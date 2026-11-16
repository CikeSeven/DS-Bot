//! `ClientCore` over tokio and real WebSockets. One driver task per session owns
//! the core and carries out its actions. A process keeps one session per
//! (Server, computer, phone): every caller that opens the same key shares it, so
//! the app's isolates never push each other off the Server.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use dsbot_link_core::LinkError;
use dsbot_link_core::conn::SocketId;
use dsbot_link_core::wire::MAX_FRAME_BYTES;
use futures_util::stream::SplitSink;
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio::runtime::Runtime;
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tokio::task::AbortHandle;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

use crate::session::{ClientAction, ClientConfig, ClientCore, LinkStatus};

/// Feed events a slow subscriber may fall behind by before it misses some.
const EVENT_BUFFER: usize = 4096;
/// A write that takes longer belongs to a dead socket; the probe then replaces it.
const WRITE_TIMEOUT: Duration = Duration::from_secs(10);

/// What a subscriber hears: status changes and the computer's feed events.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkEvent {
    Status(LinkStatus),
    Event { name: String, data: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct SessionKey {
    server: String,
    host: String,
    device: String,
}

enum Command {
    Rpc {
        method: String,
        params: String,
        timeout_ms: u64,
        reply: oneshot::Sender<Result<String, LinkError>>,
    },
    NetworkChanged,
    Foreground(bool),
    Close,
}

struct Session {
    key: SessionKey,
    commands: mpsc::UnboundedSender<Command>,
    events: broadcast::Sender<LinkEvent>,
    status: Mutex<Option<LinkStatus>>,
    host_name: Mutex<Option<String>>,
    /// Open handles; changed only under the registry lock.
    handles: AtomicUsize,
    done: watch::Receiver<bool>,
}

impl Session {
    fn ended(&self) -> bool {
        matches!(
            *lock(&self.status),
            Some(LinkStatus::Rejected { .. } | LinkStatus::Closed)
        ) || *self.done.borrow()
    }
}

/// One user of a session. The session ends when its last handle closes or drops.
pub struct LinkHandle {
    session: Arc<Session>,
    released: AtomicBool,
}

/// Opens the session for this Server, computer and phone, or joins the one that
/// is already running. A pairing code always starts a new session.
pub fn open(config: ClientConfig) -> LinkHandle {
    let key = SessionKey {
        server: config.server.clone(),
        host: config.host_device_id.clone(),
        device: config.identity.device_id.clone(),
    };
    let mut sessions = lock(registry());
    if let Some(session) = sessions.get(&key) {
        if config.pairing_code.is_none() && !session.ended() {
            session.handles.fetch_add(1, Ordering::SeqCst);
            return LinkHandle {
                session: session.clone(),
                released: AtomicBool::new(false),
            };
        }
        let _ = session.commands.send(Command::Close);
    }
    let session = start(key.clone(), config);
    sessions.insert(key, session.clone());
    LinkHandle {
        session,
        released: AtomicBool::new(false),
    }
}

impl LinkHandle {
    /// Calls `method` on the computer. A call waits for the link while there is
    /// none and fails only on timeout, a new session, rejection or close.
    pub async fn rpc(
        &self,
        method: &str,
        params_json: &str,
        timeout_ms: u64,
    ) -> Result<String, LinkError> {
        let closed = || LinkError::new("CLIENT_CLOSED", "The link was closed.");
        if self.released.load(Ordering::SeqCst) {
            return Err(closed());
        }
        let (reply, answer) = oneshot::channel();
        let command = Command::Rpc {
            method: method.into(),
            params: params_json.into(),
            timeout_ms,
            reply,
        };
        self.session.commands.send(command).map_err(|_| closed())?;
        answer.await.unwrap_or_else(|_| Err(closed()))
    }

    pub fn subscribe(&self) -> broadcast::Receiver<LinkEvent> {
        self.session.events.subscribe()
    }

    /// The latest status; subscribe first, then read it, to miss nothing.
    pub fn status(&self) -> Option<LinkStatus> {
        lock(&self.session.status).clone()
    }

    /// What the computer called itself in the last handshake.
    pub fn host_name(&self) -> Option<String> {
        lock(&self.session.host_name).clone()
    }

    pub fn network_changed(&self) {
        let _ = self.session.commands.send(Command::NetworkChanged);
    }

    pub fn set_foreground(&self, foreground: bool) {
        let _ = self.session.commands.send(Command::Foreground(foreground));
    }

    /// Lets go of the session; the last handle ends it and waits until it has.
    pub async fn close(&self) {
        if let Some(mut done) = self.release() {
            let _ = done.wait_for(|done| *done).await;
        }
    }

    fn release(&self) -> Option<watch::Receiver<bool>> {
        if self.released.swap(true, Ordering::SeqCst) {
            return None;
        }
        let mut sessions = lock(registry());
        if self.session.handles.fetch_sub(1, Ordering::SeqCst) != 1 {
            return None;
        }
        if sessions
            .get(&self.session.key)
            .is_some_and(|current| Arc::ptr_eq(current, &self.session))
        {
            sessions.remove(&self.session.key);
        }
        let _ = self.session.commands.send(Command::Close);
        Some(self.session.done.clone())
    }
}

impl Drop for LinkHandle {
    fn drop(&mut self) {
        self.release();
    }
}

fn registry() -> &'static Mutex<HashMap<SessionKey, Arc<Session>>> {
    static SESSIONS: OnceLock<Mutex<HashMap<SessionKey, Arc<Session>>>> = OnceLock::new();
    SESSIONS.get_or_init(Default::default)
}

/// The sessions' own runtime: they outlive whatever runtime or thread opened them.
fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        // Fails only if a provider is already installed, which is just as good.
        let _ = rustls::crypto::ring::default_provider().install_default();
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("dsbot-link")
            .enable_all()
            .build()
            .expect("cannot start the link runtime")
    })
}

fn epoch() -> Instant {
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    *EPOCH.get_or_init(Instant::now)
}

fn now() -> u64 {
    epoch().elapsed().as_millis() as u64
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    // A panic elsewhere must not take the link down with it.
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn start(key: SessionKey, config: ClientConfig) -> Arc<Session> {
    let (commands, receiver) = mpsc::unbounded_channel();
    let (events, _) = broadcast::channel(EVENT_BUFFER);
    let (finished, done) = watch::channel(false);
    let session = Arc::new(Session {
        key,
        commands,
        events,
        status: Mutex::new(None),
        host_name: Mutex::new(None),
        handles: AtomicUsize::new(1),
        done,
    });
    let (socket_events, from_sockets) = mpsc::unbounded_channel();
    let driver = Driver {
        core: ClientCore::new(config, now()),
        session: session.clone(),
        sockets: HashMap::new(),
        calls: HashMap::new(),
        socket_events,
    };
    runtime().spawn(driver.run(receiver, from_sockets, finished));
    session
}

enum SocketEvent {
    Opened,
    Text(String),
    Binary(Vec<u8>),
    Closed(Option<String>),
}

type SocketEvents = mpsc::UnboundedSender<(SocketId, SocketEvent)>;
type Writer = SplitSink<WebSocketStream<MaybeTlsStream<TcpStream>>, Message>;

/// A WebSocket the core asked for. Dropping it stops reading at once; frames
/// already queued still go out (a `close` sent just before), then the socket ends
/// without waiting for a closing handshake.
struct Socket {
    outgoing: mpsc::UnboundedSender<Message>,
    reader: AbortHandle,
}

impl Socket {
    fn connect(id: SocketId, url: String, events: SocketEvents) -> Self {
        let (outgoing, queued) = mpsc::unbounded_channel();
        let reader = tokio::spawn(read_socket(id, url, queued, events)).abort_handle();
        Self { outgoing, reader }
    }

    fn send(&self, message: Message) {
        let _ = self.outgoing.send(message);
    }
}

impl Drop for Socket {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

async fn read_socket(
    id: SocketId,
    url: String,
    queued: mpsc::UnboundedReceiver<Message>,
    events: SocketEvents,
) {
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_FRAME_BYTES))
        .max_frame_size(Some(MAX_FRAME_BYTES));
    let stream = match tokio_tungstenite::connect_async_tls_with_config(
        url.as_str(),
        Some(config),
        true,
        None,
    )
    .await
    {
        Ok((stream, _)) => stream,
        Err(error) => {
            let _ = events.send((id, SocketEvent::Closed(Some(error.to_string()))));
            return;
        }
    };
    let (writer, mut reader) = stream.split();
    tokio::spawn(write_socket(writer, queued));
    let _ = events.send((id, SocketEvent::Opened));
    let reason = loop {
        let event = match reader.next().await {
            Some(Ok(Message::Text(text))) => SocketEvent::Text(text.as_str().into()),
            Some(Ok(Message::Binary(data))) => SocketEvent::Binary(data.into()),
            Some(Ok(Message::Close(frame))) => {
                break frame
                    .map(|frame| frame.reason.as_str().to_owned())
                    .filter(|r| !r.is_empty());
            }
            Some(Ok(_)) => continue,
            Some(Err(error)) => break Some(error.to_string()),
            None => break None,
        };
        if events.send((id, event)).is_err() {
            return;
        }
    };
    let _ = events.send((id, SocketEvent::Closed(reason)));
}

async fn write_socket(mut writer: Writer, mut queued: mpsc::UnboundedReceiver<Message>) {
    while let Some(message) = queued.recv().await {
        match tokio::time::timeout(WRITE_TIMEOUT, writer.send(message)).await {
            Ok(Ok(())) => {}
            _ => return,
        }
    }
}

struct Driver {
    core: ClientCore,
    session: Arc<Session>,
    sockets: HashMap<SocketId, Socket>,
    calls: HashMap<u64, oneshot::Sender<Result<String, LinkError>>>,
    socket_events: SocketEvents,
}

impl Driver {
    async fn run(
        mut self,
        mut commands: mpsc::UnboundedReceiver<Command>,
        mut from_sockets: mpsc::UnboundedReceiver<(SocketId, SocketEvent)>,
        finished: watch::Sender<bool>,
    ) {
        self.core.start(now());
        let mut closing = false;
        loop {
            self.carry_out();
            if closing {
                break;
            }
            let deadline = self
                .core
                .next_deadline()
                .map(|at| tokio::time::Instant::from_std(epoch() + Duration::from_millis(at)));
            tokio::select! {
                command = commands.recv() => closing = self.command(command),
                Some((socket, event)) = from_sockets.recv() => self.socket(socket, event),
                () = tokio::time::sleep_until(deadline.unwrap_or_else(tokio::time::Instant::now)), if deadline.is_some() => {
                    self.core.tick(now());
                }
            }
        }
        // Dropping the sockets lets the `close` frame just queued go out.
        self.sockets.clear();
        let _ = finished.send(true);
    }

    /// Returns true when the session is to end.
    fn command(&mut self, command: Option<Command>) -> bool {
        match command {
            Some(Command::Rpc {
                method,
                params,
                timeout_ms,
                reply,
            }) => {
                let call = self.core.rpc(&method, &params, timeout_ms, now());
                self.calls.insert(call, reply);
            }
            Some(Command::NetworkChanged) => self.core.network_changed(now()),
            Some(Command::Foreground(foreground)) => self.core.set_foreground(foreground, now()),
            Some(Command::Close) | None => {
                self.core.close(now());
                return true;
            }
        }
        false
    }

    fn socket(&mut self, socket: SocketId, event: SocketEvent) {
        match event {
            SocketEvent::Opened => self.core.socket_opened(socket, now()),
            SocketEvent::Text(text) => self.core.socket_text(socket, &text, now()),
            SocketEvent::Binary(data) => self.core.socket_binary(socket, &data, now()),
            SocketEvent::Closed(reason) => {
                self.sockets.remove(&socket);
                self.core.socket_closed(socket, reason.as_deref(), now());
            }
        }
    }

    fn carry_out(&mut self) {
        while let Some(action) = self.core.poll_action() {
            match action {
                ClientAction::Connect { socket, url } => {
                    self.sockets.insert(
                        socket,
                        Socket::connect(socket, url, self.socket_events.clone()),
                    );
                }
                ClientAction::SendText { socket, text } => self.send(socket, Message::text(text)),
                ClientAction::SendBinary { socket, data } => {
                    self.send(socket, Message::binary(data))
                }
                ClientAction::CloseSocket { socket } => {
                    self.sockets.remove(&socket);
                }
                ClientAction::Status(status) => {
                    *lock(&self.session.status) = Some(status.clone());
                    let _ = self.session.events.send(LinkEvent::Status(status));
                }
                ClientAction::Event { name, data } => {
                    let _ = self.session.events.send(LinkEvent::Event { name, data });
                }
                ClientAction::RpcDone { call, result } => {
                    if let Some(reply) = self.calls.remove(&call) {
                        let _ = reply.send(result);
                    }
                }
            }
        }
        if let Some(name) = self.core.host_name() {
            let mut known = lock(&self.session.host_name);
            if known.as_deref() != Some(name) {
                *known = Some(name.into());
            }
        }
    }

    fn send(&self, socket: SocketId, message: Message) {
        if let Some(socket) = self.sockets.get(&socket) {
            socket.send(message);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dsbot_link_core::keys::{Identity, generate_key_pair};

    fn config(server: &str, pairing_code: Option<&str>) -> ClientConfig {
        static PHONE: OnceLock<Identity> = OnceLock::new();
        let identity = PHONE
            .get_or_init(|| {
                let pair = generate_key_pair(None).unwrap();
                Identity::new(&pair.public_key, &pair.private_key).unwrap()
            })
            .clone();
        let host = generate_key_pair(None).unwrap();
        ClientConfig {
            // Nothing listens on port 9: the sessions only dial and back off.
            server: server.into(),
            identity,
            access_token: "t".repeat(43),
            host_device_id: "d-host".into(),
            host_key: host.public_key,
            name: None,
            pairing_code: pairing_code.map(String::from),
        }
    }

    #[tokio::test]
    async fn one_session_per_key_until_the_last_handle_closes() {
        let first = open(config("ws://127.0.0.1:9/v2/link/a", None));
        let second = open(config("ws://127.0.0.1:9/v2/link/a", None));
        let other = open(config("ws://127.0.0.1:9/v2/link/b", None));
        assert!(Arc::ptr_eq(&first.session, &second.session));
        assert!(!Arc::ptr_eq(&first.session, &other.session));

        first.close().await;
        assert!(!second.session.ended(), "a handle still holds it");
        let third = open(config("ws://127.0.0.1:9/v2/link/a", None));
        assert!(Arc::ptr_eq(&second.session, &third.session));
        second.close().await;
        third.close().await;
        assert!(*third.session.done.borrow());
        assert_eq!(third.status(), Some(LinkStatus::Closed));
        let fresh = open(config("ws://127.0.0.1:9/v2/link/a", None));
        assert!(!Arc::ptr_eq(&third.session, &fresh.session));
        drop(fresh);
        drop(other);
    }

    #[tokio::test]
    async fn a_pairing_code_replaces_the_running_session() {
        let running = open(config("ws://127.0.0.1:9/v2/link/c", None));
        let mut heard = running.subscribe();
        let pairing = open(config("ws://127.0.0.1:9/v2/link/c", Some("code")));
        assert!(!Arc::ptr_eq(&running.session, &pairing.session));
        loop {
            if let LinkEvent::Status(LinkStatus::Closed) = heard.recv().await.unwrap() {
                break;
            }
        }
        let error = running.rpc("bot", "{}", 1_000).await.unwrap_err();
        assert_eq!(error.code, "CLIENT_CLOSED");
        let joined = open(config("ws://127.0.0.1:9/v2/link/c", None));
        assert!(Arc::ptr_eq(&pairing.session, &joined.session));
        running.close().await;
        pairing.close().await;
        joined.close().await;
    }
}
