use std::collections::VecDeque;

use dsbot_link_core::LinkError;
use dsbot_link_core::b64;
use dsbot_link_core::channel::{CLIENT_CAP_BYTES, Channel, Pacer};
use dsbot_link_core::conn::{Conn, ConnConfig, ConnOut, SocketId};
use dsbot_link_core::keys::Identity;
use dsbot_link_core::message::{self, Message, random_id};
use dsbot_link_core::noise::{Handshake, prologue};
use dsbot_link_core::pairing::HandshakeHello;
use dsbot_link_core::wire::{Binary, Control, LinkId, PROTOCOL, PeerState, Presence, Role};

const SILENCE_MS: u64 = 10_000;
const PROBE_MS: u64 = 10_000;
const FOREGROUND_PROBE_MS: u64 = 5_000;
/// While a call or a frame waits on the socket, a dead one should show within seconds.
const BUSY_SILENCE_MS: u64 = 3_000;
const BUSY_PROBE_MS: u64 = 5_000;
const CONNECT_TIMEOUT_MS: u64 = 10_000;
const BACKOFF_CAP_MS: u64 = 10_000;
const HOST_RETRY_MS: [u64; 4] = [1_000, 2_000, 4_000, 5_000];
pub const DEFAULT_RPC_TIMEOUT_MS: u64 = 60_000;
/// Codes after which the phone stops: the computer no longer accepts it.
const TERMINAL: [&str; 4] = [
    "NOT_PAIRED",
    "DEVICE_REVOKED",
    "PEER_IDENTITY_MISMATCH",
    "AUTH_INVALID",
];

#[derive(Clone, Debug)]
pub struct ClientConfig {
    pub server: String,
    pub identity: Identity,
    pub access_token: String,
    pub host_device_id: String,
    pub host_key: String,
    pub name: Option<String>,
    /// Sent with the handshakes until one succeeds.
    pub pairing_code: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LinkStatus {
    /// No link yet.
    Connecting {
        attempt: u32,
        error: Option<String>,
    },
    /// `resumed` is false after a new handshake: the app reads its state again.
    Online {
        resumed: bool,
    },
    /// The socket is down; the link and its unsent frames wait for it.
    Reconnecting {
        attempt: u32,
        error: Option<String>,
    },
    /// Our socket is fine but the computer is not on the Server.
    HostAway,
    /// The computer refused this phone. Final.
    Rejected {
        code: String,
        message: String,
    },
    Closed,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ClientAction {
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
    Status(LinkStatus),
    Event {
        name: String,
        data: String,
    },
    RpcDone {
        call: u64,
        result: Result<String, LinkError>,
    },
}

enum Link {
    None,
    Opening {
        id: LinkId,
        handshake: Box<Handshake>,
    },
    Ready {
        channel: Box<Channel>,
        attached: bool,
        peer_present: bool,
    },
    WaitHost {
        at: u64,
    },
}

struct Call {
    id: u64,
    request: String,
    method: String,
    params: String,
    deadline: u64,
    sent: bool,
}

pub struct ClientCore {
    config: ClientConfig,
    conn: Conn,
    link: Link,
    pacer: Pacer,
    calls: VecDeque<Call>,
    next_call: u64,
    host_retries: usize,
    host_name: Option<String>,
    was_online: bool,
    /// When the pacer lets the next frame go, if the pacer is what holds it back.
    status: Option<LinkStatus>,
    final_status: Option<LinkStatus>,
    actions: VecDeque<ClientAction>,
}

impl ClientCore {
    pub fn new(config: ClientConfig, now: u64) -> Self {
        let mut conn = Conn::new(ConnConfig {
            url: config.server.clone(),
            silence_ms: SILENCE_MS,
            probe_ms: PROBE_MS,
            connect_timeout_ms: CONNECT_TIMEOUT_MS,
            backoff_cap_ms: BACKOFF_CAP_MS,
        });
        conn.set_busy_timing(BUSY_SILENCE_MS, BUSY_PROBE_MS);
        Self {
            config,
            conn,
            link: Link::None,
            pacer: Pacer::new(now),
            calls: VecDeque::new(),
            next_call: 1,
            host_retries: 0,
            host_name: None,
            was_online: false,
            status: None,
            final_status: None,
            actions: VecDeque::new(),
        }
    }

    pub fn host_name(&self) -> Option<&str> {
        self.host_name.as_deref()
    }

    pub fn status(&self) -> Option<&LinkStatus> {
        self.status.as_ref()
    }

    pub fn start(&mut self, now: u64) {
        if self.final_status.is_none() {
            self.conn.start(now);
            self.step(now);
        }
    }

    pub fn poll_action(&mut self) -> Option<ClientAction> {
        self.actions.pop_front()
    }

    pub fn socket_opened(&mut self, socket: SocketId, now: u64) {
        if !self.conn.opened(socket, now) {
            return;
        }
        self.send_text(
            socket,
            Control::Hello {
                role: Role::Client,
                device_id: self.config.identity.device_id.clone(),
                identity_key: self.config.identity.public_key.clone(),
                access_token: self.config.access_token.clone(),
                protocols: vec![PROTOCOL],
                fresh: false,
            },
        );
        match &self.link {
            Link::Ready { channel, .. } => {
                let link = channel.link().text();
                self.send_text(socket, Control::Attach { link });
            }
            Link::WaitHost { at } if *at > now => {}
            _ => self.open(socket, now),
        }
        self.step(now);
    }

    pub fn socket_text(&mut self, socket: SocketId, text: &str, now: u64) {
        if !self.conn.heard(socket, now) {
            return;
        }
        // A frame this version does not know is skipped, so the Server can add some.
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
            self.give_up_socket(socket, "The Server sent a broken frame.", now);
            return self.step(now);
        };
        let Link::Ready { channel, .. } = &mut self.link else {
            return;
        };
        if frame.link() != channel.link() {
            return;
        }
        match channel.receive(frame, now) {
            Ok(messages) => {
                for bytes in messages {
                    self.deliver(&bytes);
                }
            }
            Err(error) => {
                let link = channel.link().text();
                self.send_text(
                    socket,
                    Control::Close {
                        link,
                        code: "INVALID".into(),
                    },
                );
                self.reset_session(&error.message, now);
            }
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
        let failed: Vec<u64> = self
            .calls
            .iter()
            .filter(|call| now >= call.deadline)
            .map(|call| call.id)
            .collect();
        for id in failed {
            self.finish_call(
                id,
                Err(LinkError::new(
                    "RPC_TIMEOUT",
                    "The computer did not answer in time.",
                )),
            );
        }
        if let Link::Ready { channel, .. } = &mut self.link {
            channel.tick(now);
        }
        self.step(now);
    }

    /// A different network: the old socket is bound to the old one, so dial again now.
    pub fn network_changed(&mut self, now: u64) {
        if self.final_status.is_some() {
            return;
        }
        let mut out = Vec::new();
        self.conn.redial(now, &mut out);
        self.conn_out(out);
        self.socket_gone();
        self.step(now);
    }

    /// Coming to the foreground checks the socket at once instead of after its silence.
    pub fn set_foreground(&mut self, foreground: bool, now: u64) {
        if foreground && self.final_status.is_none() {
            let mut out = Vec::new();
            self.conn.probe(FOREGROUND_PROBE_MS, now, &mut out);
            self.conn_out(out);
            if let Link::WaitHost { at } = &mut self.link {
                *at = now;
            }
            self.step(now);
        }
    }

    /// Sends a call; its answer comes as `RpcDone` with the returned id. A call waits
    /// for the link if there is none yet and fails only on timeout or a new session.
    pub fn rpc(&mut self, method: &str, params: &str, timeout_ms: u64, now: u64) -> u64 {
        let id = self.next_call;
        self.next_call += 1;
        let failed = if let Some(status) = &self.final_status {
            Some(final_error(status))
        } else if message::raw(params).is_err() {
            Some(LinkError::new(
                "INVALID_JSON",
                "The call's params are not JSON.",
            ))
        } else {
            None
        };
        if let Some(error) = failed {
            self.actions.push_back(ClientAction::RpcDone {
                call: id,
                result: Err(error),
            });
            return id;
        }
        self.calls.push_back(Call {
            id,
            request: random_id(),
            method: method.into(),
            params: params.into(),
            deadline: now
                + if timeout_ms == 0 {
                    DEFAULT_RPC_TIMEOUT_MS
                } else {
                    timeout_ms
                },
            sent: false,
        });
        self.step(now);
        id
    }

    /// Ends the session: the computer forgets the link and every waiting call fails.
    pub fn close(&mut self, now: u64) {
        if self.final_status == Some(LinkStatus::Closed) {
            return;
        }
        if let Some(socket) = self.conn.ready() {
            match &self.link {
                Link::Ready { channel, .. } => {
                    let link = channel.link().text();
                    self.send_text(
                        socket,
                        Control::Close {
                            link,
                            code: "CLOSED".into(),
                        },
                    );
                }
                Link::Opening { id, .. } => {
                    let link = id.text();
                    self.send_text(
                        socket,
                        Control::Close {
                            link,
                            code: "CLOSED".into(),
                        },
                    );
                }
                _ => {}
            }
        }
        self.finish(
            LinkStatus::Closed,
            LinkError::new("CLIENT_CLOSED", "The link was closed."),
        );
        self.step(now);
    }

    pub fn next_deadline(&self) -> Option<u64> {
        let mut deadlines = vec![self.conn.next_deadline()];
        deadlines.extend(self.calls.iter().map(|call| Some(call.deadline)));
        // The retry waits for a socket; without one, a passed `at` would spin the caller.
        if let (Link::WaitHost { at }, Some(_)) = (&self.link, self.conn.ready()) {
            deadlines.push(Some(*at));
        }
        if let Link::Ready { channel, .. } = &self.link {
            deadlines.push(channel.next_deadline());
            deadlines.push(channel.paced_until(&self.pacer));
        }
        deadlines.into_iter().flatten().min()
    }

    fn control(&mut self, socket: SocketId, control: Control, now: u64) {
        match control {
            Control::HelloAck { .. } => self.conn.accepted(),
            Control::Pong { .. } | Control::Ping { .. } => {}
            Control::Opened { link, handshake } => self.opened(&link, &handshake, now),
            Control::Attached { link, peer } => {
                if let Link::Ready {
                    channel,
                    attached,
                    peer_present,
                } = &mut self.link
                    && channel.link().text() == link
                {
                    *attached = true;
                    *peer_present = peer == Presence::Present;
                }
            }
            Control::Peer { link, state } => {
                if let Link::Ready {
                    channel,
                    peer_present,
                    ..
                } = &mut self.link
                    && channel.link().text() == link
                {
                    *peer_present = state == PeerState::Back;
                }
            }
            Control::Closed { link, code } => self.closed(socket, &link, &code, now),
            Control::Error { code, message } => {
                if TERMINAL.contains(&code.as_str()) || code == "UNSUPPORTED_VERSION" {
                    self.finish(
                        LinkStatus::Rejected {
                            code: code.clone(),
                            message: message.clone(),
                        },
                        LinkError::new(&code, message),
                    );
                } else {
                    self.give_up_socket(socket, &message, now);
                }
            }
            _ => {}
        }
    }

    fn current_link(&self) -> Option<LinkId> {
        match &self.link {
            Link::Opening { id, .. } => Some(*id),
            Link::Ready { channel, .. } => Some(channel.link()),
            _ => None,
        }
    }

    fn open(&mut self, socket: SocketId, now: u64) {
        let id = LinkId::random();
        let identity = &self.config.identity;
        let started = prologue(&id.text(), &self.config.host_device_id, &identity.device_id)
            .and_then(|prologue| {
                let key = dsbot_link_core::keys::key_bytes(&self.config.host_key)?;
                Handshake::initiator(identity, key, &prologue)
            })
            .and_then(|mut handshake| {
                let hello = HandshakeHello {
                    name: self.config.name.clone(),
                    pairing_code: self.config.pairing_code.clone(),
                };
                let msg1 = handshake.write(&hello.encode()?)?;
                Ok((handshake, msg1))
            });
        match started {
            Ok((handshake, msg1)) => {
                self.link = Link::Opening {
                    id,
                    handshake: Box::new(handshake),
                };
                let host = self.config.host_device_id.clone();
                self.send_text(
                    socket,
                    Control::Open {
                        link: id.text(),
                        host,
                        handshake: b64::encode(&msg1),
                    },
                );
            }
            Err(error) => self.finish(
                LinkStatus::Rejected {
                    code: error.code.clone(),
                    message: error.message.clone(),
                },
                error,
            ),
        }
        let _ = now;
    }

    fn opened(&mut self, link: &str, msg2: &str, now: u64) {
        let Link::Opening { id, .. } = &self.link else {
            return;
        };
        if id.text() != link {
            return;
        }
        let id = *id;
        let Link::Opening { handshake, .. } = std::mem::replace(&mut self.link, Link::None) else {
            unreachable!()
        };
        let mut handshake = *handshake;
        let finished = b64::decode(msg2)
            .ok_or_else(|| LinkError::invalid("The handshake is not base64."))
            .and_then(|bytes| handshake.read(&bytes))
            .and_then(|payload| HandshakeHello::decode(&payload))
            .and_then(|hello| Ok((hello, handshake.finish()?)));
        match finished {
            Ok((hello, cipher)) => {
                if hello.name.is_some() {
                    self.host_name = hello.name;
                }
                self.config.pairing_code = None;
                self.host_retries = 0;
                let mut channel = Channel::new(id, cipher, CLIENT_CAP_BYTES);
                channel.set_open(true);
                self.link = Link::Ready {
                    channel: Box::new(channel),
                    attached: true,
                    peer_present: true,
                };
                self.emit_status(LinkStatus::Online { resumed: false });
            }
            Err(error) if error.code == "PEER_IDENTITY_MISMATCH" => self.finish(
                LinkStatus::Rejected {
                    code: error.code.clone(),
                    message: error.message.clone(),
                },
                error,
            ),
            Err(error) => {
                if let Some(socket) = self.conn.ready() {
                    self.send_text(
                        socket,
                        Control::Close {
                            link: link.into(),
                            code: "INVALID".into(),
                        },
                    );
                }
                self.reset_session(&error.message, now);
            }
        }
    }

    fn closed(&mut self, socket: SocketId, link: &str, code: &str, now: u64) {
        if self.current_link().map(|id| id.text()).as_deref() != Some(link) {
            return;
        }
        if TERMINAL.contains(&code) {
            let message = if code == "DEVICE_REVOKED" {
                "The computer removed this phone."
            } else {
                "The computer does not accept this phone. Pair it again."
            };
            return self.finish(
                LinkStatus::Rejected {
                    code: code.into(),
                    message: message.into(),
                },
                LinkError::new(code, message),
            );
        }
        if matches!(code, "HOST_OFFLINE" | "HOST_BUSY") {
            self.fail_sent_calls();
            let delay = HOST_RETRY_MS[self.host_retries.min(HOST_RETRY_MS.len() - 1)];
            self.host_retries += 1;
            self.link = Link::WaitHost { at: now + delay };
            return;
        }
        self.reset_session(code, now);
        if self.conn.ready() == Some(socket) || self.conn.is_open(socket) {
            self.open(socket, now);
        }
    }

    /// The link is gone for good: calls that went out fail, calls not yet sent wait for the next one.
    fn reset_session(&mut self, why: &str, _now: u64) {
        self.fail_sent_calls_with(LinkError::new(
            "SESSION_RESET",
            format!("The link to the computer was reset ({why})."),
        ));
        self.link = Link::None;
    }

    fn fail_sent_calls(&mut self) {
        self.fail_sent_calls_with(LinkError::new(
            "SESSION_RESET",
            "The link to the computer was reset.",
        ));
    }

    fn fail_sent_calls_with(&mut self, error: LinkError) {
        let sent: Vec<u64> = self
            .calls
            .iter()
            .filter(|call| call.sent)
            .map(|call| call.id)
            .collect();
        for id in sent {
            self.finish_call(id, Err(error.clone()));
        }
    }

    fn socket_gone(&mut self) {
        match &mut self.link {
            Link::Ready {
                channel, attached, ..
            } => {
                *attached = false;
                channel.set_open(false);
            }
            Link::Opening { .. } => self.link = Link::None,
            _ => {}
        }
    }

    fn give_up_socket(&mut self, socket: SocketId, reason: &str, now: u64) {
        self.actions.push_back(ClientAction::CloseSocket { socket });
        if self.conn.lost(socket, Some(reason), now) {
            self.socket_gone();
        }
    }

    fn deliver(&mut self, bytes: &[u8]) {
        match message::decode(bytes) {
            Ok(Message::Response { request_id, result }) => self.answer(&request_id, Ok(result)),
            Ok(Message::Error {
                request_id,
                code,
                message,
            }) => self.answer(&request_id, Err(LinkError::new(&code, message))),
            Ok(Message::Event { event, data }) => self
                .actions
                .push_back(ClientAction::Event { name: event, data }),
            Ok(Message::Request { .. }) | Err(_) => {}
        }
    }

    fn answer(&mut self, request: &str, result: Result<String, LinkError>) {
        if let Some(id) = self
            .calls
            .iter()
            .find(|call| call.request == request)
            .map(|call| call.id)
        {
            self.finish_call(id, result);
        }
    }

    fn finish_call(&mut self, id: u64, result: Result<String, LinkError>) {
        if let Some(at) = self.calls.iter().position(|call| call.id == id) {
            self.calls.remove(at);
            self.actions
                .push_back(ClientAction::RpcDone { call: id, result });
        }
    }

    fn finish(&mut self, status: LinkStatus, error: LinkError) {
        let mut out = Vec::new();
        self.conn.stop(&mut out);
        self.conn_out(out);
        self.link = Link::None;
        for id in self.calls.iter().map(|call| call.id).collect::<Vec<_>>() {
            self.finish_call(id, Err(error.clone()));
        }
        self.final_status = Some(status.clone());
        self.emit_status(status);
    }

    /// Sends what can go, starts what is due, and reports the status that results.
    fn step(&mut self, now: u64) {
        self.conn.set_busy(self.busy());
        let mut out = Vec::new();
        self.conn.tick(now, &mut out);
        let lost = out.iter().any(|item| matches!(item, ConnOut::Close { .. }));
        self.conn_out(out);
        if lost {
            self.socket_gone();
        }
        if let (Some(socket), Link::WaitHost { at }) = (self.conn.ready(), &self.link)
            && now >= *at
        {
            self.open(socket, now);
        }
        // A link that was reset while the socket stayed up needs a new one now;
        // nothing else would open it until the socket drops.
        if let (Some(socket), Link::None, None) =
            (self.conn.ready(), &self.link, &self.final_status)
        {
            self.open(socket, now);
        }
        if let Link::Ready { channel, .. } = &mut self.link {
            for call in self.calls.iter_mut().filter(|call| !call.sent) {
                let params = message::raw(&call.params).expect("checked");
                if channel
                    .send(&message::request(&call.request, &call.method, params, now))
                    .is_err()
                {
                    break;
                }
                call.sent = true;
            }
        }
        if let (
            Some(socket),
            Link::Ready {
                channel,
                attached: true,
                peer_present,
            },
        ) = (self.conn.ready(), &mut self.link)
        {
            channel.set_open(*peer_present);
            for data in channel.poll(&mut self.pacer, now) {
                self.actions
                    .push_back(ClientAction::SendBinary { socket, data });
            }
        }
        self.conn.set_busy(self.busy());
        self.update_status();
    }

    /// A call or a frame waits on the socket.
    fn busy(&self) -> bool {
        self.calls.iter().any(|call| call.sent)
            || match &self.link {
                Link::Opening { .. } => true,
                Link::Ready { channel, .. } => channel.buffered_bytes() > 0,
                _ => false,
            }
    }

    fn update_status(&mut self) {
        if self.final_status.is_some() {
            return;
        }
        let attempt = self.conn.failures();
        let error = self.conn.error().map(String::from);
        let status = match &self.link {
            Link::Ready {
                attached: true,
                peer_present: true,
                ..
            } if self.conn.ready().is_some() => LinkStatus::Online { resumed: true },
            Link::Ready {
                attached: true,
                peer_present: false,
                ..
            } if self.conn.ready().is_some() => LinkStatus::HostAway,
            Link::WaitHost { .. } if self.conn.ready().is_some() => LinkStatus::HostAway,
            _ if self.was_online => LinkStatus::Reconnecting { attempt, error },
            _ => LinkStatus::Connecting { attempt, error },
        };
        // A new handshake already reported Online { resumed: false }.
        if matches!(status, LinkStatus::Online { .. })
            && matches!(self.status, Some(LinkStatus::Online { .. }))
        {
            return;
        }
        self.emit_status(status);
    }

    fn emit_status(&mut self, status: LinkStatus) {
        if self.status.as_ref() == Some(&status) {
            return;
        }
        if matches!(status, LinkStatus::Online { .. }) {
            self.was_online = true;
        }
        self.status = Some(status.clone());
        self.actions.push_back(ClientAction::Status(status));
    }

    fn send_text(&mut self, socket: SocketId, control: Control) {
        self.actions.push_back(ClientAction::SendText {
            socket,
            text: control.encode(),
        });
    }

    fn conn_out(&mut self, out: Vec<ConnOut>) {
        for item in out {
            self.actions.push_back(match item {
                ConnOut::Connect { socket, url } => ClientAction::Connect { socket, url },
                ConnOut::SendText { socket, text } => ClientAction::SendText { socket, text },
                ConnOut::Close { socket } => ClientAction::CloseSocket { socket },
            });
        }
    }
}

fn final_error(status: &LinkStatus) -> LinkError {
    match status {
        LinkStatus::Rejected { code, message } => LinkError::new(code, message.clone()),
        _ => LinkError::new("CLIENT_CLOSED", "The link was closed."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use dsbot_link_core::keys::generate_key_pair;
    use dsbot_link_core::noise::Cipher;
    use dsbot_link_core::wire::encode_data;

    fn identity() -> Identity {
        let pair = generate_key_pair(None).unwrap();
        Identity::new(&pair.public_key, &pair.private_key).unwrap()
    }

    fn hello_ack() -> String {
        Control::HelloAck {
            protocol: PROTOCOL,
            server: "test".into(),
            heartbeat_ms: 15_000,
            grace_ms: 120_000,
            max_frame_bytes: 1 << 20,
        }
        .encode()
    }

    struct Phone {
        core: ClientCore,
        host: Identity,
    }

    impl Phone {
        /// A session whose socket 1 is open and accepted, with its `open` sent.
        fn dialed() -> (Self, Control) {
            let host = identity();
            let config = ClientConfig {
                server: "ws://relay.test/v2/link".into(),
                identity: identity(),
                access_token: "t".repeat(43),
                host_device_id: host.device_id.clone(),
                host_key: host.public_key.clone(),
                name: Some("Pixel".into()),
                pairing_code: None,
            };
            let mut core = ClientCore::new(config, 0);
            core.start(0);
            assert_eq!(
                core.poll_action(),
                Some(ClientAction::Connect {
                    socket: 1,
                    url: "ws://relay.test/v2/link".into()
                })
            );
            core.socket_opened(1, 0);
            core.socket_text(1, &hello_ack(), 0);
            let mut phone = Self { core, host };
            let open = phone.sent_open().expect("an open frame");
            (phone, open)
        }

        fn sent_open(&mut self) -> Option<Control> {
            let mut open = None;
            while let Some(action) = self.core.poll_action() {
                if let ClientAction::SendText { text, .. } = action
                    && let Ok(control @ Control::Open { .. }) = Control::decode(&text)
                {
                    open = Some(control);
                }
            }
            open
        }

        /// Answers the `open` as the computer would; returns the computer's cipher.
        fn accept(&mut self, open: &Control) -> (LinkId, Cipher) {
            let Control::Open {
                link, handshake, ..
            } = open
            else {
                panic!("not an open frame")
            };
            let phone = &self.core.config.identity;
            let prologue = prologue(link, &self.host.device_id, &phone.device_id).unwrap();
            let mut responder =
                Handshake::responder(&self.host, phone.public_bytes(), &prologue).unwrap();
            responder.read(&b64::decode(handshake).unwrap()).unwrap();
            let msg2 = responder.write(br#"{"name":"Desk"}"#).unwrap();
            let opened = Control::Opened {
                link: link.clone(),
                handshake: b64::encode(&msg2),
            };
            self.core.socket_text(1, &opened.encode(), 0);
            (LinkId::parse(link).unwrap(), responder.finish().unwrap())
        }
    }

    #[test]
    fn a_new_handshake_reports_online_not_resumed() {
        let (mut phone, open) = Phone::dialed();
        phone.accept(&open);
        assert_eq!(
            phone.core.status(),
            Some(&LinkStatus::Online { resumed: false })
        );
        assert_eq!(phone.core.host_name(), Some("Desk"));
    }

    #[test]
    fn waiting_for_the_computer_does_not_spin_while_the_socket_is_down() {
        let (mut phone, open) = Phone::dialed();
        let Control::Open { link, .. } = open else {
            unreachable!()
        };
        phone.core.socket_text(
            1,
            &Control::Closed {
                link,
                code: "HOST_OFFLINE".into(),
            }
            .encode(),
            0,
        );
        assert_eq!(phone.core.status(), Some(&LinkStatus::HostAway));
        phone.core.socket_closed(1, None, 10);
        phone.core.tick(2_000);
        let next = phone.core.next_deadline().unwrap();
        assert!(next > 2_000, "the next wake-up {next} is already past");
    }

    #[test]
    fn a_link_reset_under_a_live_socket_opens_a_new_one() {
        let (mut phone, open) = Phone::dialed();
        let (link, _) = phone.accept(&open);
        phone.sent_open();
        // A frame that does not decrypt resets the link.
        phone
            .core
            .socket_binary(1, &encode_data(link, 1, 0, &[7; 32]), 10);
        assert!(phone.sent_open().is_some(), "no new open after the reset");
    }

    #[test]
    fn a_full_window_waits_for_acks_without_spinning() {
        let (mut phone, open) = Phone::dialed();
        phone.accept(&open);
        let params = serde_json::to_string(&"x".repeat(1_500_000)).unwrap();
        phone.core.rpc("bot", &params, 60_000, 0);
        phone.core.tick(5);
        let next = phone.core.next_deadline().unwrap();
        assert!(next > 5, "the next wake-up {next} is already past");
    }
}
