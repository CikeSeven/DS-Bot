//! The computer's end of the DS Bot link: one socket to the Relay Server, a link
//! per phone, the phone's calls handed to the app and its answers sent back. It
//! runs a call once and never repeats one.

use std::collections::{HashSet, VecDeque};

use dsbot_link_core::LinkError;
use dsbot_link_core::b64;
use dsbot_link_core::channel::{Channel, HOST_CAP_BYTES, Pacer};
use dsbot_link_core::conn::{Conn, ConnConfig, ConnOut, SocketId};
use dsbot_link_core::keys::{Identity, device_id_for, key_bytes};
use dsbot_link_core::message::{self, Message};
use dsbot_link_core::noise::{Handshake, prologue};
use dsbot_link_core::pairing::HandshakeHello;
use dsbot_link_core::wire::{Binary, Control, LinkId, PROTOCOL, PeerState, Presence, Role};

const SILENCE_MS: u64 = 20_000;
const PROBE_MS: u64 = 10_000;
const CONNECT_TIMEOUT_MS: u64 = 10_000;
const BACKOFF_CAP_MS: u64 = 30_000;
const MAX_CALLS_PER_LINK: usize = 32;
pub const DEFAULT_MAX_LINKS: usize = 16;

#[derive(Clone, Debug)]
pub struct HostConfig {
    pub server: String,
    pub identity: Identity,
    pub access_token: String,
    pub name: Option<String>,
    pub max_links: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostStatus {
    Stopped,
    Connecting,
    Online,
    Offline,
}

impl HostStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stopped => "stopped",
            Self::Connecting => "connecting",
            Self::Online => "online",
            Self::Offline => "offline",
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum HostAction {
    Connect {
        socket: SocketId,
        url: String,
    },
    SendText {
        socket: SocketId,
        text: String,
    },
    SendBinary {
        socket: SocketId,
        data: Vec<u8>,
    },
    CloseSocket {
        socket: SocketId,
    },
    Status(HostStatus),
    /// A phone finished its half of the handshake; answer with `authorize`.
    Authorize {
        link: String,
        device_id: String,
        identity_key: String,
        name: Option<String>,
        pairing_code: Option<String>,
    },
    /// A call to run; answer with `respond` or `respond_error`.
    Request {
        link: String,
        request: String,
        device_id: String,
        method: String,
        params: String,
    },
    /// The link of a running call closed; its answer will not be sent.
    Cancel {
        link: String,
        request: String,
    },
    /// Links that finished their handshake, including those whose phone is away for now.
    ReadyCount(usize),
}

enum Stage {
    Authorizing {
        handshake: Box<Handshake>,
    },
    Ready {
        channel: Box<Channel>,
        attached: bool,
        peer_present: bool,
    },
}

struct PhoneLink {
    id: LinkId,
    device_id: String,
    stage: Stage,
    calls: HashSet<String>,
}

pub struct HostCore {
    config: HostConfig,
    conn: Conn,
    links: Vec<PhoneLink>,
    pacer: Pacer,
    fresh: bool,
    status: HostStatus,
    ready_count: usize,
    actions: VecDeque<HostAction>,
}

impl HostCore {
    pub fn new(config: HostConfig, now: u64) -> Self {
        let conn = Conn::new(ConnConfig {
            url: config.server.clone(),
            silence_ms: SILENCE_MS,
            probe_ms: PROBE_MS,
            connect_timeout_ms: CONNECT_TIMEOUT_MS,
            backoff_cap_ms: BACKOFF_CAP_MS,
        });
        Self {
            config,
            conn,
            links: Vec::new(),
            pacer: Pacer::new(now),
            fresh: true,
            status: HostStatus::Stopped,
            ready_count: 0,
            actions: VecDeque::new(),
        }
    }

    pub fn status(&self) -> HostStatus {
        self.status
    }

    pub fn error(&self) -> Option<&str> {
        self.conn.error()
    }

    /// Phones with a finished handshake that are on the Server now. While this side's own
    /// socket is down nothing is known, so none are.
    pub fn connected_devices(&self) -> Vec<String> {
        let mut devices: Vec<String> = self
            .links
            .iter()
            .filter(|link| {
                matches!(
                    link.stage,
                    Stage::Ready {
                        attached: true,
                        peer_present: true,
                        ..
                    }
                )
            })
            .map(|link| link.device_id.clone())
            .collect();
        devices.sort_unstable();
        devices.dedup();
        devices
    }

    pub fn poll_action(&mut self) -> Option<HostAction> {
        self.actions.pop_front()
    }

    pub fn start(&mut self, now: u64) {
        self.conn.start(now);
        self.step(now);
    }

    pub fn stop(&mut self, now: u64) {
        let mut out = Vec::new();
        self.conn.stop(&mut out);
        self.conn_out(out);
        for at in (0..self.links.len()).rev() {
            self.drop_link(at);
        }
        self.step(now);
    }

    pub fn socket_opened(&mut self, socket: SocketId, now: u64) {
        if !self.conn.opened(socket, now) {
            return;
        }
        self.send_text(
            socket,
            Control::Hello {
                role: Role::Host,
                device_id: self.config.identity.device_id.clone(),
                identity_key: self.config.identity.public_key.clone(),
                access_token: self.config.access_token.clone(),
                protocols: vec![PROTOCOL],
                fresh: self.fresh,
            },
        );
        let attach: Vec<String> = self
            .links
            .iter()
            .filter(|link| matches!(link.stage, Stage::Ready { .. }))
            .map(|link| link.id.text())
            .collect();
        for link in attach {
            self.send_text(socket, Control::Attach { link });
        }
        self.step(now);
    }

    pub fn socket_text(&mut self, socket: SocketId, text: &str, now: u64) {
        if !self.conn.heard(socket, now) {
            return;
        }
        if let Ok(control) = Control::decode(text) {
            self.control(socket, control, now);
        }
        self.step(now);
    }

    pub fn socket_binary(&mut self, socket: SocketId, data: &[u8], now: u64) {
        if !self.conn.heard(socket, now) {
            return;
        }
        let Ok(frame) = Binary::decode(data) else {
            return;
        };
        let Some(at) = self.find(frame.link()) else {
            return;
        };
        let Stage::Ready { channel, .. } = &mut self.links[at].stage else {
            return;
        };
        match channel.receive(frame, now) {
            Ok(messages) => {
                for bytes in messages {
                    self.serve(at, &bytes, now);
                }
            }
            Err(_) => self.close_link(at, "INVALID"),
        }
        self.step(now);
    }

    pub fn socket_closed(&mut self, socket: SocketId, reason: Option<&str>, now: u64) {
        if self.conn.lost(socket, reason, now) {
            self.socket_gone();
        }
        self.step(now);
    }

    pub fn tick(&mut self, now: u64) {
        for link in &mut self.links {
            if let Stage::Ready { channel, .. } = &mut link.stage {
                channel.tick(now);
            }
        }
        self.step(now);
    }

    /// The app's verdict on a phone that asked to connect.
    pub fn authorize(&mut self, link: &str, allowed: bool, now: u64) {
        let Some(at) = self.links.iter().position(|item| item.id.text() == link) else {
            return;
        };
        if !matches!(self.links[at].stage, Stage::Authorizing { .. }) {
            return;
        }
        if !allowed {
            self.close_link(at, "NOT_PAIRED");
            return self.step(now);
        }
        let Some(socket) = self.conn.ready() else {
            self.drop_link(at);
            return self.step(now);
        };
        let mut link = self.links.remove(at);
        let Stage::Authorizing { mut handshake } = link.stage else {
            unreachable!()
        };
        let hello = HandshakeHello {
            name: self.config.name.clone(),
            pairing_code: None,
        };
        let finished = hello
            .encode()
            .and_then(|payload| handshake.write(&payload))
            .and_then(|msg2| Ok((msg2, handshake.finish()?)));
        match finished {
            Ok((msg2, cipher)) => {
                let mut channel = Channel::new(link.id, cipher, HOST_CAP_BYTES);
                channel.set_open(true);
                link.stage = Stage::Ready {
                    channel: Box::new(channel),
                    attached: true,
                    peer_present: true,
                };
                self.send_text(
                    socket,
                    Control::Accept {
                        link: link.id.text(),
                        handshake: b64::encode(&msg2),
                    },
                );
                self.links.insert(at, link);
            }
            Err(_) => self.send_text(
                socket,
                Control::Close {
                    link: link.id.text(),
                    code: "HANDSHAKE_FAILED".into(),
                },
            ),
        }
        self.step(now);
    }

    pub fn respond(&mut self, link: &str, request: &str, result: &str, now: u64) {
        let reply = match message::raw(result) {
            Ok(value) => message::response(request, value, now),
            Err(_) => message::error(
                request,
                "HOST_ERROR",
                "The computer's answer is not JSON.",
                false,
                now,
            ),
        };
        self.reply(link, request, reply, now);
    }

    pub fn respond_error(&mut self, link: &str, request: &str, code: &str, text: &str, now: u64) {
        let reply = message::error(request, code, text, false, now);
        self.reply(link, request, reply, now);
    }

    /// Tells every phone with a link that something changed, phones away for now included.
    pub fn emit(&mut self, event: &str, data: &str, now: u64) {
        let Ok(data) = message::raw(data) else { return };
        let bytes = message::event(event, data, now);
        for at in (0..self.links.len()).rev() {
            if let Stage::Ready { channel, .. } = &mut self.links[at].stage
                && channel.send(&bytes).is_err()
            {
                self.close_link(at, "OVERFLOW");
            }
        }
        self.step(now);
    }

    /// Ends every link of a device, for example when the user removes it.
    pub fn disconnect(&mut self, device_id: &str, now: u64) {
        for at in (0..self.links.len()).rev() {
            if self.links[at].device_id == device_id {
                self.close_link(at, "DEVICE_REVOKED");
            }
        }
        self.step(now);
    }

    pub fn next_deadline(&self) -> Option<u64> {
        let mut deadlines = vec![self.conn.next_deadline()];
        for link in &self.links {
            if let Stage::Ready { channel, .. } = &link.stage {
                deadlines.push(channel.next_deadline());
                deadlines.push(channel.paced_until(&self.pacer));
            }
        }
        deadlines.into_iter().flatten().min()
    }

    fn control(&mut self, socket: SocketId, control: Control, now: u64) {
        match control {
            Control::HelloAck { .. } => {
                self.conn.accepted();
                self.fresh = false;
            }
            Control::Incoming {
                link,
                client,
                client_key,
                handshake,
            } => self.incoming(socket, &link, &client, &client_key, &handshake),
            Control::Attached { link, peer } => {
                if let Some(Stage::Ready {
                    attached,
                    peer_present,
                    ..
                }) = self.stage_of(&link)
                {
                    *attached = true;
                    *peer_present = peer == Presence::Present;
                }
            }
            Control::Peer { link, state } => {
                if let Some(Stage::Ready { peer_present, .. }) = self.stage_of(&link) {
                    *peer_present = state == PeerState::Back;
                }
            }
            Control::Closed { link, .. } => {
                if let Some(at) = self.links.iter().position(|item| item.id.text() == link) {
                    self.drop_link(at);
                }
            }
            Control::Error { message, .. } => {
                self.actions.push_back(HostAction::CloseSocket { socket });
                if self.conn.lost(socket, Some(&message), now) {
                    self.socket_gone();
                }
            }
            _ => {}
        }
    }

    fn incoming(
        &mut self,
        socket: SocketId,
        link: &str,
        client: &str,
        client_key: &str,
        msg1: &str,
    ) {
        let reject = |core: &mut Self, code: &str| {
            core.send_text(
                socket,
                Control::Close {
                    link: link.into(),
                    code: code.into(),
                },
            );
        };
        let Ok(id) = LinkId::parse(link) else {
            return reject(self, "INVALID");
        };
        if self.find(id).is_some() || device_id_for(client_key).ok().as_deref() != Some(client) {
            return reject(self, "INVALID");
        }
        if self.links.len() >= self.config.max_links {
            return reject(self, "HOST_BUSY");
        }
        let started = key_bytes(client_key)
            .and_then(|key| {
                Ok((
                    key,
                    prologue(link, &self.config.identity.device_id, client)?,
                ))
            })
            .and_then(|(key, prologue)| Handshake::responder(&self.config.identity, key, &prologue))
            .and_then(|mut handshake| {
                let bytes = b64::decode(msg1)
                    .ok_or_else(|| LinkError::invalid("The handshake is not base64."))?;
                let hello = HandshakeHello::decode(&handshake.read(&bytes)?)?;
                Ok((handshake, hello))
            });
        let Ok((handshake, hello)) = started else {
            return reject(self, "HANDSHAKE_FAILED");
        };
        self.links.push(PhoneLink {
            id,
            device_id: client.into(),
            stage: Stage::Authorizing {
                handshake: Box::new(handshake),
            },
            calls: HashSet::new(),
        });
        self.actions.push_back(HostAction::Authorize {
            link: link.into(),
            device_id: client.into(),
            identity_key: client_key.into(),
            name: hello.name,
            pairing_code: hello.pairing_code,
        });
    }

    fn serve(&mut self, at: usize, bytes: &[u8], now: u64) {
        let Ok(Message::Request { id, method, params }) = message::decode(bytes) else {
            return;
        };
        let link = &mut self.links[at];
        if link.calls.contains(&id) {
            return;
        }
        let refusal = if method.is_empty() {
            Some(("INVALID_REQUEST", "The call has no method.", false))
        } else if link.calls.len() >= MAX_CALLS_PER_LINK {
            Some(("RATE_LIMITED", "Too many calls at once.", true))
        } else {
            None
        };
        if let Some((code, text, retryable)) = refusal {
            let reply = message::error(&id, code, text, retryable, now);
            self.send_on(at, &reply);
            return;
        }
        link.calls.insert(id.clone());
        self.actions.push_back(HostAction::Request {
            link: link.id.text(),
            request: id,
            device_id: link.device_id.clone(),
            method,
            params,
        });
    }

    fn reply(&mut self, link: &str, request: &str, reply: Vec<u8>, now: u64) {
        let Some(at) = self.links.iter().position(|item| item.id.text() == link) else {
            return;
        };
        if !self.links[at].calls.remove(request) {
            return;
        }
        self.send_on(at, &reply);
        self.step(now);
    }

    fn send_on(&mut self, at: usize, bytes: &[u8]) {
        if let Stage::Ready { channel, .. } = &mut self.links[at].stage
            && channel.send(bytes).is_err()
        {
            self.close_link(at, "OVERFLOW");
        }
    }

    fn find(&self, id: LinkId) -> Option<usize> {
        self.links.iter().position(|link| link.id == id)
    }

    fn stage_of(&mut self, link: &str) -> Option<&mut Stage> {
        self.links
            .iter_mut()
            .find(|item| item.id.text() == link)
            .map(|item| &mut item.stage)
    }

    /// Tells the Server and the phone that this link is over, then forgets it.
    fn close_link(&mut self, at: usize, code: &str) {
        if let Some(socket) = self.conn.ready() {
            let link = self.links[at].id.text();
            self.send_text(
                socket,
                Control::Close {
                    link,
                    code: code.into(),
                },
            );
        }
        self.drop_link(at);
    }

    fn drop_link(&mut self, at: usize) {
        let link = self.links.remove(at);
        let id = link.id.text();
        for request in link.calls {
            self.actions.push_back(HostAction::Cancel {
                link: id.clone(),
                request,
            });
        }
    }

    /// The Server forgot links still in their handshake; ready ones wait for an attach.
    fn socket_gone(&mut self) {
        self.links
            .retain(|link| matches!(link.stage, Stage::Ready { .. }));
        for link in &mut self.links {
            if let Stage::Ready {
                channel, attached, ..
            } = &mut link.stage
            {
                *attached = false;
                channel.set_open(false);
            }
        }
    }

    fn step(&mut self, now: u64) {
        let mut out = Vec::new();
        self.conn.tick(now, &mut out);
        let lost = out.iter().any(|item| matches!(item, ConnOut::Close { .. }));
        self.conn_out(out);
        if lost {
            self.socket_gone();
        }
        if let Some(socket) = self.conn.ready() {
            for link in &mut self.links {
                if let Stage::Ready {
                    channel,
                    attached: true,
                    peer_present,
                } = &mut link.stage
                {
                    channel.set_open(*peer_present);
                    for data in channel.poll(&mut self.pacer, now) {
                        self.actions
                            .push_back(HostAction::SendBinary { socket, data });
                    }
                }
            }
        }
        let ready = self
            .links
            .iter()
            .filter(|link| matches!(link.stage, Stage::Ready { .. }))
            .count();
        if ready != self.ready_count {
            self.ready_count = ready;
            self.actions.push_back(HostAction::ReadyCount(ready));
        }
        let status = if !self.conn.running() {
            HostStatus::Stopped
        } else if self.conn.ready().is_some() {
            HostStatus::Online
        } else if self.conn.socket().is_some() {
            HostStatus::Connecting
        } else {
            HostStatus::Offline
        };
        if status != self.status {
            self.status = status;
            self.actions.push_back(HostAction::Status(status));
        }
    }

    fn send_text(&mut self, socket: SocketId, control: Control) {
        self.actions.push_back(HostAction::SendText {
            socket,
            text: control.encode(),
        });
    }

    fn conn_out(&mut self, out: Vec<ConnOut>) {
        for item in out {
            self.actions.push_back(match item {
                ConnOut::Connect { socket, url } => HostAction::Connect { socket, url },
                ConnOut::SendText { socket, text } => HostAction::SendText { socket, text },
                ConnOut::Close { socket } => HostAction::CloseSocket { socket },
            });
        }
    }
}
