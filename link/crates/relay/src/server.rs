//! The Relay Server runtime: axum and tokio around `RelayCore`.
//!
//! One mutex holds the core and the outboxes of the open sockets. Every socket event locks
//! it, feeds the core and hands the actions out to the sockets' outboxes before unlocking.

use std::collections::HashMap;
use std::future::Future;
use std::io::{self, Write};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use axum::Router;
use axum::body::Bytes;
use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, State as Shared};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::serve::ListenerExt;
use dsbot_link_core::wire::{LINK_PATH, MAX_FRAME_BYTES};
use futures_util::stream::SplitSink;
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio::sync::{Notify, mpsc};
use tokio::time::MissedTickBehavior;
use tracing::{debug, info, warn};

use crate::{ConnId, DeviceStore, Refusal, RelayAction, RelayConfig, RelayCore};

/// A socket whose unsent frames pass this is dropped; it attaches again and the sender retransmits.
const MAX_QUEUED_BYTES: usize = 4 * 1024 * 1024;
const TICK: Duration = Duration::from_secs(1);
/// How long a socket the relay closed may take to answer the close before it is dropped.
const CLOSE_WAIT: Duration = Duration::from_secs(1);
const SHUTDOWN_WAIT: Duration = Duration::from_secs(3);
const GOING_AWAY: u16 = 1001;

#[derive(Clone, Debug, Default)]
pub struct Settings {
    pub relay: RelayConfig,
    /// Where the device table is kept; `None` keeps it in memory only.
    pub data_file: Option<PathBuf>,
    /// Take the client address from the last `X-Forwarded-For` entry. Only behind a proxy that sets it.
    pub trust_proxy: bool,
}

impl Settings {
    /// Reads the same variables as the v1 relay, plus `DSBOT_LINK_GRACE_SECONDS`.
    pub fn from_env() -> Result<Self, String> {
        let defaults = RelayConfig::default();
        let relay = RelayConfig {
            max_sockets: env_number("DSBOT_LINK_MAX_SOCKETS")?.unwrap_or(defaults.max_sockets),
            max_links: env_number("DSBOT_LINK_MAX_LINKS")?.unwrap_or(defaults.max_links),
            max_sockets_per_address: env_number("DSBOT_LINK_MAX_SOCKETS_PER_ADDRESS")?
                .unwrap_or(defaults.max_sockets_per_address),
            max_new_devices_per_hour: env_number("DSBOT_LINK_MAX_NEW_DEVICES_PER_HOUR")?
                .unwrap_or(defaults.max_new_devices_per_hour),
            max_bytes_per_hour: env_number::<u64>("DSBOT_LINK_MAX_MB_PER_HOUR")?
                .map_or(defaults.max_bytes_per_hour, |mb| {
                    mb.saturating_mul(1024 * 1024)
                }),
            grace_ms: env_number::<u64>("DSBOT_LINK_GRACE_SECONDS")?
                .map_or(defaults.grace_ms, |seconds| seconds.saturating_mul(1_000)),
            device_ttl_ms: env_number::<u64>("DSBOT_LINK_DEVICE_TTL_DAYS")?
                .map(|days| days.saturating_mul(86_400_000)),
            ..defaults
        };
        let data_file = std::env::var_os("DSBOT_LINK_DATA")
            .filter(|path| !path.is_empty())
            .map(PathBuf::from);
        let trust_proxy = std::env::var("DSBOT_LINK_TRUST_PROXY").is_ok_and(|value| value == "1");
        Ok(Self {
            relay,
            data_file,
            trust_proxy,
        })
    }
}

/// `HOST` and `PORT`, by default `0.0.0.0` and `8787`.
pub fn listen_from_env() -> Result<(String, u16), String> {
    let host = std::env::var("HOST")
        .ok()
        .filter(|host| !host.is_empty())
        .unwrap_or_else(|| "0.0.0.0".into());
    Ok((host, env_number("PORT")?.unwrap_or(8787)))
}

fn env_number<T: FromStr>(name: &str) -> Result<Option<T>, String> {
    match std::env::var(name) {
        Ok(text) if !text.trim().is_empty() => text
            .trim()
            .parse()
            .map(Some)
            .map_err(|_| format!("{name} must be a whole number, not {text:?}.")),
        _ => Ok(None),
    }
}

/// The WebSocket address that `listener` serves.
pub fn link_url(address: SocketAddr) -> String {
    format!("ws://{address}{LINK_PATH}")
}

/// Serves the relay on `listener` until `shutdown` completes, then closes the sockets and saves the device table.
pub async fn run<F>(listener: TcpListener, settings: Settings, shutdown: F) -> io::Result<()>
where
    F: Future<Output = ()> + Send + 'static,
{
    let store = match &settings.data_file {
        Some(path) => load_store(path)?,
        None => DeviceStore::new(),
    };
    let relay = Arc::new(Relay::new(settings, store));
    let stop = Arc::new(Notify::new());
    let ticker = tokio::spawn(tick_loop(relay.clone(), stop.clone()));
    let closing = relay.clone();
    let app = router(relay.clone()).into_make_service_with_connect_info::<SocketAddr>();
    // Frames are small and latency matters more than packet count.
    let listener = listener.tap_io(|socket| {
        let _ = socket.set_nodelay(true);
    });
    let served = axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            shutdown.await;
            info!("shutting down");
            closing.close_all();
        })
        .await;
    relay.wait_idle().await;
    stop.notify_one();
    let _ = ticker.await;
    served?;
    relay.save().await
}

fn router(relay: Arc<Relay>) -> Router {
    Router::new()
        .route(LINK_PATH, get(link).fallback(not_found))
        .route("/healthz", get(healthz).fallback(not_found))
        .fallback(not_found)
        .with_state(relay)
}

async fn healthz() -> impl IntoResponse {
    ([(header::CONTENT_TYPE, "text/plain")], "ok\n")
}

async fn not_found() -> StatusCode {
    StatusCode::NOT_FOUND
}

async fn link(
    Shared(relay): Shared<Arc<Relay>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    if !same_origin(&headers) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let address = relay.address_of(peer, &headers);
    let admitted = relay.lock().core.admit_socket(&address);
    if let Err(refusal) = admitted {
        debug!(%address, ?refusal, "refused a socket");
        let status = match refusal {
            Refusal::Forbidden => StatusCode::FORBIDDEN,
            Refusal::TooMany => StatusCode::TOO_MANY_REQUESTS,
        };
        return status.into_response();
    }
    // Released when the socket ends, and also when the upgrade fails and drops the callback.
    let guard = SocketGuard {
        relay: relay.clone(),
        address: address.clone(),
    };
    upgrade
        .max_message_size(MAX_FRAME_BYTES)
        .max_frame_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| serve_socket(socket, relay, address, guard))
}

/// Phone apps send no Origin; a browser page may only connect from the relay's own origin.
fn same_origin(headers: &HeaderMap) -> bool {
    let Some(origin) = headers.get(header::ORIGIN) else {
        return true;
    };
    let host = headers
        .get(header::HOST)
        .and_then(|host| host.to_str().ok());
    let origin = origin
        .to_str()
        .ok()
        .and_then(|origin| url::Url::parse(origin).ok());
    let (Some(host), Some(origin)) = (host, origin) else {
        return false;
    };
    let Some(name) = origin.host_str() else {
        return false;
    };
    let origin_host = match origin.port() {
        Some(port) => format!("{name}:{port}"),
        None => name.to_string(),
    };
    origin_host.eq_ignore_ascii_case(host)
}

struct SocketGuard {
    relay: Arc<Relay>,
    address: String,
}

impl Drop for SocketGuard {
    fn drop(&mut self) {
        self.relay.lock().core.release_socket(&self.address);
    }
}

async fn serve_socket(socket: WebSocket, relay: Arc<Relay>, address: String, _guard: SocketGuard) {
    let opened = relay.open(&address);
    let conn = opened.conn;
    debug!(conn, %address, "socket opened");
    let (sink, mut stream) = socket.split();
    let read = async {
        while let Some(Ok(message)) = stream.next().await {
            relay.receive(conn, message);
        }
    };
    tokio::select! {
        () = write(sink, opened.outbox, opened.queued) => {}
        () = read => {}
        () = opened.kill.notified() => {}
    }
    relay.closed(conn);
    debug!(conn, "socket closed");
}

async fn write(
    mut sink: SplitSink<WebSocket, Message>,
    mut outbox: mpsc::UnboundedReceiver<Outgoing>,
    queued: Arc<AtomicUsize>,
) {
    while let Some(outgoing) = outbox.recv().await {
        match outgoing {
            Outgoing::Frame { message, size } => {
                if sink.send(message).await.is_err() {
                    return;
                }
                queued.fetch_sub(size, Ordering::Relaxed);
            }
            Outgoing::Close(frame) => {
                let _ = sink.send(Message::Close(Some(frame))).await;
                // The reader ends when the peer answers; the kill timer ends a peer that does not.
                std::future::pending::<()>().await;
            }
        }
    }
}

async fn tick_loop(relay: Arc<Relay>, stop: Arc<Notify>) {
    let mut interval = tokio::time::interval(TICK);
    interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            _ = interval.tick() => {}
            () = stop.notified() => return,
        }
        relay.tick();
        if let Err(error) = relay.save().await {
            warn!(%error, "could not save the device table");
        }
    }
}

enum Outgoing {
    Frame { message: Message, size: usize },
    Close(CloseFrame),
}

struct Outbox {
    tx: mpsc::UnboundedSender<Outgoing>,
    queued: Arc<AtomicUsize>,
    kill: Arc<Notify>,
}

struct Opened {
    conn: ConnId,
    outbox: mpsc::UnboundedReceiver<Outgoing>,
    queued: Arc<AtomicUsize>,
    kill: Arc<Notify>,
}

struct State {
    core: RelayCore,
    outboxes: HashMap<ConnId, Outbox>,
    next_conn: ConnId,
    live: usize,
}

impl State {
    fn drain(&mut self, now: u64) {
        while let Some(action) = self.core.poll_action() {
            match action {
                RelayAction::SendText { conn, text } => {
                    let size = text.len();
                    self.push(conn, Message::Text(text.into()), size, now);
                }
                RelayAction::SendBinary { conn, data } => {
                    let size = data.len();
                    self.push(conn, Message::Binary(data.into()), size, now);
                }
                RelayAction::Ping { conn } => self.push(conn, Message::Ping(Bytes::new()), 0, now),
                RelayAction::Close { conn, code, reason } => self.close(conn, code, &reason),
            }
        }
    }

    fn push(&mut self, conn: ConnId, message: Message, size: usize, now: u64) {
        let Some(outbox) = self.outboxes.get(&conn) else {
            return;
        };
        if outbox.queued.load(Ordering::Relaxed) + size > MAX_QUEUED_BYTES {
            warn!(conn, "dropping a slow consumer");
            outbox.kill.notify_one();
            self.outboxes.remove(&conn);
            self.core.socket_closed(conn, now);
            return;
        }
        outbox.queued.fetch_add(size, Ordering::Relaxed);
        let _ = outbox.tx.send(Outgoing::Frame { message, size });
    }

    fn close(&mut self, conn: ConnId, code: u16, reason: &str) {
        let Some(outbox) = self.outboxes.remove(&conn) else {
            return;
        };
        debug!(conn, code, reason, "closing a socket");
        let _ = outbox.tx.send(Outgoing::Close(CloseFrame {
            code,
            reason: reason.into(),
        }));
        tokio::spawn(async move {
            tokio::time::sleep(CLOSE_WAIT).await;
            outbox.kill.notify_one();
        });
    }
}

struct Relay {
    state: Mutex<State>,
    data_file: Option<PathBuf>,
    trust_proxy: bool,
    save_failed: AtomicBool,
}

impl Relay {
    fn new(settings: Settings, store: DeviceStore) -> Self {
        let core = RelayCore::new(settings.relay, store, now_ms());
        let state = State {
            core,
            outboxes: HashMap::new(),
            next_conn: 1,
            live: 0,
        };
        Self {
            state: Mutex::new(state),
            data_file: settings.data_file,
            trust_proxy: settings.trust_proxy,
            save_failed: AtomicBool::new(false),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn with(&self, event: impl FnOnce(&mut RelayCore, u64)) {
        let now = now_ms();
        let mut state = self.lock();
        event(&mut state.core, now);
        state.drain(now);
    }

    fn address_of(&self, peer: SocketAddr, headers: &HeaderMap) -> String {
        if self.trust_proxy {
            let forwarded = headers
                .get_all("x-forwarded-for")
                .iter()
                .next_back()
                .and_then(|value| value.to_str().ok());
            let last = forwarded
                .and_then(|value| value.rsplit(',').next())
                .map(str::trim)
                .filter(|value| !value.is_empty());
            if let Some(address) = last {
                return address.to_string();
            }
        }
        peer.ip().to_canonical().to_string()
    }

    fn open(&self, address: &str) -> Opened {
        let (tx, outbox) = mpsc::unbounded_channel();
        let queued = Arc::new(AtomicUsize::new(0));
        let kill = Arc::new(Notify::new());
        let mut state = self.lock();
        let conn = state.next_conn;
        state.next_conn += 1;
        state.live += 1;
        state.outboxes.insert(
            conn,
            Outbox {
                tx,
                queued: queued.clone(),
                kill: kill.clone(),
            },
        );
        state.core.socket_opened(conn, address, now_ms());
        Opened {
            conn,
            outbox,
            queued,
            kill,
        }
    }

    fn receive(&self, conn: ConnId, message: Message) {
        self.with(|core, now| match message {
            Message::Text(text) => core.socket_text(conn, text.as_str(), now),
            Message::Binary(data) => core.socket_binary(conn, &data, now),
            Message::Ping(_) | Message::Pong(_) | Message::Close(_) => core.socket_pong(conn, now),
        });
    }

    fn closed(&self, conn: ConnId) {
        let now = now_ms();
        let mut state = self.lock();
        state.live -= 1;
        state.outboxes.remove(&conn);
        state.core.socket_closed(conn, now);
        state.drain(now);
    }

    fn tick(&self) {
        self.with(|core, now| core.tick(now));
    }

    fn close_all(&self) {
        let mut state = self.lock();
        let conns: Vec<ConnId> = state.outboxes.keys().copied().collect();
        for conn in conns {
            state.close(conn, GOING_AWAY, "SHUTDOWN");
        }
    }

    fn live(&self) -> usize {
        self.lock().live
    }

    async fn wait_idle(&self) {
        let deadline = Instant::now() + SHUTDOWN_WAIT;
        while self.live() > 0 && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    /// Writes the device table if it changed, or if the last write failed.
    async fn save(&self) -> io::Result<()> {
        let Some(path) = self.data_file.clone() else {
            return Ok(());
        };
        let json = {
            let mut state = self.lock();
            if !state.core.store().dirty() && !self.save_failed.load(Ordering::Relaxed) {
                return Ok(());
            }
            state.core.store_mut().mark_saved();
            state.core.store().to_json()
        };
        let result = tokio::task::spawn_blocking(move || write_store(&path, &json))
            .await
            .unwrap_or_else(|error| Err(io::Error::other(error)));
        self.save_failed.store(result.is_err(), Ordering::Relaxed);
        result
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as u64)
}

fn load_store(path: &Path) -> io::Result<DeviceStore> {
    match std::fs::read_to_string(path) {
        Ok(text) => DeviceStore::from_json(&text)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(DeviceStore::new()),
        Err(error) => Err(error),
    }
}

/// Replaces the file in one rename, so a crash never leaves half a table.
fn write_store(path: &Path, json: &str) -> io::Result<()> {
    if let Some(dir) = path.parent().filter(|dir| !dir.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)?;
    }
    let mut temp = path.as_os_str().to_owned();
    temp.push(".tmp");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(&temp)?;
    #[cfg(unix)]
    file.set_permissions(std::os::unix::fs::PermissionsExt::from_mode(0o600))?;
    file.write_all(json.as_bytes())?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    std::fs::rename(&temp, path)
}
