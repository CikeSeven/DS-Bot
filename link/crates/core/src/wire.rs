//! Protocol v2 on the WebSocket: JSON control frames as text, encrypted data as binary.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::b64;
use crate::error::LinkError;
use crate::keys::random_bytes;

pub const PROTOCOL: u32 = 2;
/// Where the Relay Server listens; a bare relay host means this path.
pub const LINK_PATH: &str = "/v2/link";
pub const MAX_CONTROL_BYTES: usize = 64 * 1024;
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;

const KIND_DATA: u8 = 1;
const KIND_ACK: u8 = 2;
pub const DATA_HEADER_BYTES: usize = 33;
pub const ACK_FRAME_BYTES: usize = 25;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct LinkId(pub [u8; 16]);

impl LinkId {
    pub fn random() -> Self {
        Self(random_bytes(16).try_into().expect("16 bytes"))
    }

    pub fn parse(text: &str) -> Result<Self, LinkError> {
        b64::decode(text)
            .and_then(|bytes| <[u8; 16]>::try_from(bytes).ok())
            .map(Self)
            .ok_or_else(|| LinkError::invalid("A link id must be 16 bytes."))
    }

    pub fn text(&self) -> String {
        b64::encode(&self.0)
    }
}

impl fmt::Display for LinkId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.text())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Host,
    Client,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Presence {
    Present,
    Away,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PeerState {
    Away,
    Back,
}

/// A text frame. Unknown fields are ignored so either side can add some later.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all_fields = "camelCase")]
pub enum Control {
    #[serde(rename = "hello")]
    Hello {
        role: Role,
        device_id: String,
        identity_key: String,
        access_token: String,
        protocols: Vec<u32>,
        #[serde(default, skip_serializing_if = "is_false")]
        fresh: bool,
    },
    #[serde(rename = "hello.ack")]
    HelloAck {
        protocol: u32,
        server: String,
        heartbeat_ms: u64,
        grace_ms: u64,
        max_frame_bytes: u64,
    },
    #[serde(rename = "ping")]
    Ping { nonce: String },
    #[serde(rename = "pong")]
    Pong { nonce: String },
    #[serde(rename = "open")]
    Open {
        link: String,
        host: String,
        handshake: String,
    },
    #[serde(rename = "accept")]
    Accept { link: String, handshake: String },
    #[serde(rename = "attach")]
    Attach { link: String },
    #[serde(rename = "close")]
    Close { link: String, code: String },
    #[serde(rename = "incoming")]
    Incoming {
        link: String,
        client: String,
        client_key: String,
        handshake: String,
    },
    #[serde(rename = "opened")]
    Opened { link: String, handshake: String },
    #[serde(rename = "attached")]
    Attached { link: String, peer: Presence },
    #[serde(rename = "peer")]
    Peer { link: String, state: PeerState },
    #[serde(rename = "closed")]
    Closed { link: String, code: String },
    #[serde(rename = "error")]
    Error { code: String, message: String },
}

fn is_false(value: &bool) -> bool {
    !*value
}

impl Control {
    pub fn encode(&self) -> String {
        serde_json::to_string(self).expect("plain data")
    }

    pub fn decode(text: &str) -> Result<Self, LinkError> {
        if text.len() > MAX_CONTROL_BYTES {
            return Err(LinkError::new(
                "INVALID_MESSAGE",
                "A control frame is too large.",
            ));
        }
        serde_json::from_str(text)
            .map_err(|_| LinkError::new("INVALID_MESSAGE", "A control frame is invalid."))
    }
}

/// A binary frame, borrowed from the bytes it was read from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Binary<'a> {
    Data {
        link: LinkId,
        seq: u64,
        ack: u64,
        ciphertext: &'a [u8],
    },
    Ack {
        link: LinkId,
        ack: u64,
    },
}

impl<'a> Binary<'a> {
    pub fn decode(bytes: &'a [u8]) -> Result<Self, LinkError> {
        let invalid = || LinkError::new("INVALID_MESSAGE", "A data frame is invalid.");
        let link = binary_link(bytes).ok_or_else(invalid)?;
        let u64_at = |at: usize| u64::from_be_bytes(bytes[at..at + 8].try_into().expect("8 bytes"));
        match bytes[0] {
            KIND_DATA if bytes.len() >= DATA_HEADER_BYTES + crate::noise::TAG_BYTES => {
                let seq = u64_at(17);
                if seq == 0 {
                    return Err(invalid());
                }
                Ok(Self::Data {
                    link,
                    seq,
                    ack: u64_at(25),
                    ciphertext: &bytes[DATA_HEADER_BYTES..],
                })
            }
            KIND_ACK if bytes.len() == ACK_FRAME_BYTES => Ok(Self::Ack {
                link,
                ack: u64_at(17),
            }),
            _ => Err(invalid()),
        }
    }

    pub fn link(&self) -> LinkId {
        match self {
            Self::Data { link, .. } | Self::Ack { link, .. } => *link,
        }
    }
}

/// The link a binary frame belongs to: all the Relay Server reads of it.
pub fn binary_link(bytes: &[u8]) -> Option<LinkId> {
    if bytes.len() < ACK_FRAME_BYTES
        || bytes.len() > MAX_FRAME_BYTES
        || !matches!(bytes[0], KIND_DATA | KIND_ACK)
    {
        return None;
    }
    Some(LinkId(bytes[1..17].try_into().expect("16 bytes")))
}

pub fn encode_data(link: LinkId, seq: u64, ack: u64, ciphertext: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(DATA_HEADER_BYTES + ciphertext.len());
    frame.push(KIND_DATA);
    frame.extend_from_slice(&link.0);
    frame.extend_from_slice(&seq.to_be_bytes());
    frame.extend_from_slice(&ack.to_be_bytes());
    frame.extend_from_slice(ciphertext);
    frame
}

pub fn encode_ack(link: LinkId, ack: u64) -> Vec<u8> {
    let mut frame = Vec::with_capacity(ACK_FRAME_BYTES);
    frame.push(KIND_ACK);
    frame.extend_from_slice(&link.0);
    frame.extend_from_slice(&ack.to_be_bytes());
    frame
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_frames_use_camel_case_fields() {
        let hello = Control::Hello {
            role: Role::Client,
            device_id: "d-a".into(),
            identity_key: "k".into(),
            access_token: "t".into(),
            protocols: vec![PROTOCOL],
            fresh: false,
        };
        assert_eq!(
            hello.encode(),
            r#"{"type":"hello","role":"client","deviceId":"d-a","identityKey":"k","accessToken":"t","protocols":[2]}"#
        );
        assert_eq!(Control::decode(&hello.encode()).unwrap(), hello);
        let incoming = Control::decode(r#"{"type":"incoming","link":"l","client":"d-b","clientKey":"k","handshake":"h","extra":1}"#).unwrap();
        assert_eq!(
            incoming,
            Control::Incoming {
                link: "l".into(),
                client: "d-b".into(),
                client_key: "k".into(),
                handshake: "h".into()
            }
        );
        assert_eq!(
            Control::Attached {
                link: "l".into(),
                peer: Presence::Away
            }
            .encode(),
            r#"{"type":"attached","link":"l","peer":"away"}"#
        );
        assert!(Control::decode(r#"{"type":"nope"}"#).is_err());
    }

    #[test]
    fn binary_frames_round_trip() {
        let link = LinkId::random();
        assert_eq!(LinkId::parse(&link.text()).unwrap(), link);
        let data = encode_data(link, 5, 3, &[9; 20]);
        assert_eq!(
            Binary::decode(&data).unwrap(),
            Binary::Data {
                link,
                seq: 5,
                ack: 3,
                ciphertext: &[9; 20]
            }
        );
        let ack = encode_ack(link, 11);
        assert_eq!(Binary::decode(&ack).unwrap(), Binary::Ack { link, ack: 11 });
        assert!(Binary::decode(&encode_data(link, 0, 0, &[0; 16])).is_err());
        assert!(Binary::decode(&encode_data(link, 1, 0, &[0; 15])).is_err());
        assert!(Binary::decode(&ack[..24]).is_err());
    }
}
