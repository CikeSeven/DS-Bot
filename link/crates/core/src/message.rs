//! The messages inside the encrypted channel: v1's `RemoteMessage` JSON, unchanged,
//! so the app's endpoints and payloads do not change with the link.

use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

use crate::error::LinkError;
use crate::keys::random_bytes;

#[derive(Debug, PartialEq, Eq)]
pub enum Message {
    Request {
        id: String,
        method: String,
        params: String,
    },
    Response {
        request_id: String,
        result: String,
    },
    Error {
        request_id: String,
        code: String,
        message: String,
    },
    Event {
        event: String,
        data: String,
    },
}

#[derive(Serialize)]
struct Envelope<'a, P: Serialize> {
    v: u32,
    id: &'a str,
    #[serde(rename = "type")]
    kind: &'a str,
    timestamp: u64,
    payload: P,
}

#[derive(Deserialize)]
struct Incoming<'a> {
    v: u32,
    id: String,
    #[serde(rename = "type")]
    kind: String,
    #[serde(borrow)]
    payload: &'a RawValue,
}

pub fn random_id() -> String {
    let mut bytes: [u8; 16] = random_bytes(16).try_into().expect("16 bytes");
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}

/// Checks that `json` is one JSON value, so it can be placed into a message as is.
pub fn raw(json: &str) -> Result<&RawValue, LinkError> {
    serde_json::from_str(json).map_err(|_| LinkError::new("INVALID_JSON", "A value is not JSON."))
}

fn envelope(id: &str, kind: &str, now: u64, payload: impl Serialize) -> Vec<u8> {
    serde_json::to_vec(&Envelope {
        v: 1,
        id,
        kind,
        timestamp: now,
        payload,
    })
    .expect("plain data")
}

pub fn request(id: &str, method: &str, params: &RawValue, now: u64) -> Vec<u8> {
    #[derive(Serialize)]
    struct Payload<'a> {
        method: &'a str,
        params: &'a RawValue,
    }
    envelope(id, "rpc.request", now, Payload { method, params })
}

pub fn response(request_id: &str, result: &RawValue, now: u64) -> Vec<u8> {
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Payload<'a> {
        request_id: &'a str,
        result: &'a RawValue,
    }
    envelope(
        &random_id(),
        "rpc.response",
        now,
        Payload { request_id, result },
    )
}

pub fn error(request_id: &str, code: &str, message: &str, retryable: bool, now: u64) -> Vec<u8> {
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Payload<'a> {
        request_id: &'a str,
        code: &'a str,
        message: &'a str,
        #[serde(skip_serializing_if = "std::ops::Not::not")]
        retryable: bool,
    }
    envelope(
        &random_id(),
        "rpc.error",
        now,
        Payload {
            request_id,
            code,
            message,
            retryable,
        },
    )
}

pub fn event(event: &str, data: &RawValue, now: u64) -> Vec<u8> {
    #[derive(Serialize)]
    struct Payload<'a> {
        event: &'a str,
        data: &'a RawValue,
    }
    envelope(&random_id(), "event", now, Payload { event, data })
}

pub fn decode(bytes: &[u8]) -> Result<Message, LinkError> {
    let invalid = || LinkError::invalid("A message is invalid.");
    let incoming: Incoming = serde_json::from_slice(bytes).map_err(|_| invalid())?;
    if incoming.v != 1 || incoming.id.is_empty() {
        return Err(invalid());
    }
    let payload = incoming.payload.get();
    match incoming.kind.as_str() {
        "rpc.request" => {
            #[derive(Deserialize)]
            struct Payload<'a> {
                #[serde(default)]
                method: String,
                #[serde(borrow, default)]
                params: Option<&'a RawValue>,
            }
            let p: Payload = serde_json::from_str(payload).map_err(|_| invalid())?;
            Ok(Message::Request {
                id: incoming.id,
                method: p.method,
                params: p.params.map_or("null", RawValue::get).into(),
            })
        }
        "rpc.response" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Payload<'a> {
                request_id: String,
                #[serde(borrow, default)]
                result: Option<&'a RawValue>,
            }
            let p: Payload = serde_json::from_str(payload).map_err(|_| invalid())?;
            Ok(Message::Response {
                request_id: p.request_id,
                result: p.result.map_or("null", RawValue::get).into(),
            })
        }
        "rpc.error" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Payload {
                request_id: String,
                code: String,
                #[serde(default)]
                message: String,
            }
            let p: Payload = serde_json::from_str(payload).map_err(|_| invalid())?;
            Ok(Message::Error {
                request_id: p.request_id,
                code: p.code,
                message: p.message,
            })
        }
        "event" => {
            #[derive(Deserialize)]
            struct Payload<'a> {
                event: String,
                #[serde(borrow, default)]
                data: Option<&'a RawValue>,
            }
            let p: Payload = serde_json::from_str(payload).map_err(|_| invalid())?;
            Ok(Message::Event {
                event: p.event,
                data: p.data.map_or("null", RawValue::get).into(),
            })
        }
        _ => Err(invalid()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_round_trip() {
        let params = raw(r#"{"endpoint":"state","payload":{}}"#).unwrap();
        let bytes = request("r-1", "bot", params, 1_700_000_000_000);
        assert_eq!(
            std::str::from_utf8(&bytes).unwrap(),
            r#"{"v":1,"id":"r-1","type":"rpc.request","timestamp":1700000000000,"payload":{"method":"bot","params":{"endpoint":"state","payload":{}}}}"#
        );
        assert_eq!(
            decode(&bytes).unwrap(),
            Message::Request {
                id: "r-1".into(),
                method: "bot".into(),
                params: r#"{"endpoint":"state","payload":{}}"#.into()
            }
        );
        let reply = response("r-1", raw("[1,2]").unwrap(), 1);
        assert_eq!(
            decode(&reply).unwrap(),
            Message::Response {
                request_id: "r-1".into(),
                result: "[1,2]".into()
            }
        );
        let failed = error("r-1", "HOST_ERROR", "no", false, 1);
        assert_eq!(
            decode(&failed).unwrap(),
            Message::Error {
                request_id: "r-1".into(),
                code: "HOST_ERROR".into(),
                message: "no".into()
            }
        );
        assert!(!std::str::from_utf8(&failed).unwrap().contains("retryable"));
        let event = event("revision", raw(r#"{"revision":7}"#).unwrap(), 1);
        assert_eq!(
            decode(&event).unwrap(),
            Message::Event {
                event: "revision".into(),
                data: r#"{"revision":7}"#.into()
            }
        );
        assert!(raw("{").is_err());
        assert_eq!(random_id().len(), 36);
    }
}
