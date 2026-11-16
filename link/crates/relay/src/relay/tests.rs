use dsbot_link_core::keys::{device_id_for, generate_key_pair, random_token};
use dsbot_link_core::wire::{encode_ack, encode_data};

use super::*;

const START: u64 = 1_800_000_000_000;
const HOME: &str = "203.0.113.1";

struct Device {
    id: String,
    key: String,
    token: String,
    role: Role,
}

impl Device {
    fn new(role: Role) -> Self {
        let pair = generate_key_pair(None).unwrap();
        Self {
            id: device_id_for(&pair.public_key).unwrap(),
            key: pair.public_key,
            token: random_token(32),
            role,
        }
    }

    fn hello(&self, fresh: bool) -> Control {
        Control::Hello {
            role: self.role,
            device_id: self.id.clone(),
            identity_key: self.key.clone(),
            access_token: self.token.clone(),
            protocols: vec![PROTOCOL],
            fresh,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
enum Out {
    Text(Control),
    Binary(Vec<u8>),
    Ping,
    Close(u16, String),
}

struct Bench {
    core: RelayCore,
    now: u64,
    next: ConnId,
}

impl Bench {
    fn new() -> Self {
        Self::with(RelayConfig::default())
    }

    fn with(config: RelayConfig) -> Self {
        Self {
            core: RelayCore::new(config, DeviceStore::new(), START),
            now: START,
            next: 1,
        }
    }

    fn socket(&mut self, address: &str) -> ConnId {
        self.core.admit_socket(address).unwrap();
        let conn = self.next;
        self.next += 1;
        self.core.socket_opened(conn, address, self.now);
        conn
    }

    fn connect(&mut self, device: &Device) -> ConnId {
        self.connect_from(device, HOME)
    }

    fn connect_from(&mut self, device: &Device, address: &str) -> ConnId {
        let conn = self.socket(address);
        self.send(conn, device.hello(false));
        conn
    }

    fn send(&mut self, conn: ConnId, control: Control) {
        self.core.socket_text(conn, &control.encode(), self.now);
    }

    fn advance(&mut self, ms: u64) {
        self.now += ms;
        self.core.tick(self.now);
    }

    fn take_all(&mut self) -> Vec<(ConnId, Out)> {
        std::iter::from_fn(|| self.core.poll_action())
            .map(|action| match action {
                RelayAction::SendText { conn, text } => {
                    (conn, Out::Text(Control::decode(&text).unwrap()))
                }
                RelayAction::SendBinary { conn, data } => (conn, Out::Binary(data)),
                RelayAction::Ping { conn } => (conn, Out::Ping),
                RelayAction::Close { conn, code, reason } => (conn, Out::Close(code, reason)),
            })
            .collect()
    }

    fn take(&mut self) -> Vec<(ConnId, Out)> {
        self.take_all()
            .into_iter()
            .filter(|(_, out)| *out != Out::Ping)
            .collect()
    }

    /// A host and a client, both connected, with nothing left to drain.
    fn pair() -> (Self, Device, ConnId, Device, ConnId) {
        let mut bench = Self::new();
        let (host, client) = (Device::new(Role::Host), Device::new(Role::Client));
        let host_conn = bench.connect(&host);
        let client_conn = bench.connect(&client);
        bench.take();
        (bench, host, host_conn, client, client_conn)
    }

    fn open(&mut self, client_conn: ConnId, host: &Device) -> String {
        let link = LinkId::random().text();
        self.send(
            client_conn,
            Control::Open {
                link: link.clone(),
                host: host.id.clone(),
                handshake: "msg1".into(),
            },
        );
        link
    }

    fn ready_link(&mut self, host_conn: ConnId, client_conn: ConnId, host: &Device) -> String {
        let link = self.open(client_conn, host);
        self.send(
            host_conn,
            Control::Accept {
                link: link.clone(),
                handshake: "msg2".into(),
            },
        );
        self.take();
        link
    }
}

fn ack() -> Out {
    ack_with(120_000)
}

fn ack_with(grace_ms: u64) -> Out {
    Out::Text(Control::HelloAck {
        protocol: 2,
        server: RelayConfig::default().server_version,
        heartbeat_ms: 15_000,
        grace_ms,
        max_frame_bytes: 1_048_576,
    })
}

fn hello_text(
    device: &Device,
    device_id: &str,
    key: &str,
    token: &str,
    protocols: Vec<u32>,
) -> String {
    let (device_id, identity_key, access_token) = (device_id.into(), key.into(), token.into());
    Control::Hello {
        role: device.role,
        device_id,
        identity_key,
        access_token,
        protocols,
        fresh: false,
    }
    .encode()
}

fn closed(link: &str, code: &str) -> Out {
    Out::Text(Control::Closed {
        link: link.into(),
        code: code.into(),
    })
}

fn peer(link: &str, state: PeerState) -> Out {
    Out::Text(Control::Peer {
        link: link.into(),
        state,
    })
}

fn attached(link: &str, peer: Presence) -> Out {
    Out::Text(Control::Attached {
        link: link.into(),
        peer,
    })
}

/// A socket-level error: the error frame, then the close.
fn refused(conn: ConnId, code: &str, close: u16) -> Vec<(ConnId, Out)> {
    vec![
        (
            conn,
            Out::Text(Control::Error {
                code: code.into(),
                message: String::new(),
            }),
        ),
        (conn, Out::Close(close, code.into())),
    ]
}

/// Compares socket-level errors by code only; their messages are for people.
fn codes(actions: Vec<(ConnId, Out)>) -> Vec<(ConnId, Out)> {
    actions
        .into_iter()
        .map(|(conn, out)| match out {
            Out::Text(Control::Error { code, .. }) => (
                conn,
                Out::Text(Control::Error {
                    code,
                    message: String::new(),
                }),
            ),
            other => (conn, other),
        })
        .collect()
}

fn data(link: &str, seq: u64) -> Vec<u8> {
    encode_data(LinkId::parse(link).unwrap(), seq, 0, &[7; 16])
}

#[test]
fn hello_is_acknowledged_and_recorded() {
    let mut bench = Bench::new();
    let host = Device::new(Role::Host);
    let conn = bench.connect(&host);
    assert_eq!(bench.take(), vec![(conn, ack())]);
    let record = bench.core.store().get(&host.id).unwrap();
    assert_eq!(
        (record.role, record.identity_key.as_str()),
        (Role::Host, host.key.as_str())
    );
    assert!(bench.core.store().dirty());
}

#[test]
fn hello_must_come_first_and_be_valid() {
    let mut bench = Bench::new();
    let device = Device::new(Role::Client);
    let other = Device::new(Role::Client);
    let cases: Vec<(String, &str)> = vec![
        (
            Control::Ping { nonce: "n".into() }.encode(),
            "AUTH_REQUIRED",
        ),
        ("not json".into(), "INVALID_MESSAGE"),
        (
            r#"{"type":"hello","role":"admin"}"#.into(),
            "INVALID_MESSAGE",
        ),
        (
            hello_text(&device, &other.id, &device.key, &device.token, vec![2]),
            "AUTH_INVALID",
        ),
        (
            hello_text(&device, &device.id, "not-a-key", &device.token, vec![2]),
            "AUTH_INVALID",
        ),
        (
            hello_text(&device, &device.id, &device.key, &"x".repeat(31), vec![2]),
            "AUTH_INVALID",
        ),
        (
            hello_text(&device, &device.id, &device.key, &"x".repeat(257), vec![2]),
            "AUTH_INVALID",
        ),
        (
            hello_text(&device, &device.id, &device.key, &device.token, vec![1]),
            "UNSUPPORTED_VERSION",
        ),
    ];
    for (text, code) in cases {
        let conn = bench.socket(HOME);
        bench.core.socket_text(conn, &text, bench.now);
        assert_eq!(codes(bench.take()), refused(conn, code, 4001), "{text}");
        bench.send(conn, device.hello(false));
        bench.core.socket_binary(conn, &[1; 40], bench.now);
        assert_eq!(
            bench.take(),
            vec![],
            "frames after a failed hello are ignored"
        );
    }
    let conn = bench.socket(HOME);
    bench.core.socket_binary(conn, &[1; 40], bench.now);
    assert_eq!(codes(bench.take()), refused(conn, "AUTH_REQUIRED", 4001));
    assert!(bench.core.store().is_empty());
}

#[test]
fn hello_binds_the_first_token_and_role() {
    let mut bench = Bench::new();
    let host = Device::new(Role::Host);
    let first = bench.connect(&host);
    bench.take();
    let thief = Device {
        id: host.id.clone(),
        key: host.key.clone(),
        token: random_token(32),
        role: Role::Host,
    };
    let conn = bench.connect(&thief);
    assert_eq!(codes(bench.take()), refused(conn, "AUTH_INVALID", 4001));
    let wrong_role = Device {
        role: Role::Client,
        token: host.token.clone(),
        id: host.id.clone(),
        key: host.key.clone(),
    };
    let conn = bench.connect(&wrong_role);
    assert_eq!(codes(bench.take()), refused(conn, "AUTH_INVALID", 4001));
    bench.send(
        first,
        Control::Ping {
            nonce: "still here".into(),
        },
    );
    assert_eq!(
        bench.take(),
        vec![(
            first,
            Out::Text(Control::Pong {
                nonce: "still here".into()
            })
        )]
    );
}

#[test]
fn hello_must_arrive_within_five_seconds() {
    let mut bench = Bench::new();
    let conn = bench.socket(HOME);
    bench.advance(4_999);
    assert_eq!(bench.take(), vec![]);
    bench.advance(1);
    assert_eq!(codes(bench.take()), refused(conn, "AUTH_REQUIRED", 4001));
    assert_eq!(bench.core.conn_count(), 0);
}

#[test]
fn a_newer_hello_replaces_the_old_socket_and_keeps_its_links() {
    let (mut bench, host, host_conn, client, old) = Bench::pair();
    let link = bench.ready_link(host_conn, old, &host);
    let new = bench.connect(&client);
    assert_eq!(
        codes(bench.take()),
        [
            refused(old, "REPLACED", 4003),
            vec![(host_conn, peer(&link, PeerState::Away)), (new, ack())]
        ]
        .concat()
    );
    assert_eq!(bench.core.link_count(), 1);
    bench.core.socket_binary(old, &data(&link, 1), bench.now);
    assert_eq!(bench.take(), vec![], "the old socket is gone");
    bench.send(new, Control::Attach { link: link.clone() });
    assert_eq!(
        bench.take(),
        vec![
            (new, attached(&link, Presence::Present)),
            (host_conn, peer(&link, PeerState::Back))
        ]
    );
    bench
        .core
        .socket_binary(host_conn, &data(&link, 1), bench.now);
    assert_eq!(bench.take(), vec![(new, Out::Binary(data(&link, 1)))]);
    bench.core.socket_closed(old, bench.now);
    assert_eq!(
        bench.take(),
        vec![],
        "a late close of the replaced socket changes nothing"
    );
}

#[test]
fn open_accept_and_opened() {
    let (mut bench, host, host_conn, client, client_conn) = Bench::pair();
    let link = bench.open(client_conn, &host);
    assert_eq!(
        bench.take(),
        vec![(
            host_conn,
            Out::Text(Control::Incoming {
                link: link.clone(),
                client: client.id.clone(),
                client_key: client.key.clone(),
                handshake: "msg1".into()
            })
        )]
    );
    bench
        .core
        .socket_binary(client_conn, &data(&link, 1), bench.now);
    assert_eq!(
        bench.take(),
        vec![
            (host_conn, closed(&link, "INVALID")),
            (client_conn, closed(&link, "INVALID"))
        ],
        "no data before the link is ready"
    );
    assert_eq!(bench.core.link_count(), 0);
    let link = bench.open(client_conn, &host);
    bench.take();
    bench.send(
        host_conn,
        Control::Accept {
            link: link.clone(),
            handshake: "msg2".into(),
        },
    );
    assert_eq!(
        bench.take(),
        vec![(
            client_conn,
            Out::Text(Control::Opened {
                link: link.clone(),
                handshake: "msg2".into()
            })
        )]
    );
    assert_eq!(bench.core.link_count(), 1);
}

#[test]
fn hello_and_open_may_be_sent_together() {
    let (mut bench, host, host_conn, client, _) = Bench::pair();
    let conn = bench.socket(HOME);
    bench.send(conn, client.hello(false));
    let link = bench.open(conn, &host);
    let actions = bench.take();
    assert_eq!(actions.len(), 4);
    assert_eq!(actions[2], (conn, ack()));
    assert!(
        matches!(&actions[3], (to, Out::Text(Control::Incoming { link: l, .. })) if *to == host_conn && *l == link)
    );
}

#[test]
fn open_needs_the_host_online() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    let other_client = Device::new(Role::Client);
    bench.connect(&other_client);
    bench.take();
    let link = bench.open(client_conn, &other_client);
    assert_eq!(
        bench.take(),
        vec![(client_conn, closed(&link, "HOST_OFFLINE"))],
        "a client is not a host"
    );
    bench.core.socket_closed(host_conn, bench.now);
    let link = bench.open(client_conn, &host);
    assert_eq!(
        bench.take(),
        vec![(client_conn, closed(&link, "HOST_OFFLINE"))]
    );
    assert_eq!(bench.core.link_count(), 0);
}

#[test]
fn open_is_for_clients_with_new_link_ids() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    let link = bench.open(host_conn, &host);
    assert_eq!(bench.take(), vec![(host_conn, closed(&link, "INVALID"))]);
    bench.send(
        client_conn,
        Control::Open {
            link: "short".into(),
            host: host.id.clone(),
            handshake: "m".into(),
        },
    );
    assert_eq!(
        bench.take(),
        vec![(client_conn, closed("short", "INVALID"))]
    );
    let link = bench.ready_link(host_conn, client_conn, &host);
    bench.send(
        client_conn,
        Control::Open {
            link: link.clone(),
            host: host.id.clone(),
            handshake: "m".into(),
        },
    );
    assert_eq!(
        bench.take(),
        vec![
            (host_conn, closed(&link, "INVALID")),
            (client_conn, closed(&link, "INVALID"))
        ]
    );
    assert_eq!(bench.core.link_count(), 0);
}

#[test]
fn a_new_link_replaces_the_pair_s_old_one() {
    let (mut bench, host, host_conn, client, client_conn) = Bench::pair();
    let old = bench.ready_link(host_conn, client_conn, &host);
    let new = bench.open(client_conn, &host);
    assert_eq!(
        bench.take(),
        vec![
            (host_conn, closed(&old, "REPLACED")),
            (
                host_conn,
                Out::Text(Control::Incoming {
                    link: new.clone(),
                    client: client.id.clone(),
                    client_key: client.key.clone(),
                    handshake: "msg1".into()
                })
            ),
        ]
    );
    assert_eq!(bench.core.link_count(), 1);
}

#[test]
fn links_are_capped() {
    let mut bench = Bench::with(RelayConfig {
        max_links: 1,
        ..RelayConfig::default()
    });
    let (first, second, client) = (
        Device::new(Role::Host),
        Device::new(Role::Host),
        Device::new(Role::Client),
    );
    let (first_conn, _) = (bench.connect(&first), bench.connect(&second));
    let client_conn = bench.connect(&client);
    bench.take();
    bench.ready_link(first_conn, client_conn, &first);
    let link = bench.open(client_conn, &second);
    assert_eq!(
        bench.take(),
        vec![(client_conn, closed(&link, "RATE_LIMITED"))]
    );
    assert_eq!(bench.core.link_count(), 1);
}

#[test]
fn accept_comes_from_the_host_of_an_opening_link() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    let link = bench.open(client_conn, &host);
    bench.take();
    bench.send(
        client_conn,
        Control::Accept {
            link: link.clone(),
            handshake: "m".into(),
        },
    );
    assert_eq!(
        bench.take(),
        vec![
            (host_conn, closed(&link, "INVALID")),
            (client_conn, closed(&link, "INVALID"))
        ]
    );
    let unknown = LinkId::random().text();
    bench.send(
        host_conn,
        Control::Accept {
            link: unknown.clone(),
            handshake: "m".into(),
        },
    );
    assert_eq!(bench.take(), vec![(host_conn, closed(&unknown, "INVALID"))]);
    assert_eq!(bench.core.conn_count(), 2, "link faults keep the socket");
}

#[test]
fn binary_frames_are_forwarded_both_ways() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    let link = bench.ready_link(host_conn, client_conn, &host);
    bench
        .core
        .socket_binary(client_conn, &data(&link, 1), bench.now);
    let ack = encode_ack(LinkId::parse(&link).unwrap(), 1);
    bench.core.socket_binary(host_conn, &ack, bench.now);
    bench
        .core
        .socket_binary(host_conn, &data(&link, 1), bench.now);
    assert_eq!(
        bench.take(),
        vec![
            (host_conn, Out::Binary(data(&link, 1))),
            (client_conn, Out::Binary(ack)),
            (client_conn, Out::Binary(data(&link, 1)))
        ]
    );
}

#[test]
fn binary_frames_are_dropped_while_the_other_side_is_away() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    let link = bench.ready_link(host_conn, client_conn, &host);
    bench.core.socket_closed(host_conn, bench.now);
    assert_eq!(
        bench.take(),
        vec![(client_conn, peer(&link, PeerState::Away))]
    );
    bench
        .core
        .socket_binary(client_conn, &data(&link, 1), bench.now);
    assert_eq!(bench.take(), vec![]);
    assert_eq!(bench.core.link_count(), 1);
}

#[test]
fn binary_faults_stay_on_their_link() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    let link = bench.ready_link(host_conn, client_conn, &host);
    let stranger = Device::new(Role::Client);
    let stranger_conn = bench.connect(&stranger);
    bench.take();
    bench
        .core
        .socket_binary(stranger_conn, &data(&link, 1), bench.now);
    assert_eq!(
        bench.take(),
        vec![(stranger_conn, closed(&link, "INVALID"))]
    );
    let unknown = LinkId::random().text();
    bench
        .core
        .socket_binary(client_conn, &data(&unknown, 1), bench.now);
    assert_eq!(
        bench.take(),
        vec![(client_conn, closed(&unknown, "INVALID"))]
    );
    assert_eq!(bench.core.link_count(), 1);
    assert_eq!(bench.core.conn_count(), 3);
    let mut unknown_kind = data(&link, 1);
    unknown_kind[0] = 9;
    bench
        .core
        .socket_binary(client_conn, &unknown_kind, bench.now);
    assert_eq!(
        codes(bench.take()),
        [
            refused(client_conn, "INVALID_MESSAGE", 4001),
            vec![(host_conn, peer(&link, PeerState::Away))]
        ]
        .concat()
    );
}

#[test]
fn frames_over_the_size_limits_close_the_socket() {
    let (mut bench, _host, host_conn, _client, client_conn) = Bench::pair();
    bench
        .core
        .socket_text(host_conn, &"x".repeat(64 * 1024 + 1), bench.now);
    assert_eq!(
        codes(bench.take()),
        refused(host_conn, "INVALID_MESSAGE", 4001)
    );
    bench
        .core
        .socket_binary(client_conn, &vec![1; 1024 * 1024 + 1], bench.now);
    assert_eq!(
        codes(bench.take()),
        refused(client_conn, "INVALID_MESSAGE", 4001)
    );
}

#[test]
fn a_side_goes_away_and_comes_back() {
    let (mut bench, host, host_conn, client, client_conn) = Bench::pair();
    let link = bench.ready_link(host_conn, client_conn, &host);
    bench.core.socket_closed(client_conn, bench.now);
    assert_eq!(
        bench.take(),
        vec![(host_conn, peer(&link, PeerState::Away))]
    );
    let back = bench.connect(&client);
    bench.send(back, Control::Attach { link: link.clone() });
    assert_eq!(
        bench.take(),
        vec![
            (back, ack()),
            (back, attached(&link, Presence::Present)),
            (host_conn, peer(&link, PeerState::Back))
        ]
    );
    bench.core.socket_binary(back, &data(&link, 2), bench.now);
    assert_eq!(bench.take(), vec![(host_conn, Out::Binary(data(&link, 2)))]);
}

#[test]
fn attach_while_the_other_side_is_away() {
    let (mut bench, host, host_conn, client, client_conn) = Bench::pair();
    let link = bench.ready_link(host_conn, client_conn, &host);
    bench.core.socket_closed(host_conn, bench.now);
    bench.core.socket_closed(client_conn, bench.now);
    bench.take();
    let back = bench.connect(&client);
    bench.send(back, Control::Attach { link: link.clone() });
    assert_eq!(
        bench.take(),
        vec![(back, ack()), (back, attached(&link, Presence::Away))]
    );
    let host_back = bench.connect(&host);
    bench.send(host_back, Control::Attach { link: link.clone() });
    assert_eq!(
        bench.take(),
        vec![
            (host_back, ack()),
            (host_back, attached(&link, Presence::Present)),
            (back, peer(&link, PeerState::Back))
        ]
    );
}

#[test]
fn attach_to_a_gone_link() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    let unknown = LinkId::random().text();
    bench.send(
        client_conn,
        Control::Attach {
            link: unknown.clone(),
        },
    );
    assert_eq!(
        bench.take(),
        vec![(client_conn, closed(&unknown, "LINK_GONE"))]
    );
    let link = bench.ready_link(host_conn, client_conn, &host);
    let stranger = Device::new(Role::Client);
    let stranger_conn = bench.connect(&stranger);
    bench.send(stranger_conn, Control::Attach { link: link.clone() });
    assert_eq!(
        bench.take(),
        vec![
            (stranger_conn, ack()),
            (stranger_conn, closed(&link, "LINK_GONE"))
        ]
    );
    assert_eq!(bench.core.link_count(), 1);
}

#[test]
fn a_link_expires_after_the_grace_period() {
    let mut bench = Bench::with(RelayConfig {
        grace_ms: 10_000,
        ..RelayConfig::default()
    });
    let (host, client) = (Device::new(Role::Host), Device::new(Role::Client));
    let (host_conn, client_conn) = (bench.connect(&host), bench.connect(&client));
    let link = bench.ready_link(host_conn, client_conn, &host);
    bench.core.socket_closed(client_conn, bench.now);
    bench.take();
    bench.advance(9_999);
    assert_eq!(bench.take(), vec![]);
    bench.advance(1);
    assert_eq!(bench.take(), vec![(host_conn, closed(&link, "EXPIRED"))]);
    assert_eq!(bench.core.link_count(), 0);
    let back = bench.connect(&client);
    bench.send(back, Control::Attach { link: link.clone() });
    assert_eq!(
        bench.take(),
        vec![(back, ack_with(10_000)), (back, closed(&link, "LINK_GONE"))]
    );
}

#[test]
fn a_fresh_hello_ends_the_device_s_links() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    let link = bench.ready_link(host_conn, client_conn, &host);
    let restarted = bench.socket(HOME);
    bench.send(restarted, host.hello(true));
    assert_eq!(
        codes(bench.take()),
        [
            vec![(client_conn, closed(&link, "PEER_RESTARTED"))],
            refused(host_conn, "REPLACED", 4003),
            vec![(restarted, ack())]
        ]
        .concat()
    );
    assert_eq!(bench.core.link_count(), 0);
}

#[test]
fn an_opening_link_times_out() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    let link = bench.open(client_conn, &host);
    bench.take();
    bench.advance(29_999);
    assert_eq!(bench.take(), vec![]);
    bench.advance(1);
    assert_eq!(
        bench.take(),
        vec![
            (host_conn, closed(&link, "TIMEOUT")),
            (client_conn, closed(&link, "TIMEOUT"))
        ]
    );
    assert_eq!(bench.core.link_count(), 0);
}

#[test]
fn an_opening_link_ends_with_its_socket() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    let link = bench.open(client_conn, &host);
    bench.take();
    bench.core.socket_closed(host_conn, bench.now);
    assert_eq!(
        bench.take(),
        vec![(client_conn, closed(&link, "CONNECTION_LOST"))]
    );
    assert_eq!(bench.core.link_count(), 0);
}

#[test]
fn close_is_passed_on_with_its_code() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    let link = bench.open(client_conn, &host);
    bench.take();
    bench.send(
        host_conn,
        Control::Close {
            link: link.clone(),
            code: "NOT_PAIRED".into(),
        },
    );
    assert_eq!(
        bench.take(),
        vec![(client_conn, closed(&link, "NOT_PAIRED"))]
    );
    let link = bench.ready_link(host_conn, client_conn, &host);
    let stranger = Device::new(Role::Client);
    let stranger_conn = bench.connect(&stranger);
    bench.send(
        stranger_conn,
        Control::Close {
            link: link.clone(),
            code: "CLOSED".into(),
        },
    );
    assert_eq!(
        bench.take(),
        vec![(stranger_conn, ack())],
        "only a side may close a link"
    );
    bench.send(
        client_conn,
        Control::Close {
            link: link.clone(),
            code: "CLOSED".into(),
        },
    );
    assert_eq!(bench.take(), vec![(host_conn, closed(&link, "CLOSED"))]);
    assert_eq!(bench.core.link_count(), 0);
}

#[test]
fn app_ping_gets_a_pong() {
    let (mut bench, _host, host_conn, _client, _) = Bench::pair();
    bench.send(
        host_conn,
        Control::Ping {
            nonce: "abc".into(),
        },
    );
    assert_eq!(
        bench.take(),
        vec![(
            host_conn,
            Out::Text(Control::Pong {
                nonce: "abc".into()
            })
        )]
    );
}

#[test]
fn frames_from_the_relay_are_not_accepted() {
    let (mut bench, _host, host_conn, _client, _) = Bench::pair();
    bench.send(
        host_conn,
        Control::Pong {
            nonce: "abc".into(),
        },
    );
    assert_eq!(
        codes(bench.take()),
        refused(host_conn, "INVALID_MESSAGE", 4001)
    );
}

#[test]
fn sockets_are_pinged_and_closed_when_silent() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    bench.advance(15_000);
    assert_eq!(
        bench.take_all(),
        vec![(host_conn, Out::Ping), (client_conn, Out::Ping)]
    );
    bench.core.socket_pong(client_conn, bench.now);
    bench.advance(15_000);
    assert_eq!(
        bench.take_all(),
        vec![(host_conn, Out::Ping), (client_conn, Out::Ping)]
    );
    bench.advance(14_999);
    assert_eq!(bench.take_all(), vec![]);
    bench.advance(1);
    assert_eq!(
        bench.take_all(),
        vec![
            (host_conn, Out::Close(4001, "TIMEOUT".into())),
            (client_conn, Out::Ping)
        ]
    );
    let link = bench.open(client_conn, &host);
    assert_eq!(
        bench.take(),
        vec![(client_conn, closed(&link, "HOST_OFFLINE"))]
    );
    bench.advance(44_999);
    assert_eq!(
        bench.take_all(),
        vec![(client_conn, Out::Ping)],
        "any frame counts as heard"
    );
    bench.advance(1);
    assert_eq!(
        bench.take_all(),
        vec![(client_conn, Out::Close(4001, "TIMEOUT".into()))]
    );
}

#[test]
fn sockets_are_rate_limited_per_second() {
    let (mut bench, host, host_conn, _client, client_conn) = Bench::pair();
    bench.advance(1_000);
    for _ in 0..512 {
        bench.send(host_conn, Control::Ping { nonce: "n".into() });
    }
    assert_eq!(bench.take().len(), 512);
    bench.advance(1_000);
    bench.send(host_conn, Control::Ping { nonce: "n".into() });
    assert_eq!(bench.take().len(), 1, "the window starts over each second");
    for _ in 0..512 {
        bench.send(host_conn, Control::Ping { nonce: "n".into() });
    }
    assert_eq!(
        codes(bench.take()).last(),
        refused(host_conn, "RATE_LIMITED", 4001).last()
    );
    let host_conn = bench.connect(&host);
    let link = bench.ready_link(host_conn, client_conn, &host);
    bench.advance(1_000);
    bench.take();
    let big = encode_data(
        LinkId::parse(&link).unwrap(),
        1,
        0,
        &vec![0; 1024 * 1024 - 33],
    );
    for _ in 0..8 {
        bench.core.socket_binary(client_conn, &big, bench.now);
    }
    assert_eq!(bench.take().len(), 8);
    bench.core.socket_binary(client_conn, &big, bench.now);
    assert_eq!(
        codes(bench.take())[..2],
        refused(client_conn, "RATE_LIMITED", 4001)[..]
    );
}

#[test]
fn addresses_are_capped_per_hour() {
    let mut bench = Bench::with(RelayConfig {
        max_bytes_per_hour: 2_000,
        ..RelayConfig::default()
    });
    let host = Device::new(Role::Host);
    let conn = bench.connect(&host);
    bench.take();
    let ping = Control::Ping {
        nonce: "x".repeat(100),
    };
    let mut sent = host.hello(false).encode().len();
    while sent + ping.encode().len() <= 2_000 {
        bench.send(conn, ping.clone());
        sent += ping.encode().len();
    }
    assert!(
        bench
            .take()
            .iter()
            .all(|(_, out)| matches!(out, Out::Text(Control::Pong { .. })))
    );
    bench.send(conn, ping.clone());
    assert_eq!(codes(bench.take()), refused(conn, "RATE_LIMITED", 4001));
    let again = bench.connect(&host);
    assert_eq!(
        codes(bench.take()),
        refused(again, "RATE_LIMITED", 4001),
        "the cap is per address, not per socket"
    );
    let elsewhere = bench.connect_from(&host, "198.51.100.7");
    assert_eq!(bench.take(), vec![(elsewhere, ack())]);
    bench.now += 3_600_000;
    let later = bench.connect(&host);
    assert_eq!(
        codes(bench.take()),
        [refused(elsewhere, "REPLACED", 4003), vec![(later, ack())]].concat()
    );
}

#[test]
fn new_devices_are_capped_per_address() {
    let mut bench = Bench::with(RelayConfig {
        max_new_devices_per_hour: 2,
        ..RelayConfig::default()
    });
    let devices: Vec<Device> = (0..3).map(|_| Device::new(Role::Client)).collect();
    let first = bench.connect(&devices[0]);
    bench.connect(&devices[1]);
    let third = bench.connect(&devices[2]);
    assert_eq!(
        codes(bench.take())[2..],
        refused(third, "RATE_LIMITED", 4001)[..]
    );
    bench.core.socket_closed(first, bench.now);
    let known = bench.connect(&devices[0]);
    assert_eq!(
        bench.take(),
        vec![(known, ack())],
        "known devices are not counted"
    );
    let elsewhere = bench.connect_from(&devices[2], "198.51.100.7");
    assert_eq!(bench.take(), vec![(elsewhere, ack())]);
    bench.advance(3_600_000);
    bench.take();
    let fourth = Device::new(Role::Client);
    let conn = bench.connect(&fourth);
    assert_eq!(bench.take(), vec![(conn, ack())]);
}

#[test]
fn sockets_are_capped_in_total_and_per_address() {
    let mut bench = Bench::with(RelayConfig {
        max_sockets: 3,
        max_sockets_per_address: 2,
        ..RelayConfig::default()
    });
    assert_eq!(bench.core.admit_socket("a"), Ok(()));
    assert_eq!(bench.core.admit_socket("a"), Ok(()));
    assert_eq!(bench.core.admit_socket("a"), Err(Refusal::TooMany));
    assert_eq!(bench.core.admit_socket("b"), Ok(()));
    assert_eq!(bench.core.admit_socket("c"), Err(Refusal::Forbidden));
    assert_eq!(bench.core.socket_count(), 3);
    bench.core.release_socket("a");
    assert_eq!(bench.core.admit_socket("c"), Ok(()));
    bench.core.release_socket("unknown");
    assert_eq!(bench.core.socket_count(), 3);
}

#[test]
fn devices_not_seen_are_forgotten_but_online_ones_are_kept() {
    let mut store = DeviceStore::new();
    store
        .admit("d-old", Role::Client, "k", "t", START - 10 * 86_400_000)
        .unwrap();
    let config = RelayConfig {
        device_ttl_ms: Some(86_400_000),
        ..RelayConfig::default()
    };
    let mut bench = Bench {
        core: RelayCore::new(config, store, START),
        now: START,
        next: 1,
    };
    assert!(bench.core.store().get("d-old").is_none(), "pruned at start");
    let (online, offline) = (Device::new(Role::Host), Device::new(Role::Client));
    let online_conn = bench.connect(&online);
    let offline_conn = bench.connect(&offline);
    bench.core.socket_closed(offline_conn, bench.now);
    for _ in 0..(86_400_000 + 3_600_000) / 30_000 {
        bench.core.socket_pong(online_conn, bench.now);
        bench.advance(30_000);
    }
    assert!(bench.core.store().get(&offline.id).is_none());
    assert!(bench.core.store().get(&online.id).is_some());
}
