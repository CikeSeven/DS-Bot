//! One link to one computer, shared by every isolate in the app's process: opening
//! the same Server, computer and phone again joins the session that is running.

use dsbot_link_client::runtime::{self, LinkEvent, LinkHandle};
use dsbot_link_client::{ClientConfig, LinkStatus};
use dsbot_link_core::keys::Identity;
use dsbot_link_core::LinkError;
use flutter_rust_bridge::frb;
use tokio::sync::broadcast::error::RecvError;

use crate::frb_generated::StreamSink;

/// A failure with a stable code the app can act on.
#[derive(Debug)]
pub struct LinkFailure {
    pub code: String,
    pub message: String,
}

impl From<LinkError> for LinkFailure {
    fn from(error: LinkError) -> Self {
        Self { code: error.code, message: error.message }
    }
}

pub struct PhoneLinkConfig {
    pub server: String,
    pub public_key: String,
    pub private_key: String,
    pub access_token: String,
    pub host_device_id: String,
    pub host_key: String,
    /// The phone's name, shown on the computer.
    pub name: Option<String>,
    /// Only when pairing: sent inside the handshake until one succeeds.
    pub pairing_code: Option<String>,
}

pub enum LinkState {
    Connecting,
    Online,
    Reconnecting,
    HostAway,
    Rejected,
    Closed,
}

pub struct PhoneLinkStatus {
    pub state: LinkState,
    /// Online: the old link came back, so nothing needs reading again.
    pub resumed: bool,
    /// Connecting and reconnecting: failed tries since the Server last answered.
    pub attempt: u32,
    /// Rejected: why the computer refused this phone.
    pub code: Option<String>,
    /// Rejected: the reason in words; connecting and reconnecting: the last socket error.
    pub message: Option<String>,
}

/// A status change, or else a feed event from the computer (name and JSON data).
pub struct PhoneLinkEvent {
    pub status: Option<PhoneLinkStatus>,
    pub name: String,
    pub data: String,
}

#[frb(opaque)]
pub struct PhoneLink {
    handle: LinkHandle,
}

impl PhoneLink {
    #[frb(sync)]
    pub fn open(config: PhoneLinkConfig) -> Result<PhoneLink, LinkFailure> {
        let identity = Identity::new(&config.public_key, &config.private_key)?;
        let handle = runtime::open(ClientConfig {
            server: config.server,
            identity,
            access_token: config.access_token,
            host_device_id: config.host_device_id,
            host_key: config.host_key,
            name: config.name,
            pairing_code: config.pairing_code,
        });
        Ok(PhoneLink { handle })
    }

    /// Calls `method` with JSON params; the answer is JSON. 0 means the default timeout.
    pub async fn rpc(&self, method: String, params_json: String, timeout_ms: u32) -> Result<String, LinkFailure> {
        Ok(self.handle.rpc(&method, &params_json, timeout_ms.into()).await?)
    }

    /// The current status first, then every change and feed event, until the link closes.
    pub async fn events(&self, sink: StreamSink<PhoneLinkEvent>) {
        let mut events = self.handle.subscribe();
        let current = self.handle.status();
        flutter_rust_bridge::spawn(async move {
            if let Some(status) = current {
                if sink.add(status_event(status)).is_err() {
                    return;
                }
            }
            loop {
                let event = match events.recv().await {
                    Ok(LinkEvent::Status(status)) => {
                        let closed = status == LinkStatus::Closed;
                        if sink.add(status_event(status)).is_err() || closed {
                            return;
                        }
                        continue;
                    }
                    Ok(LinkEvent::Event { name, data }) => PhoneLinkEvent { status: None, name, data },
                    // Far behind: the next revision read catches up on what was missed.
                    Err(RecvError::Lagged(_)) => continue,
                    Err(RecvError::Closed) => return,
                };
                if sink.add(event).is_err() {
                    return;
                }
            }
        });
    }

    #[frb(sync)]
    pub fn status(&self) -> Option<PhoneLinkStatus> {
        self.handle.status().map(status)
    }

    /// What the computer called itself in the handshake.
    #[frb(sync)]
    pub fn host_name(&self) -> Option<String> {
        self.handle.host_name()
    }

    /// The phone moved to another network: the socket is dialed again at once.
    #[frb(sync)]
    pub fn network_changed(&self) {
        self.handle.network_changed();
    }

    /// Coming to the foreground checks the socket at once.
    #[frb(sync)]
    pub fn set_foreground(&self, foreground: bool) {
        self.handle.set_foreground(foreground);
    }

    /// Lets go of the session; the last user of it ends it.
    pub async fn close(&self) {
        self.handle.close().await;
    }
}

fn status_event(status: LinkStatus) -> PhoneLinkEvent {
    PhoneLinkEvent { status: Some(self::status(status)), name: String::new(), data: String::new() }
}

fn status(status: LinkStatus) -> PhoneLinkStatus {
    let plain = |state| PhoneLinkStatus { state, resumed: false, attempt: 0, code: None, message: None };
    match status {
        LinkStatus::Connecting { attempt, error } => PhoneLinkStatus { attempt, message: error, ..plain(LinkState::Connecting) },
        LinkStatus::Online { resumed } => PhoneLinkStatus { resumed, ..plain(LinkState::Online) },
        LinkStatus::Reconnecting { attempt, error } => {
            PhoneLinkStatus { attempt, message: error, ..plain(LinkState::Reconnecting) }
        }
        LinkStatus::HostAway => plain(LinkState::HostAway),
        LinkStatus::Rejected { code, message } => {
            PhoneLinkStatus { code: Some(code), message: Some(message), ..plain(LinkState::Rejected) }
        }
        LinkStatus::Closed => plain(LinkState::Closed),
    }
}
