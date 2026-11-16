//! The Relay Server's rules, without IO or a clock: the runtime passes socket events and
//! the time in, and carries out the actions it drains with `poll_action`.

use std::collections::{BTreeMap, HashMap, VecDeque};

use dsbot_link_core::LinkError;
use dsbot_link_core::keys::device_id_for;
use dsbot_link_core::wire::{
    Control, LinkId, MAX_CONTROL_BYTES, MAX_FRAME_BYTES, PROTOCOL, PeerState, Presence, Role,
    binary_link,
};

use crate::store::DeviceStore;

pub type ConnId = u64;

pub const HEARTBEAT_MS: u64 = 15_000;
const SILENCE_LIMIT_MS: u64 = 3 * HEARTBEAT_MS;
const HELLO_DEADLINE_MS: u64 = 5_000;
const OPEN_DEADLINE_MS: u64 = 30_000;
const HOUR_MS: u64 = 3_600_000;
const RATE_WINDOW_MS: u64 = 1_000;
const MAX_FRAMES_PER_SECOND: u32 = 512;
const MAX_BYTES_PER_SECOND: u64 = 8 * 1024 * 1024;
const TOKEN_CHARS: std::ops::RangeInclusive<usize> = 32..=256;
const CLOSE_ERROR: u16 = 4001;
const CLOSE_REPLACED: u16 = 4003;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RelayConfig {
    pub server_version: String,
    pub max_sockets: usize,
    pub max_links: usize,
    pub max_sockets_per_address: usize,
    pub max_new_devices_per_hour: u32,
    pub max_bytes_per_hour: u64,
    pub grace_ms: u64,
    pub device_ttl_ms: Option<u64>,
}

impl Default for RelayConfig {
    fn default() -> Self {
        Self {
            server_version: format!("dsbot-link-relay/{}", env!("CARGO_PKG_VERSION")),
            max_sockets: 1024,
            max_links: 1024,
            max_sockets_per_address: 256,
            max_new_devices_per_hour: 20,
            max_bytes_per_hour: 512 * 1024 * 1024,
            grace_ms: 120_000,
            device_ttl_ms: None,
        }
    }
}

/// Why a socket was turned away before its WebSocket upgrade.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// 403: the relay holds as many sockets as it may.
    Forbidden,
    /// 429: the address holds as many sockets as it may.
    TooMany,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RelayAction {
    SendText {
        conn: ConnId,
        text: String,
    },
    SendBinary {
        conn: ConnId,
        data: Vec<u8>,
    },
    /// A WebSocket protocol ping.
    Ping {
        conn: ConnId,
    },
    /// The relay has already forgotten the socket; a later `socket_closed` for it does nothing.
    Close {
        conn: ConnId,
        code: u16,
        reason: String,
    },
}

#[derive(Clone, Debug)]
struct Peer {
    device: String,
    role: Role,
}

struct Conn {
    address: String,
    peer: Option<Peer>,
    opened_at: u64,
    heard_at: u64,
    pinged_at: u64,
    window_start: u64,
    window_frames: u32,
    window_bytes: u64,
}

struct Side {
    device: String,
    conn: Option<ConnId>,
    left_at: u64,
}

impl Side {
    fn bound(device: &str, conn: ConnId) -> Self {
        Self {
            device: device.into(),
            conn: Some(conn),
            left_at: 0,
        }
    }
}

struct Link {
    host: Side,
    client: Side,
    ready: bool,
    created_at: u64,
}

impl Link {
    fn has(&self, device: &str) -> bool {
        self.host.device == device || self.client.device == device
    }

    fn sides_mut(&mut self, device: &str) -> (&mut Side, &mut Side) {
        if self.host.device == device {
            (&mut self.host, &mut self.client)
        } else {
            (&mut self.client, &mut self.host)
        }
    }

    fn bound(&self, conn: ConnId) -> bool {
        self.host.conn == Some(conn) || self.client.conn == Some(conn)
    }

    /// The other side's socket, for a `conn` bound to this link.
    fn peer_of(&self, conn: ConnId) -> Option<ConnId> {
        if self.host.conn == Some(conn) {
            self.client.conn
        } else {
            self.host.conn
        }
    }

    fn present(&self) -> impl Iterator<Item = ConnId> {
        self.host.conn.into_iter().chain(self.client.conn)
    }

    fn away_since(&self) -> Option<u64> {
        [&self.host, &self.client]
            .into_iter()
            .filter(|side| side.conn.is_none())
            .map(|side| side.left_at)
            .min()
    }
}

/// A fixed window that counts up to a limit and starts over once it is `length` old.
struct Window {
    start: u64,
    used: u64,
}

impl Window {
    fn new(now: u64) -> Self {
        Self {
            start: now,
            used: 0,
        }
    }

    fn charge(&mut self, amount: u64, limit: u64, length: u64, now: u64) -> bool {
        if now.saturating_sub(self.start) >= length {
            *self = Self::new(now);
        }
        self.used = self.used.saturating_add(amount);
        self.used <= limit
    }
}

pub struct RelayCore {
    config: RelayConfig,
    store: DeviceStore,
    sockets: usize,
    sockets_by_address: HashMap<String, usize>,
    conns: BTreeMap<ConnId, Conn>,
    online: HashMap<String, ConnId>,
    links: BTreeMap<LinkId, Link>,
    registrations: HashMap<String, Window>,
    traffic: HashMap<String, Window>,
    last_prune: Option<u64>,
    actions: VecDeque<RelayAction>,
}

impl RelayCore {
    pub fn new(config: RelayConfig, store: DeviceStore, now: u64) -> Self {
        let mut core = Self {
            config,
            store,
            sockets: 0,
            sockets_by_address: HashMap::new(),
            conns: BTreeMap::new(),
            online: HashMap::new(),
            links: BTreeMap::new(),
            registrations: HashMap::new(),
            traffic: HashMap::new(),
            last_prune: None,
            actions: VecDeque::new(),
        };
        core.prune(now);
        core
    }

    pub fn config(&self) -> &RelayConfig {
        &self.config
    }

    pub fn store(&self) -> &DeviceStore {
        &self.store
    }

    pub fn store_mut(&mut self) -> &mut DeviceStore {
        &mut self.store
    }

    /// TCP sockets admitted and not yet released, upgraded or not.
    pub fn socket_count(&self) -> usize {
        self.sockets
    }

    /// WebSockets the relay is still serving.
    pub fn conn_count(&self) -> usize {
        self.conns.len()
    }

    pub fn link_count(&self) -> usize {
        self.links.len()
    }

    pub fn poll_action(&mut self) -> Option<RelayAction> {
        self.actions.pop_front()
    }

    pub fn admit_socket(&mut self, address: &str) -> Result<(), Refusal> {
        if self.sockets >= self.config.max_sockets {
            return Err(Refusal::Forbidden);
        }
        let open = self.sockets_by_address.get(address).copied().unwrap_or(0);
        if open >= self.config.max_sockets_per_address {
            return Err(Refusal::TooMany);
        }
        self.sockets += 1;
        self.sockets_by_address.insert(address.into(), open + 1);
        Ok(())
    }

    pub fn release_socket(&mut self, address: &str) {
        let Some(open) = self.sockets_by_address.get_mut(address) else {
            return;
        };
        *open -= 1;
        if *open == 0 {
            self.sockets_by_address.remove(address);
        }
        self.sockets -= 1;
    }

    pub fn socket_opened(&mut self, conn: ConnId, address: &str, now: u64) {
        let state = Conn {
            address: address.into(),
            peer: None,
            opened_at: now,
            heard_at: now,
            pinged_at: now,
            window_start: now,
            window_frames: 0,
            window_bytes: 0,
        };
        self.conns.insert(conn, state);
    }

    pub fn socket_text(&mut self, conn: ConnId, text: &str, now: u64) {
        if !self.heard(conn, now) {
            return;
        }
        if let Err(error) = self
            .charge(conn, text.len(), now)
            .and_then(|()| self.text(conn, text, now))
        {
            self.fail(conn, &error, now);
        }
    }

    pub fn socket_binary(&mut self, conn: ConnId, data: &[u8], now: u64) {
        if !self.heard(conn, now) {
            return;
        }
        if let Err(error) = self
            .charge(conn, data.len(), now)
            .and_then(|()| self.binary(conn, data))
        {
            self.fail(conn, &error, now);
        }
    }

    pub fn socket_pong(&mut self, conn: ConnId, now: u64) {
        self.heard(conn, now);
    }

    pub fn socket_closed(&mut self, conn: ConnId, now: u64) {
        self.forget(conn, now);
    }

    pub fn tick(&mut self, now: u64) {
        self.prune(now);
        self.check_conns(now);
        self.check_links(now);
    }

    fn heard(&mut self, conn: ConnId, now: u64) -> bool {
        let Some(state) = self.conns.get_mut(&conn) else {
            return false;
        };
        state.heard_at = now;
        true
    }

    fn charge(&mut self, conn: ConnId, size: usize, now: u64) -> Result<(), LinkError> {
        let rate_limited = || LinkError::new("RATE_LIMITED", "Too much traffic.");
        let state = self.conns.get_mut(&conn).expect("checked by heard");
        if now.saturating_sub(state.window_start) >= RATE_WINDOW_MS {
            state.window_start = now;
            state.window_frames = 0;
            state.window_bytes = 0;
        }
        state.window_frames += 1;
        state.window_bytes += size as u64;
        if state.window_frames > MAX_FRAMES_PER_SECOND || state.window_bytes > MAX_BYTES_PER_SECOND
        {
            return Err(rate_limited());
        }
        let traffic = self
            .traffic
            .entry(state.address.clone())
            .or_insert_with(|| Window::new(now));
        if !traffic.charge(size as u64, self.config.max_bytes_per_hour, HOUR_MS, now) {
            return Err(rate_limited());
        }
        Ok(())
    }

    fn text(&mut self, conn: ConnId, text: &str, now: u64) -> Result<(), LinkError> {
        if text.len() > MAX_CONTROL_BYTES {
            return Err(LinkError::new(
                "INVALID_MESSAGE",
                "A control frame is too large.",
            ));
        }
        let control = Control::decode(text);
        match self.conns[&conn].peer.clone() {
            None => self.hello(conn, control?, now),
            Some(peer) => self.control(conn, &peer, control?, now),
        }
    }

    fn hello(&mut self, conn: ConnId, control: Control, now: u64) -> Result<(), LinkError> {
        let Control::Hello {
            role,
            device_id,
            identity_key,
            access_token,
            protocols,
            fresh,
        } = control
        else {
            return Err(LinkError::new(
                "AUTH_REQUIRED",
                "The first frame must be a hello.",
            ));
        };
        let invalid = || LinkError::new("AUTH_INVALID", "The hello is invalid.");
        if !TOKEN_CHARS.contains(&access_token.chars().count()) {
            return Err(invalid());
        }
        if device_id_for(&identity_key).ok().as_deref() != Some(device_id.as_str()) {
            return Err(invalid());
        }
        if !protocols.contains(&PROTOCOL) {
            return Err(LinkError::new(
                "UNSUPPORTED_VERSION",
                "This Relay Server speaks protocol 2.",
            ));
        }
        if self.store.get(&device_id).is_none() {
            self.register_new(conn, now)?;
        }
        self.store
            .admit(&device_id, role, &identity_key, &access_token, now)?;
        if fresh {
            self.restart(&device_id);
        }
        if let Some(old) = self.online.get(&device_id).copied() {
            self.send(
                old,
                Control::Error {
                    code: "REPLACED".into(),
                    message: "A newer connection of this device took over.".into(),
                },
            );
            self.close(old, CLOSE_REPLACED, "REPLACED", now);
        }
        self.online.insert(device_id.clone(), conn);
        self.conns.get_mut(&conn).expect("open").peer = Some(Peer {
            device: device_id,
            role,
        });
        self.send(
            conn,
            Control::HelloAck {
                protocol: PROTOCOL,
                server: self.config.server_version.clone(),
                heartbeat_ms: HEARTBEAT_MS,
                grace_ms: self.config.grace_ms,
                max_frame_bytes: MAX_FRAME_BYTES as u64,
            },
        );
        Ok(())
    }

    fn register_new(&mut self, conn: ConnId, now: u64) -> Result<(), LinkError> {
        let address = self.conns[&conn].address.clone();
        let limit = u64::from(self.config.max_new_devices_per_hour);
        let window = self
            .registrations
            .entry(address)
            .or_insert_with(|| Window::new(now));
        if !window.charge(1, limit, HOUR_MS, now) {
            return Err(LinkError::new(
                "RATE_LIMITED",
                "Too many new devices from this address.",
            ));
        }
        Ok(())
    }

    /// The device's process restarted: the links it held cannot be resumed.
    fn restart(&mut self, device: &str) {
        let ids: Vec<LinkId> = self
            .links
            .iter()
            .filter(|(_, link)| link.has(device))
            .map(|(id, _)| *id)
            .collect();
        for id in ids {
            let mut link = self.links.remove(&id).expect("listed");
            let (_, other) = link.sides_mut(device);
            if let Some(other) = other.conn {
                self.send_closed(other, &id.text(), "PEER_RESTARTED");
            }
        }
    }

    fn control(
        &mut self,
        conn: ConnId,
        peer: &Peer,
        control: Control,
        now: u64,
    ) -> Result<(), LinkError> {
        match control {
            Control::Ping { nonce } => self.send(conn, Control::Pong { nonce }),
            Control::Open {
                link,
                host,
                handshake,
            } => self.open(conn, peer, &link, &host, handshake, now),
            Control::Accept { link, handshake } => self.accept(conn, peer, &link, handshake),
            Control::Attach { link } => self.attach(conn, peer, &link),
            Control::Close { link, code } => self.close_link(peer, &link, code),
            _ => {
                return Err(LinkError::new(
                    "INVALID_MESSAGE",
                    "This frame is not for the Relay Server.",
                ));
            }
        }
        Ok(())
    }

    fn open(
        &mut self,
        conn: ConnId,
        peer: &Peer,
        link: &str,
        host: &str,
        handshake: String,
        now: u64,
    ) {
        let id = match LinkId::parse(link) {
            Ok(id) if peer.role == Role::Client && !self.links.contains_key(&id) => id,
            _ => return self.link_fault(conn, peer, link),
        };
        let Some(host_conn) = self.online_host(host) else {
            return self.send_closed(conn, link, "HOST_OFFLINE");
        };
        self.replace_pair(&peer.device, host);
        if self.links.len() >= self.config.max_links {
            return self.send_closed(conn, link, "RATE_LIMITED");
        }
        let Some(client_key) = self
            .store
            .get(&peer.device)
            .map(|record| record.identity_key.clone())
        else {
            return self.send_closed(conn, link, "INVALID");
        };
        let opening = Link {
            host: Side::bound(host, host_conn),
            client: Side::bound(&peer.device, conn),
            ready: false,
            created_at: now,
        };
        self.links.insert(id, opening);
        self.send(
            host_conn,
            Control::Incoming {
                link: link.into(),
                client: peer.device.clone(),
                client_key,
                handshake,
            },
        );
    }

    fn online_host(&self, host: &str) -> Option<ConnId> {
        let conn = *self.online.get(host)?;
        let role = self.conns.get(&conn)?.peer.as_ref()?.role;
        (role == Role::Host).then_some(conn)
    }

    fn replace_pair(&mut self, client: &str, host: &str) {
        let ids: Vec<LinkId> = self
            .links
            .iter()
            .filter(|(_, link)| link.client.device == client && link.host.device == host)
            .map(|(id, _)| *id)
            .collect();
        for id in ids {
            let link = self.links.remove(&id).expect("listed");
            if let Some(host_conn) = link.host.conn {
                self.send_closed(host_conn, &id.text(), "REPLACED");
            }
        }
    }

    fn accept(&mut self, conn: ConnId, peer: &Peer, link: &str, handshake: String) {
        let opening = LinkId::parse(link)
            .ok()
            .and_then(|id| self.links.get_mut(&id))
            .filter(|found| !found.ready && found.host.conn == Some(conn));
        let Some(opening) = opening else {
            return self.link_fault(conn, peer, link);
        };
        opening.ready = true;
        if let Some(client) = opening.client.conn {
            self.send(
                client,
                Control::Opened {
                    link: link.into(),
                    handshake,
                },
            );
        }
    }

    fn attach(&mut self, conn: ConnId, peer: &Peer, link: &str) {
        let id = LinkId::parse(link).ok().filter(|id| {
            self.links
                .get(id)
                .is_some_and(|found| found.has(&peer.device))
        });
        let Some(id) = id else {
            return self.send_closed(conn, link, "LINK_GONE");
        };
        let found = self.links.get_mut(&id).expect("checked");
        if !found.ready {
            return self.link_fault(conn, peer, link);
        }
        let (mine, other) = found.sides_mut(&peer.device);
        mine.conn = Some(conn);
        let other = other.conn;
        let presence = if other.is_some() {
            Presence::Present
        } else {
            Presence::Away
        };
        self.send(
            conn,
            Control::Attached {
                link: link.into(),
                peer: presence,
            },
        );
        if let Some(other) = other {
            self.send(
                other,
                Control::Peer {
                    link: link.into(),
                    state: PeerState::Back,
                },
            );
        }
    }

    fn close_link(&mut self, peer: &Peer, link: &str, code: String) {
        let Ok(id) = LinkId::parse(link) else { return };
        if !self
            .links
            .get(&id)
            .is_some_and(|found| found.has(&peer.device))
        {
            return;
        }
        let mut closed = self.links.remove(&id).expect("checked");
        let (_, other) = closed.sides_mut(&peer.device);
        if let Some(other) = other.conn {
            self.send(
                other,
                Control::Closed {
                    link: link.into(),
                    code,
                },
            );
        }
    }

    fn binary(&mut self, conn: ConnId, data: &[u8]) -> Result<(), LinkError> {
        if data.len() > MAX_FRAME_BYTES {
            return Err(LinkError::new(
                "INVALID_MESSAGE",
                "A data frame is too large.",
            ));
        }
        let Some(peer) = self.conns[&conn].peer.clone() else {
            return Err(LinkError::new(
                "AUTH_REQUIRED",
                "The first frame must be a hello.",
            ));
        };
        let Some(id) = binary_link(data) else {
            return Err(LinkError::new(
                "INVALID_MESSAGE",
                "A data frame is invalid.",
            ));
        };
        let Some(link) = self
            .links
            .get(&id)
            .filter(|link| link.ready && link.bound(conn))
        else {
            self.link_fault(conn, &peer, &id.text());
            return Ok(());
        };
        if let Some(other) = link.peer_of(conn) {
            self.actions.push_back(RelayAction::SendBinary {
                conn: other,
                data: data.to_vec(),
            });
        }
        Ok(())
    }

    /// A protocol fault confined to one link: the sender's socket stays open. A link the sender
    /// is a side of ends for both sides, since `closed` must mean the link is gone.
    fn link_fault(&mut self, conn: ConnId, peer: &Peer, link: &str) {
        let removed = LinkId::parse(link).ok().filter(|id| {
            self.links
                .get(id)
                .is_some_and(|found| found.has(&peer.device))
        });
        if let Some(found) = removed.and_then(|id| self.links.remove(&id)) {
            for other in found.present().filter(|present| *present != conn) {
                self.send_closed(other, link, "INVALID");
            }
        }
        self.send_closed(conn, link, "INVALID");
    }

    fn send(&mut self, conn: ConnId, control: Control) {
        self.actions.push_back(RelayAction::SendText {
            conn,
            text: control.encode(),
        });
    }

    fn send_closed(&mut self, conn: ConnId, link: &str, code: &str) {
        self.send(
            conn,
            Control::Closed {
                link: link.into(),
                code: code.into(),
            },
        );
    }

    fn fail(&mut self, conn: ConnId, error: &LinkError, now: u64) {
        self.send(
            conn,
            Control::Error {
                code: error.code.clone(),
                message: error.message.clone(),
            },
        );
        self.close(conn, CLOSE_ERROR, &error.code, now);
    }

    fn close(&mut self, conn: ConnId, code: u16, reason: &str, now: u64) {
        self.actions.push_back(RelayAction::Close {
            conn,
            code,
            reason: reason.into(),
        });
        self.forget(conn, now);
    }

    /// The socket is gone: its device goes offline and the links it held lose that side.
    fn forget(&mut self, conn: ConnId, now: u64) {
        let Some(state) = self.conns.remove(&conn) else {
            return;
        };
        if let Some(peer) = state.peer {
            if self.online.get(&peer.device) == Some(&conn) {
                self.online.remove(&peer.device);
            }
        }
        let held: Vec<LinkId> = self
            .links
            .iter()
            .filter(|(_, link)| link.bound(conn))
            .map(|(id, _)| *id)
            .collect();
        for id in held {
            let link = self.links.get_mut(&id).expect("listed");
            let other = link.peer_of(conn);
            if !link.ready {
                self.links.remove(&id);
                if let Some(other) = other {
                    self.send_closed(other, &id.text(), "CONNECTION_LOST");
                }
                continue;
            }
            let side = if link.host.conn == Some(conn) {
                &mut link.host
            } else {
                &mut link.client
            };
            side.conn = None;
            side.left_at = now;
            if let Some(other) = other {
                self.send(
                    other,
                    Control::Peer {
                        link: id.text(),
                        state: PeerState::Away,
                    },
                );
            }
        }
    }

    fn check_conns(&mut self, now: u64) {
        let ids: Vec<ConnId> = self.conns.keys().copied().collect();
        for conn in ids {
            let Some(state) = self.conns.get_mut(&conn) else {
                continue;
            };
            if state.peer.is_none() && now.saturating_sub(state.opened_at) >= HELLO_DEADLINE_MS {
                self.fail(
                    conn,
                    &LinkError::new("AUTH_REQUIRED", "No hello within 5 seconds."),
                    now,
                );
            } else if now.saturating_sub(state.heard_at) >= SILENCE_LIMIT_MS {
                self.close(conn, CLOSE_ERROR, "TIMEOUT", now);
            } else if now.saturating_sub(state.pinged_at) >= HEARTBEAT_MS {
                state.pinged_at = now;
                self.actions.push_back(RelayAction::Ping { conn });
            }
        }
    }

    fn check_links(&mut self, now: u64) {
        let grace_ms = self.config.grace_ms;
        let ended: Vec<(LinkId, &str)> = self
            .links
            .iter()
            .filter_map(|(id, link)| {
                if !link.ready && now.saturating_sub(link.created_at) >= OPEN_DEADLINE_MS {
                    Some((*id, "TIMEOUT"))
                } else if link.ready
                    && link
                        .away_since()
                        .is_some_and(|since| now.saturating_sub(since) >= grace_ms)
                {
                    Some((*id, "EXPIRED"))
                } else {
                    None
                }
            })
            .collect();
        for (id, code) in ended {
            let link = self.links.remove(&id).expect("listed");
            for conn in link.present() {
                self.send_closed(conn, &id.text(), code);
            }
        }
    }

    fn prune(&mut self, now: u64) {
        self.registrations
            .retain(|_, window| now.saturating_sub(window.start) < HOUR_MS);
        self.traffic
            .retain(|_, window| now.saturating_sub(window.start) < HOUR_MS);
        let Some(ttl_ms) = self.config.device_ttl_ms else {
            return;
        };
        if self
            .last_prune
            .is_some_and(|at| now.saturating_sub(at) < HOUR_MS)
        {
            return;
        }
        self.last_prune = Some(now);
        for device in self.online.keys() {
            self.store.touch(device, now);
        }
        self.store.prune(ttl_ms, now);
    }
}

#[cfg(test)]
mod tests;
