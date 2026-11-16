//! One WebSocket to the Relay Server at a time: when to dial, when a silent socket
//! is dead, and how long to wait before the next try. A socket given up on is
//! reported lost at once; its own close event can take minutes on a half-open link.

use crate::backoff::Backoff;
use crate::keys::random_token;
use crate::wire::Control;

pub type SocketId = u64;

#[derive(Clone, Debug)]
pub struct ConnConfig {
    pub url: String,
    /// Silence after which an open socket is probed.
    pub silence_ms: u64,
    /// Silence after a probe that declares the socket dead.
    pub probe_ms: u64,
    /// Dial to `hello.ack`.
    pub connect_timeout_ms: u64,
    pub backoff_cap_ms: u64,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ConnOut {
    Connect { socket: SocketId, url: String },
    SendText { socket: SocketId, text: String },
    Close { socket: SocketId },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Idle,
    Waiting {
        at: u64,
    },
    Dialing {
        socket: SocketId,
        since: u64,
    },
    Open {
        socket: SocketId,
        since: u64,
        acked: bool,
    },
}

#[derive(Debug)]
pub struct Conn {
    config: ConnConfig,
    backoff: Backoff,
    phase: Phase,
    next_socket: SocketId,
    last_heard: u64,
    probe: Option<(u64, u64)>,
    error: Option<String>,
    failures: u32,
    busy: bool,
    busy_timing: Option<(u64, u64)>,
}

impl Conn {
    pub fn new(config: ConnConfig) -> Self {
        let backoff = Backoff::new(config.backoff_cap_ms);
        Self {
            config,
            backoff,
            phase: Phase::Idle,
            next_socket: 1,
            last_heard: 0,
            probe: None,
            error: None,
            failures: 0,
            busy: false,
            busy_timing: None,
        }
    }

    /// Shorter silence and probe limits for while something waits on the socket, such as
    /// a call or unacked frames: a dead socket then shows within seconds, while an idle
    /// one is checked less often.
    pub fn set_busy_timing(&mut self, silence_ms: u64, probe_ms: u64) {
        self.busy_timing = Some((silence_ms, probe_ms));
    }

    pub fn set_busy(&mut self, busy: bool) {
        self.busy = busy;
    }

    fn timing(&self) -> (u64, u64) {
        match self.busy_timing {
            Some(timing) if self.busy => timing,
            _ => (self.config.silence_ms, self.config.probe_ms),
        }
    }

    /// Dials at the next `tick`.
    pub fn start(&mut self, now: u64) {
        if self.phase == Phase::Idle {
            self.phase = Phase::Waiting { at: now };
        }
    }

    /// Closes the socket and stops dialing.
    pub fn stop(&mut self, out: &mut Vec<ConnOut>) {
        if let Some(socket) = self.socket() {
            out.push(ConnOut::Close { socket });
        }
        self.phase = Phase::Idle;
    }

    pub fn socket(&self) -> Option<SocketId> {
        match self.phase {
            Phase::Dialing { socket, .. } | Phase::Open { socket, .. } => Some(socket),
            _ => None,
        }
    }

    /// The socket is open and the Server accepted our hello.
    pub fn ready(&self) -> Option<SocketId> {
        match self.phase {
            Phase::Open {
                socket,
                acked: true,
                ..
            } => Some(socket),
            _ => None,
        }
    }

    pub fn is_open(&self, socket: SocketId) -> bool {
        matches!(self.phase, Phase::Open { socket: open, .. } if open == socket)
    }

    pub fn running(&self) -> bool {
        self.phase != Phase::Idle
    }

    /// Why the last socket ended, for surfaces that show it.
    pub fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }

    /// Connect attempts that failed since the Server last accepted us.
    pub fn failures(&self) -> u32 {
        self.failures
    }

    /// The socket opened; returns false for a socket that is no longer current.
    pub fn opened(&mut self, socket: SocketId, now: u64) -> bool {
        match self.phase {
            Phase::Dialing {
                socket: dialing,
                since,
            } if dialing == socket => {
                self.phase = Phase::Open {
                    socket,
                    since,
                    acked: false,
                };
                self.last_heard = now;
                self.probe = None;
                true
            }
            _ => false,
        }
    }

    /// Any frame from the current socket; returns false for a stale one.
    pub fn heard(&mut self, socket: SocketId, now: u64) -> bool {
        if !self.is_open(socket) {
            return false;
        }
        self.last_heard = now;
        self.probe = None;
        true
    }

    /// `hello.ack` arrived: the next failure starts the backoff over.
    pub fn accepted(&mut self) {
        if let Phase::Open { socket, since, .. } = self.phase {
            self.phase = Phase::Open {
                socket,
                since,
                acked: true,
            };
            self.backoff.reset();
            self.error = None;
            self.failures = 0;
        }
    }

    /// The current socket closed or failed; returns false for a stale one.
    pub fn lost(&mut self, socket: SocketId, reason: Option<&str>, now: u64) -> bool {
        if self.socket() != Some(socket) {
            return false;
        }
        self.fail(reason.unwrap_or("The Server closed the connection."), now);
        true
    }

    /// Gives up on the current socket now and dials again at once, as after a network change.
    pub fn redial(&mut self, now: u64, out: &mut Vec<ConnOut>) {
        if self.phase == Phase::Idle {
            return;
        }
        if let Some(socket) = self.socket() {
            out.push(ConnOut::Close { socket });
        }
        self.backoff.reset();
        self.backoff.next_delay();
        self.phase = Phase::Waiting { at: now };
    }

    /// Asks the Server for a reply now, giving it `timeout_ms`; a waiting dial goes at once.
    pub fn probe(&mut self, timeout_ms: u64, now: u64, out: &mut Vec<ConnOut>) {
        match self.phase {
            Phase::Waiting { .. } => {
                self.backoff.reset();
                self.phase = Phase::Waiting { at: now };
            }
            Phase::Open {
                socket,
                acked: true,
                ..
            } if self.probe.is_none() => {
                let deadline = now + timeout_ms.min(self.timing().1);
                self.send_ping(socket, now, deadline, out);
            }
            _ => {}
        }
    }

    fn send_ping(&mut self, socket: SocketId, now: u64, deadline: u64, out: &mut Vec<ConnOut>) {
        self.probe = Some((now, deadline));
        out.push(ConnOut::SendText {
            socket,
            text: Control::Ping {
                nonce: random_token(8),
            }
            .encode(),
        });
    }

    fn fail(&mut self, reason: &str, now: u64) {
        self.error = Some(reason.into());
        self.failures += 1;
        self.probe = None;
        let delay = self.backoff.next_delay();
        self.phase = Phase::Waiting { at: now + delay };
    }

    pub fn tick(&mut self, now: u64, out: &mut Vec<ConnOut>) {
        match self.phase {
            Phase::Waiting { at } if now >= at => {
                let socket = self.next_socket;
                self.next_socket += 1;
                self.phase = Phase::Dialing { socket, since: now };
                out.push(ConnOut::Connect {
                    socket,
                    url: self.config.url.clone(),
                });
            }
            Phase::Dialing { socket, since }
            | Phase::Open {
                socket,
                since,
                acked: false,
            } if now >= since + self.config.connect_timeout_ms => {
                out.push(ConnOut::Close { socket });
                self.fail("The Server did not answer in time.", now);
            }
            Phase::Open {
                socket,
                acked: true,
                ..
            } => {
                let (silence_ms, probe_ms) = self.timing();
                match self.probe {
                    Some((_, deadline)) if now >= deadline => {
                        out.push(ConnOut::Close { socket });
                        self.fail("The Server stopped answering.", now);
                    }
                    None if now >= self.last_heard + silence_ms => {
                        self.send_ping(socket, now, now + probe_ms, out)
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }

    pub fn next_deadline(&self) -> Option<u64> {
        match self.phase {
            Phase::Idle => None,
            Phase::Waiting { at } => Some(at),
            Phase::Dialing { since, .. }
            | Phase::Open {
                since,
                acked: false,
                ..
            } => Some(since + self.config.connect_timeout_ms),
            Phase::Open { acked: true, .. } => Some(
                self.probe
                    .map_or(self.last_heard + self.timing().0, |(_, deadline)| deadline),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conn() -> Conn {
        Conn::new(ConnConfig {
            url: "ws://relay/v2/link".into(),
            silence_ms: 10_000,
            probe_ms: 10_000,
            connect_timeout_ms: 10_000,
            backoff_cap_ms: 10_000,
        })
    }

    #[test]
    fn dials_probes_and_redials() {
        let mut conn = conn();
        let mut out = Vec::new();
        conn.start(0);
        conn.tick(0, &mut out);
        assert_eq!(
            out.pop(),
            Some(ConnOut::Connect {
                socket: 1,
                url: "ws://relay/v2/link".into()
            })
        );
        assert!(conn.opened(1, 10));
        conn.accepted();
        assert_eq!(conn.ready(), Some(1));
        conn.tick(10_010, &mut out);
        assert!(matches!(
            out.pop(),
            Some(ConnOut::SendText { socket: 1, .. })
        ));
        assert_eq!(conn.next_deadline(), Some(20_010));
        conn.tick(20_010, &mut out);
        assert_eq!(out.pop(), Some(ConnOut::Close { socket: 1 }));
        // The first retry goes at once.
        conn.tick(20_010, &mut out);
        assert_eq!(
            out.pop(),
            Some(ConnOut::Connect {
                socket: 2,
                url: "ws://relay/v2/link".into()
            })
        );
        assert!(!conn.heard(1, 20_020));
        assert!(!conn.lost(1, None, 20_020));
    }

    #[test]
    fn a_busy_socket_is_probed_sooner() {
        let mut conn = conn();
        let mut out = Vec::new();
        conn.set_busy_timing(3_000, 5_000);
        conn.start(0);
        conn.tick(0, &mut out);
        conn.opened(1, 0);
        conn.accepted();
        conn.set_busy(true);
        assert_eq!(conn.next_deadline(), Some(3_000));
        conn.tick(3_000, &mut out);
        assert!(matches!(out.pop(), Some(ConnOut::SendText { .. })));
        conn.tick(8_000, &mut out);
        assert_eq!(out.pop(), Some(ConnOut::Close { socket: 1 }));
    }

    #[test]
    fn a_dial_that_never_answers_times_out_and_backs_off() {
        let mut conn = conn();
        let mut out = Vec::new();
        conn.start(0);
        conn.tick(0, &mut out);
        conn.tick(10_000, &mut out);
        assert_eq!(out.pop(), Some(ConnOut::Close { socket: 1 }));
        assert_eq!(conn.failures(), 1);
        out.clear();
        conn.tick(10_000, &mut out);
        assert_eq!(out.len(), 1);
        conn.tick(20_000, &mut out);
        let at = conn.next_deadline().unwrap();
        assert!(at > 20_000 && at <= 20_300, "{at}");
        conn.redial(20_001, &mut out);
        assert_eq!(conn.next_deadline(), Some(20_001));
    }
}
