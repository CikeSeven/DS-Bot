//! A simulated network for the sans-IO cores: one Relay Server, one computer and any
//! number of phones, with a clock the test moves and faults it injects. Every frame
//! takes `latency_ms` each way; a cut socket can close cleanly, vanish silently
//! (half-open) or stop carrying frames while staying open (a black hole).

use std::collections::{BTreeMap, HashMap, VecDeque};

use dsbot_link_client::{ClientAction, ClientConfig, ClientCore, LinkStatus};
use dsbot_link_core::keys::{Identity, generate_key_pair, random_token};
use dsbot_link_core::pairing::DeviceRegistry;
use dsbot_link_host::{DEFAULT_MAX_LINKS, HostAction, HostConfig, HostCore};
use dsbot_link_relay::{DeviceStore, RelayAction, RelayConfig, RelayCore};

pub const URL: &str = "ws://relay.test/v2/link";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Side {
    Host,
    Phone(usize),
}

#[derive(Debug, Clone)]
enum Frame {
    Text(String),
    Binary(Vec<u8>),
}

#[derive(Debug)]
enum Delivery {
    /// To the relay, from a socket.
    ToRelay {
        conn: u64,
        frame: Frame,
    },
    /// From the relay, to an endpoint's socket.
    ToEndpoint {
        conn: u64,
        frame: Frame,
    },
    RelayPong {
        conn: u64,
    },
    /// The relay closed this socket; the endpoint hears it.
    EndpointClosed {
        conn: u64,
    },
    /// The endpoint closed this socket; the relay hears it.
    RelayClosed {
        conn: u64,
    },
    EndpointOpened {
        conn: u64,
    },
}

#[derive(Debug)]
struct Socket {
    side: Side,
    local: u64,
    blackholed: bool,
    dead: bool,
}

pub struct Phone {
    pub core: ClientCore,
    pub statuses: Vec<LinkStatus>,
    pub events: Vec<(String, String)>,
    pub answers: BTreeMap<u64, Result<String, String>>,
    pub handshakes: usize,
    pub identity: Identity,
}

pub struct Host {
    pub core: HostCore,
    pub registry: DeviceRegistry,
    pub identity: Identity,
    pub token: String,
    /// Calls the app has not answered yet: (link, request, method, params).
    pub pending: Vec<(String, String, String, String)>,
    /// Answer calls at once with `{"echo": params}` instead of leaving them pending.
    pub auto_answer: bool,
    pub served: Vec<String>,
}

pub struct Net {
    pub now: u64,
    pub latency_ms: u64,
    pub relay: RelayCore,
    pub host: Host,
    pub phones: Vec<Phone>,
    sockets: HashMap<u64, Socket>,
    next_conn: u64,
    queue: BTreeMap<(u64, u64), Delivery>,
    seq: u64,
    pub relay_offline: bool,
    relay_tick_at: u64,
}

fn identity() -> Identity {
    let pair = generate_key_pair(None).unwrap();
    Identity::new(&pair.public_key, &pair.private_key).unwrap()
}

impl Net {
    pub fn new(grace_ms: u64) -> Self {
        let now = 1_000_000;
        let host_identity = identity();
        let token = random_token(32);
        let host = Host {
            core: HostCore::new(
                HostConfig {
                    server: URL.into(),
                    identity: host_identity.clone(),
                    access_token: token.clone(),
                    name: Some("Desk".into()),
                    max_links: DEFAULT_MAX_LINKS,
                },
                now,
            ),
            registry: DeviceRegistry::default(),
            identity: host_identity,
            token,
            pending: Vec::new(),
            auto_answer: true,
            served: Vec::new(),
        };
        let config = RelayConfig {
            grace_ms,
            ..RelayConfig::default()
        };
        Self {
            now,
            latency_ms: 20,
            relay: RelayCore::new(config, DeviceStore::new(), now),
            host,
            phones: Vec::new(),
            sockets: HashMap::new(),
            next_conn: 1,
            queue: BTreeMap::new(),
            seq: 0,
            relay_offline: false,
            relay_tick_at: now,
        }
    }

    /// Opens pairing on the computer and adds a phone that uses the code.
    pub fn add_phone(&mut self) -> usize {
        let (code, _) = self.host.registry.open_pairing(60_000, self.now);
        let identity = identity();
        let core = ClientCore::new(
            ClientConfig {
                server: URL.into(),
                identity: identity.clone(),
                access_token: random_token(32),
                host_device_id: self.host.identity.device_id.clone(),
                host_key: self.host.identity.public_key.clone(),
                name: Some(format!("Phone {}", self.phones.len())),
                pairing_code: Some(code),
            },
            self.now,
        );
        self.phones.push(Phone {
            core,
            statuses: Vec::new(),
            events: Vec::new(),
            answers: BTreeMap::new(),
            handshakes: 0,
            identity,
        });
        self.phones.len() - 1
    }

    pub fn start(&mut self) {
        self.host.core.start(self.now);
        for phone in &mut self.phones {
            phone.core.start(self.now);
        }
        self.drain();
    }

    /// Restarts the computer: a new HostCore with the same identity and paired phones.
    pub fn restart_host(&mut self) {
        let conns: Vec<u64> = self
            .sockets
            .iter()
            .filter(|(_, s)| s.side == Side::Host)
            .map(|(c, _)| *c)
            .collect();
        for conn in conns {
            self.cut(conn, true);
        }
        self.host.core = HostCore::new(
            HostConfig {
                server: URL.into(),
                identity: self.host.identity.clone(),
                access_token: self.host.token.clone(),
                name: Some("Desk".into()),
                max_links: DEFAULT_MAX_LINKS,
            },
            self.now,
        );
        self.host.pending.clear();
        self.host.core.start(self.now);
        self.drain();
    }

    fn push(&mut self, delay: u64, delivery: Delivery) {
        self.seq += 1;
        self.queue.insert((self.now + delay, self.seq), delivery);
    }

    pub fn conns_of(&self, side: Side) -> Vec<u64> {
        self.sockets
            .iter()
            .filter(|(_, s)| s.side == side && !s.dead)
            .map(|(c, _)| *c)
            .collect()
    }

    /// Ends a socket. `clean`: both ends hear it at once. Otherwise only the relay
    /// eventually notices (by its own liveness check) and the endpoint does not.
    pub fn cut(&mut self, conn: u64, clean: bool) {
        let Some(socket) = self.sockets.get_mut(&conn) else {
            return;
        };
        if socket.dead {
            return;
        }
        socket.dead = true;
        if clean {
            self.push(0, Delivery::EndpointClosed { conn });
            self.push(0, Delivery::RelayClosed { conn });
        }
    }

    /// Frames on this socket are lost from now on, in both directions; nobody is told.
    pub fn blackhole(&mut self, side: Side) {
        for conn in self.conns_of(side) {
            self.sockets.get_mut(&conn).unwrap().blackholed = true;
        }
    }

    /// Moves the clock, delivering frames and firing timers, in steps of at most 10 ms.
    pub fn run(&mut self, ms: u64) {
        let end = self.now + ms;
        loop {
            while let Some((&key, _)) = self.queue.first_key_value() {
                if key.0 > self.now {
                    break;
                }
                let delivery = self.queue.remove(&key).unwrap();
                self.deliver(delivery);
                self.drain();
            }
            self.tick();
            if self.now >= end {
                break;
            }
            let queued = self
                .queue
                .first_key_value()
                .map_or(u64::MAX, |(key, _)| key.0);
            self.now = (self.now + 10).min(queued).min(end).max(self.now + 1);
        }
    }

    pub fn run_until(&mut self, limit_ms: u64, mut done: impl FnMut(&Net) -> bool) -> bool {
        let end = self.now + limit_ms;
        while self.now < end {
            if done(self) {
                return true;
            }
            self.run(10);
        }
        done(self)
    }

    fn tick(&mut self) {
        let now = self.now;
        if self.host.core.next_deadline().is_some_and(|at| at <= now) {
            self.host.core.tick(now);
        }
        for phone in &mut self.phones {
            if phone.core.next_deadline().is_some_and(|at| at <= now) {
                phone.core.tick(now);
            }
        }
        if now >= self.relay_tick_at {
            self.relay_tick_at = now + 1_000;
            self.relay.tick(now);
        }
        self.drain();
    }

    fn deliver(&mut self, delivery: Delivery) {
        let now = self.now;
        match delivery {
            Delivery::EndpointOpened { conn } => {
                let Some(socket) = self.sockets.get(&conn) else {
                    return;
                };
                if socket.dead {
                    return;
                }
                let (side, local) = (socket.side, socket.local);
                self.relay.socket_opened(conn, "203.0.113.7", now);
                match side {
                    Side::Host => self.host.core.socket_opened(local, now),
                    Side::Phone(i) => self.phones[i].core.socket_opened(local, now),
                }
            }
            Delivery::ToRelay { conn, frame } => {
                if self
                    .sockets
                    .get(&conn)
                    .is_none_or(|s| s.dead || s.blackholed)
                {
                    return;
                }
                match frame {
                    Frame::Text(text) => self.relay.socket_text(conn, &text, now),
                    Frame::Binary(data) => self.relay.socket_binary(conn, &data, now),
                }
            }
            Delivery::RelayPong { conn } => {
                if self
                    .sockets
                    .get(&conn)
                    .is_some_and(|s| !s.dead && !s.blackholed)
                {
                    self.relay.socket_pong(conn, now);
                }
            }
            Delivery::ToEndpoint { conn, frame } => {
                let Some(socket) = self.sockets.get(&conn) else {
                    return;
                };
                if socket.dead || socket.blackholed {
                    return;
                }
                let (side, local) = (socket.side, socket.local);
                match (side, frame) {
                    (Side::Host, Frame::Text(text)) => {
                        self.host.core.socket_text(local, &text, now)
                    }
                    (Side::Host, Frame::Binary(data)) => {
                        self.host.core.socket_binary(local, &data, now)
                    }
                    (Side::Phone(i), Frame::Text(text)) => {
                        self.phones[i].core.socket_text(local, &text, now)
                    }
                    (Side::Phone(i), Frame::Binary(data)) => {
                        self.phones[i].core.socket_binary(local, &data, now)
                    }
                }
            }
            Delivery::EndpointClosed { conn } => {
                let Some(socket) = self.sockets.get(&conn) else {
                    return;
                };
                let (side, local) = (socket.side, socket.local);
                match side {
                    Side::Host => self.host.core.socket_closed(local, Some("closed"), now),
                    Side::Phone(i) => self.phones[i]
                        .core
                        .socket_closed(local, Some("closed"), now),
                }
            }
            Delivery::RelayClosed { conn } => {
                self.relay.socket_closed(conn, now);
                self.relay.release_socket("203.0.113.7");
            }
        }
    }

    fn conn_for(&self, side: Side, local: u64) -> Option<u64> {
        self.sockets
            .iter()
            .find(|(_, s)| s.side == side && s.local == local)
            .map(|(c, _)| *c)
    }

    fn connect(&mut self, side: Side, local: u64) {
        let conn = self.next_conn;
        self.next_conn += 1;
        self.sockets.insert(
            conn,
            Socket {
                side,
                local,
                blackholed: false,
                dead: false,
            },
        );
        if self.relay_offline || self.relay.admit_socket("203.0.113.7").is_err() {
            self.sockets.get_mut(&conn).unwrap().dead = true;
            self.push(self.latency_ms, Delivery::EndpointClosed { conn });
            return;
        }
        // TCP, TLS and the upgrade: a round trip and a half.
        self.push(self.latency_ms * 3, Delivery::EndpointOpened { conn });
    }

    fn endpoint_close(&mut self, side: Side, local: u64) {
        if let Some(conn) = self.conn_for(side, local) {
            let socket = self.sockets.get_mut(&conn).unwrap();
            if !socket.dead {
                socket.dead = true;
                let silent = socket.blackholed;
                if !silent {
                    self.push(self.latency_ms, Delivery::RelayClosed { conn });
                }
            }
        }
    }

    fn endpoint_send(&mut self, side: Side, local: u64, frame: Frame) {
        if let Some(conn) = self.conn_for(side, local) {
            self.push(self.latency_ms, Delivery::ToRelay { conn, frame });
        }
    }

    /// Carries out every action the cores have queued, until none is left.
    pub fn drain(&mut self) {
        loop {
            let mut busy = false;
            while let Some(action) = self.relay.poll_action() {
                busy = true;
                match action {
                    RelayAction::SendText { conn, text } => self.push(
                        self.latency_ms,
                        Delivery::ToEndpoint {
                            conn,
                            frame: Frame::Text(text),
                        },
                    ),
                    RelayAction::SendBinary { conn, data } => self.push(
                        self.latency_ms,
                        Delivery::ToEndpoint {
                            conn,
                            frame: Frame::Binary(data),
                        },
                    ),
                    RelayAction::Ping { conn } => {
                        // The endpoint's WebSocket answers pings by itself.
                        if self.sockets.get(&conn).is_some_and(|s| !s.dead) {
                            self.push(self.latency_ms * 2, Delivery::RelayPong { conn });
                        }
                    }
                    RelayAction::Close { conn, .. } => {
                        if let Some(socket) = self.sockets.get_mut(&conn)
                            && !socket.dead
                        {
                            socket.dead = true;
                            if !socket.blackholed {
                                self.push(self.latency_ms, Delivery::EndpointClosed { conn });
                            }
                            self.push(0, Delivery::RelayClosed { conn });
                        }
                    }
                }
            }
            while let Some(action) = self.host.core.poll_action() {
                busy = true;
                self.host_action(action);
            }
            for i in 0..self.phones.len() {
                while let Some(action) = self.phones[i].core.poll_action() {
                    busy = true;
                    self.phone_action(i, action);
                }
            }
            if !busy {
                break;
            }
        }
    }

    fn host_action(&mut self, action: HostAction) {
        let now = self.now;
        match action {
            HostAction::Connect { socket, .. } => self.connect(Side::Host, socket),
            HostAction::SendText { socket, text } => {
                self.endpoint_send(Side::Host, socket, Frame::Text(text))
            }
            HostAction::SendBinary { socket, data } => {
                self.endpoint_send(Side::Host, socket, Frame::Binary(data))
            }
            HostAction::CloseSocket { socket } => self.endpoint_close(Side::Host, socket),
            HostAction::Authorize {
                link,
                device_id,
                identity_key,
                name,
                pairing_code,
            } => {
                let hello = dsbot_link_core::pairing::HandshakeHello { name, pairing_code };
                let allowed = self.host.registry.admits(&device_id, &identity_key, now)
                    && self
                        .host
                        .registry
                        .authorize(&device_id, &identity_key, &hello, now)
                        .0;
                self.host.core.authorize(&link, allowed, now);
            }
            HostAction::Request {
                link,
                request,
                method,
                params,
                ..
            } => {
                self.host.served.push(params.clone());
                if self.host.auto_answer {
                    self.host.core.respond(
                        &link,
                        &request,
                        &format!(r#"{{"echo":{params}}}"#),
                        now,
                    );
                } else {
                    self.host.pending.push((link, request, method, params));
                }
            }
            HostAction::Cancel { request, .. } => {
                self.host.pending.retain(|(_, r, _, _)| *r != request)
            }
            HostAction::Status(_) | HostAction::ReadyCount(_) => {}
        }
    }

    fn phone_action(&mut self, i: usize, action: ClientAction) {
        let side = Side::Phone(i);
        match action {
            ClientAction::Connect { socket, .. } => self.connect(side, socket),
            ClientAction::SendText { socket, text } => {
                self.endpoint_send(side, socket, Frame::Text(text))
            }
            ClientAction::SendBinary { socket, data } => {
                self.endpoint_send(side, socket, Frame::Binary(data))
            }
            ClientAction::CloseSocket { socket } => self.endpoint_close(side, socket),
            ClientAction::Status(status) => {
                if status == (LinkStatus::Online { resumed: false }) {
                    self.phones[i].handshakes += 1;
                }
                self.phones[i].statuses.push(status);
            }
            ClientAction::Event { name, data } => self.phones[i].events.push((name, data)),
            ClientAction::RpcDone { call, result } => {
                self.phones[i]
                    .answers
                    .insert(call, result.map_err(|error| error.code));
            }
        }
    }

    pub fn status(&self, phone: usize) -> Option<&LinkStatus> {
        self.phones[phone].core.status()
    }

    pub fn online(&self, phone: usize) -> bool {
        matches!(self.status(phone), Some(LinkStatus::Online { .. }))
    }

    pub fn rpc(&mut self, phone: usize, params: &str) -> u64 {
        let call = self.phones[phone].core.rpc("bot", params, 0, self.now);
        self.drain();
        call
    }

    pub fn emit(&mut self, event: &str, data: &str) {
        self.host.core.emit(event, data, self.now);
        self.drain();
    }

    pub fn answer_pending(&mut self) {
        let now = self.now;
        for (link, request, _, params) in std::mem::take(&mut self.host.pending) {
            self.host
                .core
                .respond(&link, &request, &format!(r#"{{"echo":{params}}}"#), now);
        }
        self.drain();
    }

    pub fn network_changed(&mut self, phone: usize) {
        self.phones[phone].core.network_changed(self.now);
        self.drain();
    }

    pub fn set_foreground(&mut self, phone: usize, foreground: bool) {
        self.phones[phone].core.set_foreground(foreground, self.now);
        self.drain();
    }

    pub fn queued(&self) -> usize {
        self.queue.len()
    }

    pub fn pending_frames(&self) -> VecDeque<String> {
        self.queue.values().map(|d| format!("{d:?}")).collect()
    }
}
