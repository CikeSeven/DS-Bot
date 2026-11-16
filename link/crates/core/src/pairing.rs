//! What a phone and a computer tell each other inside the handshake, the pairing
//! QR code, and the phones a computer trusts. All the same as protocol v1.

use serde::{Deserialize, Serialize};
use url::Url;

use crate::error::LinkError;
use crate::keys::{device_id_for, random_token, same_bytes};

const MAX_NAME: usize = 64;
const MAX_CODE: usize = 128;
const MAX_MISSES: u32 = 5;
pub const PAIRING_TTL_MS: u64 = 5 * 60_000;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HandshakeHello {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pairing_code: Option<String>,
}

impl HandshakeHello {
    pub fn encode(&self) -> Result<Vec<u8>, LinkError> {
        self.check()?;
        Ok(serde_json::to_vec(self).expect("plain strings"))
    }

    pub fn decode(data: &[u8]) -> Result<Self, LinkError> {
        if data.is_empty() {
            return Ok(Self::default());
        }
        let hello: Self = serde_json::from_slice(data)
            .map_err(|_| LinkError::invalid("The handshake hello is invalid."))?;
        hello.check()?;
        Ok(hello)
    }

    fn check(&self) -> Result<(), LinkError> {
        if self
            .name
            .as_deref()
            .is_some_and(|name| js_len(name) > MAX_NAME)
        {
            return Err(LinkError::invalid("The device name is invalid."));
        }
        if self
            .pairing_code
            .as_deref()
            .is_some_and(|code| code.is_empty() || js_len(code) > MAX_CODE)
        {
            return Err(LinkError::invalid("The pairing code is invalid."));
        }
        Ok(())
    }
}

/// What the computer's pairing QR code carries to the phone.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingOffer {
    pub server: String,
    pub host_device_id: String,
    pub host_key: String,
    pub code: String,
    pub name: String,
}

pub fn pairing_uri(offer: &PairingOffer) -> String {
    let query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("v", "1")
        .append_pair("server", &offer.server)
        .append_pair("host", &offer.host_device_id)
        .append_pair("key", &offer.host_key)
        .append_pair("code", &offer.code)
        .append_pair("name", &offer.name)
        .finish();
    format!("dsbot://pair?{query}")
}

pub fn parse_pairing_uri(uri: &str) -> Result<PairingOffer, LinkError> {
    let not_ours = || LinkError::invalid("This is not a DS Bot pairing code.");
    let url = Url::parse(uri).map_err(|_| not_ours())?;
    let field = |name: &str| {
        url.query_pairs()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.into_owned())
    };
    if url.scheme() != "dsbot"
        || url.host_str() != Some("pair")
        || field("v").as_deref() != Some("1")
    {
        return Err(not_ours());
    }
    let required = |name: &str| {
        field(name)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| LinkError::invalid(format!("The pairing code has no {name}.")))
    };
    let server = required("server")?;
    if !Url::parse(&server).is_ok_and(|parsed| matches!(parsed.scheme(), "ws" | "wss")) {
        return Err(LinkError::invalid(
            "The pairing code names an invalid Server.",
        ));
    }
    let offer = PairingOffer {
        server,
        host_device_id: required("host")?,
        host_key: required("key")?,
        code: required("code")?,
        name: js_truncate(&field("name").unwrap_or_default(), MAX_NAME),
    };
    if device_id_for(&offer.host_key).ok().as_deref() != Some(offer.host_device_id.as_str()) {
        return Err(LinkError::invalid(
            "The pairing code does not match its computer.",
        ));
    }
    Ok(offer)
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairedDevice {
    pub device_id: String,
    pub identity_key: String,
    pub name: String,
    pub paired_at: u64,
}

#[derive(Clone, Debug)]
struct OpenPairing {
    code: String,
    expires_at: u64,
    misses: u32,
}

/// The phones a computer trusts, and the one pairing code it may have open. A code
/// works once, ends after a time limit, and closes after a few wrong tries. Calls that
/// change the list return true so the caller can save it.
#[derive(Clone, Debug, Default)]
pub struct DeviceRegistry {
    devices: Vec<PairedDevice>,
    pairing: Option<OpenPairing>,
}

impl DeviceRegistry {
    pub fn new(devices: Vec<PairedDevice>) -> Self {
        let mut registry = Self::default();
        for device in devices {
            registry
                .devices
                .retain(|known| known.device_id != device.device_id);
            registry.devices.push(device);
        }
        registry
    }

    pub fn list(&self) -> &[PairedDevice] {
        &self.devices
    }

    pub fn open_pairing(&mut self, ttl_ms: u64, now: u64) -> (String, u64) {
        let pairing = OpenPairing {
            code: random_token(18),
            expires_at: now + ttl_ms,
            misses: 0,
        };
        let opened = (pairing.code.clone(), pairing.expires_at);
        self.pairing = Some(pairing);
        opened
    }

    pub fn close_pairing(&mut self) {
        self.pairing = None;
    }

    pub fn pairing_open(&mut self, now: u64) -> bool {
        if self
            .pairing
            .as_ref()
            .is_some_and(|pairing| now >= pairing.expires_at)
        {
            self.pairing = None;
        }
        self.pairing.is_some()
    }

    /// Whether a device may start a handshake: it is paired, or a pairing code is open.
    pub fn admits(&mut self, device_id: &str, identity_key: &str, now: u64) -> bool {
        self.matches(device_id, identity_key) || self.pairing_open(now)
    }

    /// The check after the handshake: a paired device, or a new one that holds the
    /// open code. Returns (allowed, list changed).
    pub fn authorize(
        &mut self,
        device_id: &str,
        identity_key: &str,
        hello: &HandshakeHello,
        now: u64,
    ) -> (bool, bool) {
        if self.matches(device_id, identity_key) {
            return (true, false);
        }
        let Some(code) = hello.pairing_code.as_deref() else {
            return (false, false);
        };
        if !self.pairing_open(now) {
            return (false, false);
        }
        let pairing = self.pairing.as_mut().expect("open");
        if !same_bytes(code.as_bytes(), pairing.code.as_bytes()) {
            pairing.misses += 1;
            if pairing.misses >= MAX_MISSES {
                self.pairing = None;
            }
            return (false, false);
        }
        self.pairing = None;
        self.devices.retain(|known| known.device_id != device_id);
        self.devices.push(PairedDevice {
            device_id: device_id.into(),
            identity_key: identity_key.into(),
            name: hello.name.clone().unwrap_or_default(),
            paired_at: now,
        });
        (true, true)
    }

    pub fn revoke(&mut self, device_id: &str) -> bool {
        let before = self.devices.len();
        self.devices.retain(|known| known.device_id != device_id);
        self.devices.len() != before
    }

    fn matches(&self, device_id: &str, identity_key: &str) -> bool {
        self.devices.iter().any(|known| {
            known.device_id == device_id
                && same_bytes(known.identity_key.as_bytes(), identity_key.as_bytes())
        })
    }
}

/// Length as JavaScript counts it, so limits match the TS and Dart checks.
fn js_len(text: &str) -> usize {
    text.encode_utf16().count()
}

fn js_truncate(text: &str, max: usize) -> String {
    let mut units = 0;
    text.chars()
        .take_while(|ch| {
            units += ch.len_utf16();
            units <= max
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::generate_key_pair;

    #[test]
    fn hello_round_trips_and_checks_limits() {
        let hello = HandshakeHello {
            name: Some("Pixel".into()),
            pairing_code: Some("abc".into()),
        };
        let bytes = hello.encode().unwrap();
        assert_eq!(
            std::str::from_utf8(&bytes).unwrap(),
            r#"{"name":"Pixel","pairingCode":"abc"}"#
        );
        assert_eq!(HandshakeHello::decode(&bytes).unwrap(), hello);
        assert_eq!(
            HandshakeHello::decode(b"").unwrap(),
            HandshakeHello::default()
        );
        assert!(HandshakeHello::decode(br#"{"pairingCode":""}"#).is_err());
        assert!(
            HandshakeHello::decode(format!(r#"{{"name":"{}"}}"#, "x".repeat(65)).as_bytes())
                .is_err()
        );
    }

    #[test]
    fn pairing_uri_round_trips_and_checks_the_key() {
        let pair = generate_key_pair(None).unwrap();
        let offer = PairingOffer {
            server: "wss://relay.test/v2/link".into(),
            host_device_id: device_id_for(&pair.public_key).unwrap(),
            host_key: pair.public_key.clone(),
            code: "c0de".into(),
            name: "My PC & co".into(),
        };
        let uri = pairing_uri(&offer);
        assert!(uri.starts_with("dsbot://pair?v=1&server=wss%3A%2F%2Frelay.test%2Fv2%2Flink&"));
        assert!(uri.ends_with("&name=My+PC+%26+co"));
        assert_eq!(parse_pairing_uri(&uri).unwrap(), offer);
        let wrong = PairingOffer {
            host_device_id: "d-other".into(),
            ..offer.clone()
        };
        assert!(parse_pairing_uri(&pairing_uri(&wrong)).is_err());
        let http = PairingOffer {
            server: "https://relay.test".into(),
            ..offer
        };
        assert!(parse_pairing_uri(&pairing_uri(&http)).is_err());
        assert!(parse_pairing_uri("https://example.test").is_err());
    }

    #[test]
    fn registry_pairs_once_and_closes_after_misses() {
        let mut registry = DeviceRegistry::default();
        let hello = |code: &str| HandshakeHello {
            name: Some("Pixel".into()),
            pairing_code: Some(code.into()),
        };
        assert!(!registry.admits("d-a", "ka", 0));
        let (code, expires) = registry.open_pairing(PAIRING_TTL_MS, 1_000);
        assert_eq!(expires, 1_000 + PAIRING_TTL_MS);
        assert!(registry.admits("d-a", "ka", 2_000));
        assert_eq!(
            registry.authorize("d-a", "ka", &hello(&code), 2_000),
            (true, true)
        );
        assert!(!registry.pairing_open(2_000));
        assert_eq!(
            registry.authorize("d-a", "ka", &HandshakeHello::default(), 3_000),
            (true, false)
        );
        assert_eq!(
            registry.authorize("d-a", "other", &HandshakeHello::default(), 3_000),
            (false, false)
        );
        assert_eq!(registry.list()[0].name, "Pixel");

        registry.open_pairing(PAIRING_TTL_MS, 4_000);
        for _ in 0..5 {
            assert_eq!(
                registry.authorize("d-b", "kb", &hello("wrong"), 4_000),
                (false, false)
            );
        }
        assert!(!registry.pairing_open(4_000));

        let (code, _) = registry.open_pairing(10, 5_000);
        assert_eq!(
            registry.authorize("d-b", "kb", &hello(&code), 5_010),
            (false, false)
        );
        assert!(registry.revoke("d-a"));
        assert!(!registry.revoke("d-a"));
    }
}
