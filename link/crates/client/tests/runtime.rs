//! The runtime over a real local WebSocket. The other end is a small stand-in for
//! the Relay Server and the computer together: it answers hello, open and attach,
//! echoes calls and pushes events, and can cut the socket.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use dsbot_link_client::runtime::{self, LinkEvent, LinkHandle};
use dsbot_link_client::{ClientConfig, LinkStatus};
use dsbot_link_core::b64;
use dsbot_link_core::channel::{Channel, HOST_CAP_BYTES, Pacer};
use dsbot_link_core::keys::{Identity, device_id_for, generate_key_pair};
use dsbot_link_core::message::{self, Message as LinkMessage};
use dsbot_link_core::noise::{Handshake, prologue};
use dsbot_link_core::wire::{Binary, Control, LinkId, PROTOCOL, Presence};
use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio::sync::broadcast;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;

const WAIT: Duration = Duration::from_secs(10);

fn identity() -> Identity {
    let pair = generate_key_pair(None).unwrap();
    Identity::new(&pair.public_key, &pair.private_key).unwrap()
}

struct Computer {
    identity: Identity,
    phone_key: [u8; 32],
    started: Instant,
    link: Mutex<Option<Channel>>,
    pacer: Mutex<Pacer>,
    closes: Mutex<Vec<String>>,
}

impl Computer {
    fn now(&self) -> u64 {
        self.started.elapsed().as_millis() as u64
    }

    fn control(&self, control: Control) -> Vec<Message> {
        let reply = match control {
            Control::Hello { .. } => Control::HelloAck {
                protocol: PROTOCOL,
                server: "test".into(),
                heartbeat_ms: 15_000,
                grace_ms: 120_000,
                max_frame_bytes: 1 << 20,
            },
            Control::Ping { nonce } => Control::Pong { nonce },
            Control::Open {
                link, handshake, ..
            } => {
                let phone = device_id_for(&b64::encode(&self.phone_key)).unwrap();
                let prologue = prologue(&link, &self.identity.device_id, &phone).unwrap();
                let mut responder =
                    Handshake::responder(&self.identity, self.phone_key, &prologue).unwrap();
                responder.read(&b64::decode(&handshake).unwrap()).unwrap();
                let msg2 = responder.write(br#"{"name":"Desk"}"#).unwrap();
                let mut channel = Channel::new(
                    LinkId::parse(&link).unwrap(),
                    responder.finish().unwrap(),
                    HOST_CAP_BYTES,
                );
                channel.set_open(true);
                *self.link.lock().unwrap() = Some(channel);
                Control::Opened {
                    link,
                    handshake: b64::encode(&msg2),
                }
            }
            Control::Attach { link } => {
                let mut current = self.link.lock().unwrap();
                let channel = current.as_mut().unwrap();
                channel.set_open(false);
                channel.set_open(true);
                Control::Attached {
                    link,
                    peer: Presence::Present,
                }
            }
            Control::Close { code, .. } => {
                self.closes.lock().unwrap().push(code);
                return Vec::new();
            }
            _ => return Vec::new(),
        };
        let mut out = vec![Message::text(reply.encode())];
        out.extend(self.flush());
        out
    }

    fn binary(&self, data: &[u8]) -> Vec<Message> {
        let now = self.now();
        let mut current = self.link.lock().unwrap();
        let Some(channel) = current.as_mut() else {
            return Vec::new();
        };
        for bytes in channel.receive(Binary::decode(data).unwrap(), now).unwrap() {
            if let Ok(LinkMessage::Request { id, method, params }) = message::decode(&bytes) {
                let reply = match method.as_str() {
                    "echo" => message::response(&id, message::raw(&params).unwrap(), now),
                    _ => message::error(&id, "NO_METHOD", "unknown", false, now),
                };
                channel.send(&reply).unwrap();
            }
        }
        drop(current);
        self.flush()
    }

    fn emit(&self, name: &str, data: &str) -> Vec<Message> {
        let now = self.now();
        if let Some(channel) = self.link.lock().unwrap().as_mut() {
            channel
                .send(&message::event(name, message::raw(data).unwrap(), now))
                .unwrap();
        }
        self.flush()
    }

    fn flush(&self) -> Vec<Message> {
        let now = self.now();
        let mut current = self.link.lock().unwrap();
        let Some(channel) = current.as_mut() else {
            return Vec::new();
        };
        channel.tick(now);
        channel
            .poll(&mut self.pacer.lock().unwrap(), now)
            .into_iter()
            .map(Message::binary)
            .collect()
    }
}

#[derive(Clone, Debug)]
enum Order {
    Cut,
    Emit(&'static str, &'static str),
}

/// Serves one socket at a time; returns the URL and a way to give orders.
async fn serve(computer: Arc<Computer>) -> (String, broadcast::Sender<Order>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}/v2/link", listener.local_addr().unwrap());
    let (orders, _) = broadcast::channel(16);
    let orders_for_sockets = orders.clone();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
            let computer = computer.clone();
            let mut orders = orders_for_sockets.subscribe();
            tokio::spawn(async move {
                let mut ticks = tokio::time::interval(Duration::from_millis(50));
                loop {
                    let out = tokio::select! {
                        frame = ws.next() => match frame {
                            Some(Ok(Message::Text(text))) => computer.control(Control::decode(text.as_str()).unwrap()),
                            Some(Ok(Message::Binary(data))) => computer.binary(&data),
                            Some(Ok(_)) => Vec::new(),
                            _ => return,
                        },
                        order = orders.recv() => match order {
                            Ok(Order::Cut) | Err(_) => return,
                            Ok(Order::Emit(name, data)) => computer.emit(name, data),
                        },
                        _ = ticks.tick() => computer.flush(),
                    };
                    for message in out {
                        if ws.send(message).await.is_err() {
                            return;
                        }
                    }
                }
            });
        }
    });
    (url, orders)
}

async fn next_status(events: &mut broadcast::Receiver<LinkEvent>) -> LinkStatus {
    loop {
        if let LinkEvent::Status(status) = timeout(WAIT, events.recv())
            .await
            .expect("no status in time")
            .unwrap()
        {
            return status;
        }
    }
}

async fn wait_for(events: &mut broadcast::Receiver<LinkEvent>, wanted: LinkStatus) {
    loop {
        if next_status(events).await == wanted {
            return;
        }
    }
}

async fn setup() -> (Arc<Computer>, broadcast::Sender<Order>, ClientConfig) {
    let (phone, host) = (identity(), identity());
    let computer = Arc::new(Computer {
        phone_key: phone.public_bytes(),
        identity: host.clone(),
        started: Instant::now(),
        link: Mutex::new(None),
        pacer: Mutex::new(Pacer::new(0)),
        closes: Mutex::new(Vec::new()),
    });
    let (url, orders) = serve(computer.clone()).await;
    let config = ClientConfig {
        server: url,
        identity: phone,
        access_token: "t".repeat(43),
        host_device_id: host.device_id,
        host_key: host.public_key,
        name: Some("Pixel".into()),
        pairing_code: None,
    };
    (computer, orders, config)
}

fn open(config: &ClientConfig) -> (LinkHandle, broadcast::Receiver<LinkEvent>) {
    let handle = runtime::open(config.clone());
    let events = handle.subscribe();
    (handle, events)
}

#[tokio::test]
async fn calls_events_and_a_resumed_link_after_the_socket_drops() {
    let (computer, orders, config) = setup().await;
    let (handle, mut events) = open(&config);
    // A call made before the link is up waits for it.
    let early = handle.rpc("echo", r#"{"n":1}"#, 10_000);
    wait_for(&mut events, LinkStatus::Online { resumed: false }).await;
    assert_eq!(early.await.unwrap(), r#"{"n":1}"#);
    assert_eq!(handle.host_name().as_deref(), Some("Desk"));

    orders
        .send(Order::Emit("revision", r#"{"revision":7}"#))
        .unwrap();
    loop {
        if let LinkEvent::Event { name, data } =
            timeout(WAIT, events.recv()).await.unwrap().unwrap()
        {
            assert_eq!(
                (name.as_str(), data.as_str()),
                ("revision", r#"{"revision":7}"#)
            );
            break;
        }
    }

    orders.send(Order::Cut).unwrap();
    assert!(matches!(
        next_status(&mut events).await,
        LinkStatus::Reconnecting { .. }
    ));
    wait_for(&mut events, LinkStatus::Online { resumed: true }).await;
    assert_eq!(handle.rpc("echo", "[2]", 10_000).await.unwrap(), "[2]");

    handle.network_changed();
    assert!(matches!(
        next_status(&mut events).await,
        LinkStatus::Reconnecting { .. }
    ));
    wait_for(&mut events, LinkStatus::Online { resumed: true }).await;
    assert_eq!(
        handle.rpc("nope", "null", 10_000).await.unwrap_err().code,
        "NO_METHOD"
    );

    handle.close().await;
    assert_eq!(handle.status(), Some(LinkStatus::Closed));
    let deadline = Instant::now() + WAIT;
    while computer.closes.lock().unwrap().is_empty() && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(
        *computer.closes.lock().unwrap(),
        vec!["CLOSED".to_string()],
        "the computer heard the close"
    );
}

#[tokio::test]
async fn a_second_open_joins_the_live_session() {
    let (_computer, _orders, config) = setup().await;
    let (first, mut events) = open(&config);
    wait_for(&mut events, LinkStatus::Online { resumed: false }).await;
    let (second, _) = open(&config);
    // Joined, not dialed again: the status is there at once and calls go.
    assert_eq!(second.status(), Some(LinkStatus::Online { resumed: false }));
    assert_eq!(second.rpc("echo", "1", 10_000).await.unwrap(), "1");
    first.close().await;
    assert_eq!(second.rpc("echo", "2", 10_000).await.unwrap(), "2");
    second.close().await;
    assert_eq!(second.status(), Some(LinkStatus::Closed));
}

#[tokio::test]
async fn going_to_the_background_never_strands_the_session() {
    let (_computer, orders, config) = setup().await;
    let (handle, mut events) = open(&config);
    wait_for(&mut events, LinkStatus::Online { resumed: false }).await;
    handle.set_foreground(false);
    orders.send(Order::Cut).unwrap();
    assert!(matches!(
        next_status(&mut events).await,
        LinkStatus::Reconnecting { .. }
    ));
    wait_for(&mut events, LinkStatus::Online { resumed: true }).await;
    handle.set_foreground(true);
    assert_eq!(handle.rpc("echo", "3", 10_000).await.unwrap(), "3");
    handle.close().await;
}
