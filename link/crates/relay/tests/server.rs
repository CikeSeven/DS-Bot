//! The real Relay Server on a local port, with real WebSocket clients.

use std::path::PathBuf;
use std::time::Duration;

use dsbot_link_core::keys::{device_id_for, generate_key_pair, random_token};
use dsbot_link_core::wire::{Control, LinkId, PROTOCOL, Role, encode_data};
use dsbot_link_relay::server::{self, Settings};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

const WAIT: Duration = Duration::from_secs(5);

struct Device {
    id: String,
    hello: Control,
}

impl Device {
    fn new(role: Role) -> Self {
        let pair = generate_key_pair(None).unwrap();
        let id = device_id_for(&pair.public_key).unwrap();
        let hello = Control::Hello {
            role,
            device_id: id.clone(),
            identity_key: pair.public_key,
            access_token: random_token(32),
            protocols: vec![PROTOCOL],
            fresh: false,
        };
        Self { id, hello }
    }
}

async fn send(socket: &mut Socket, control: &Control) {
    socket.send(Message::text(control.encode())).await.unwrap();
}

async fn next_message(socket: &mut Socket) -> Message {
    loop {
        let message = timeout(WAIT, socket.next())
            .await
            .expect("a frame in time")
            .expect("an open socket")
            .unwrap();
        if !matches!(message, Message::Ping(_) | Message::Pong(_)) {
            return message;
        }
    }
}

async fn next_control(socket: &mut Socket) -> Control {
    match next_message(socket).await {
        Message::Text(text) => Control::decode(text.as_str()).unwrap(),
        other => panic!("expected a control frame, got {other:?}"),
    }
}

async fn http_get(address: std::net::SocketAddr, path: &str) -> String {
    let mut stream = TcpStream::connect(address).await.unwrap();
    let request = format!("GET {path} HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\n\r\n");
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut response = String::new();
    timeout(WAIT, stream.read_to_string(&mut response))
        .await
        .unwrap()
        .unwrap();
    response
}

fn data_file() -> PathBuf {
    let unique = format!(
        "dsbot-link-relay-test-{}-{}",
        std::process::id(),
        random_token(6)
    );
    std::env::temp_dir().join(unique).join("devices.json")
}

#[tokio::test]
async fn relays_a_link_between_real_sockets() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let url = server::link_url(address);
    let file = data_file();
    let settings = Settings {
        data_file: Some(file.clone()),
        ..Settings::default()
    };
    let (stop, stopped) = oneshot::channel::<()>();
    let server = tokio::spawn(server::run(listener, settings, async {
        let _ = stopped.await;
    }));

    let health = http_get(address, "/healthz").await;
    assert!(health.starts_with("HTTP/1.1 200"), "{health}");
    assert!(health.ends_with("\r\n\r\nok\n"), "{health}");
    assert!(http_get(address, "/nope").await.starts_with("HTTP/1.1 404"));

    let mut foreign = url.as_str().into_client_request().unwrap();
    foreign
        .headers_mut()
        .insert("Origin", "https://elsewhere.example".parse().unwrap());
    match connect_async(foreign).await {
        Err(tokio_tungstenite::tungstenite::Error::Http(response)) => {
            assert_eq!(response.status(), 403)
        }
        other => panic!("a page from another origin must be refused, got {other:?}"),
    }

    let (host, client) = (Device::new(Role::Host), Device::new(Role::Client));
    let (mut host_socket, _) = connect_async(url.as_str()).await.unwrap();
    send(&mut host_socket, &host.hello).await;
    assert!(matches!(
        next_control(&mut host_socket).await,
        Control::HelloAck {
            protocol: 2,
            heartbeat_ms: 15_000,
            ..
        }
    ));

    let link = LinkId::random();
    let (mut client_socket, _) = connect_async(url.as_str()).await.unwrap();
    send(&mut client_socket, &client.hello).await;
    send(
        &mut client_socket,
        &Control::Open {
            link: link.text(),
            host: host.id.clone(),
            handshake: "bXNnMQ".into(),
        },
    )
    .await;
    assert!(matches!(
        next_control(&mut client_socket).await,
        Control::HelloAck { .. }
    ));

    match next_control(&mut host_socket).await {
        Control::Incoming {
            link: incoming,
            client: from,
            handshake,
            ..
        } => {
            assert_eq!(
                (incoming, from, handshake.as_str()),
                (link.text(), client.id.clone(), "bXNnMQ")
            );
        }
        other => panic!("expected incoming, got {other:?}"),
    }
    send(
        &mut host_socket,
        &Control::Accept {
            link: link.text(),
            handshake: "bXNnMg".into(),
        },
    )
    .await;
    assert_eq!(
        next_control(&mut client_socket).await,
        Control::Opened {
            link: link.text(),
            handshake: "bXNnMg".into()
        }
    );

    let frame = encode_data(link, 1, 0, &[42; 48]);
    client_socket
        .send(Message::binary(frame.clone()))
        .await
        .unwrap();
    assert_eq!(next_message(&mut host_socket).await, Message::binary(frame));
    let reply = encode_data(link, 1, 1, &[24; 16]);
    host_socket
        .send(Message::binary(reply.clone()))
        .await
        .unwrap();
    assert_eq!(
        next_message(&mut client_socket).await,
        Message::binary(reply)
    );

    stop.send(()).unwrap();
    match next_message(&mut client_socket).await {
        Message::Close(Some(frame)) => assert_eq!(u16::from(frame.code), 1001),
        other => panic!("expected a close, got {other:?}"),
    }
    timeout(Duration::from_secs(10), server)
        .await
        .expect("a prompt shutdown")
        .unwrap()
        .unwrap();

    let saved = std::fs::read_to_string(&file).unwrap();
    assert!(saved.contains(&host.id) && saved.contains(&client.id));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    std::fs::remove_dir_all(file.parent().unwrap()).unwrap();
}
