//! The devices the Relay Server has seen, in the same JSON as the v1 TS relay's file.
//!
//! A device claims its id with its first access token; later hellos must bring the same
//! token, role and key. The relay keeps no account and no message content.

use std::collections::BTreeMap;

use dsbot_link_core::LinkError;
use dsbot_link_core::b64;
use dsbot_link_core::keys::same_bytes;
use dsbot_link_core::wire::Role;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub const MAX_DEVICES: usize = 100_000;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceRecord {
    pub role: Role,
    pub identity_key: String,
    pub token_hash: String,
    pub first_seen: u64,
    pub last_seen: u64,
}

#[derive(Clone, Debug)]
pub struct DeviceStore {
    devices: BTreeMap<String, DeviceRecord>,
    max_devices: usize,
    dirty: bool,
}

impl Default for DeviceStore {
    fn default() -> Self {
        Self {
            devices: BTreeMap::new(),
            max_devices: MAX_DEVICES,
            dirty: false,
        }
    }
}

impl DeviceStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn from_json(text: &str) -> Result<Self, serde_json::Error> {
        Ok(Self {
            devices: serde_json::from_str(text)?,
            ..Self::default()
        })
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(&self.devices).expect("plain data")
    }

    pub fn get(&self, device_id: &str) -> Option<&DeviceRecord> {
        self.devices.get(device_id)
    }

    pub fn len(&self) -> usize {
        self.devices.len()
    }

    pub fn is_empty(&self) -> bool {
        self.devices.is_empty()
    }

    /// Checks a hello against the record, or records the device on first sight.
    pub fn admit(
        &mut self,
        device_id: &str,
        role: Role,
        identity_key: &str,
        access_token: &str,
        now: u64,
    ) -> Result<(), LinkError> {
        let token_hash = token_hash(access_token);
        if let Some(known) = self.devices.get_mut(device_id) {
            if known.role != role
                || known.identity_key != identity_key
                || !same_bytes(known.token_hash.as_bytes(), token_hash.as_bytes())
            {
                return Err(LinkError::new(
                    "AUTH_INVALID",
                    "The device was registered with another token, role or key.",
                ));
            }
            known.last_seen = now;
            self.dirty = true;
            return Ok(());
        }
        if self.devices.len() >= self.max_devices {
            return Err(LinkError::new(
                "SERVER_FULL",
                "The Relay Server knows too many devices.",
            ));
        }
        let record = DeviceRecord {
            role,
            identity_key: identity_key.into(),
            token_hash,
            first_seen: now,
            last_seen: now,
        };
        self.devices.insert(device_id.into(), record);
        self.dirty = true;
        Ok(())
    }

    pub fn touch(&mut self, device_id: &str, now: u64) {
        if let Some(record) = self.devices.get_mut(device_id) {
            record.last_seen = now;
            self.dirty = true;
        }
    }

    /// Forgets devices not seen for `max_age_ms`. A forgotten device claims its id again on its next hello.
    pub fn prune(&mut self, max_age_ms: u64, now: u64) -> usize {
        let before = self.devices.len();
        self.devices
            .retain(|_, record| now.saturating_sub(record.last_seen) <= max_age_ms);
        let removed = before - self.devices.len();
        if removed > 0 {
            self.dirty = true;
        }
        removed
    }

    /// True when the records changed since the last `mark_saved`.
    pub fn dirty(&self) -> bool {
        self.dirty
    }

    pub fn mark_saved(&mut self) {
        self.dirty = false;
    }

    #[cfg(test)]
    pub(crate) fn with_max_devices(max_devices: usize) -> Self {
        Self {
            max_devices,
            ..Self::default()
        }
    }
}

/// `b64url(sha256(token))`, as the v1 relay stored it.
pub fn token_hash(access_token: &str) -> String {
    b64::encode(&Sha256::digest(access_token.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const V1_FILE: &str = r#"{"d-host":{"role":"host","identityKey":"key-h","tokenHash":"ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0","firstSeen":1700000000000,"lastSeen":1700000500000},"d-phone":{"role":"client","identityKey":"key-p","tokenHash":"x","firstSeen":1,"lastSeen":2,"extra":true}}"#;

    #[test]
    fn reads_and_writes_the_v1_file() {
        let store = DeviceStore::from_json(V1_FILE).unwrap();
        assert_eq!(store.len(), 2);
        let host = store.get("d-host").unwrap();
        assert_eq!(host.role, Role::Host);
        assert_eq!(host.identity_key, "key-h");
        assert_eq!(host.first_seen, 1_700_000_000_000);
        assert_eq!(host.last_seen, 1_700_000_500_000);
        let written = store.to_json();
        assert!(written.contains(r#""d-host":{"role":"host","identityKey":"key-h","tokenHash":"ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0","firstSeen":1700000000000,"lastSeen":1700000500000}"#));
        let again = DeviceStore::from_json(&written).unwrap();
        assert_eq!(again.get("d-phone"), store.get("d-phone"));
        assert!(!again.dirty());
        assert!(DeviceStore::from_json(r#"{"d-x":{"role":"admin"}}"#).is_err());
    }

    #[test]
    fn hashes_tokens_like_v1() {
        assert_eq!(
            token_hash("abc"),
            "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0"
        );
    }

    #[test]
    fn binds_the_first_token_role_and_key() {
        let mut store = DeviceStore::from_json(V1_FILE).unwrap();
        assert!(store.admit("d-host", Role::Host, "key-h", "abc", 5).is_ok());
        assert_eq!(store.get("d-host").unwrap().last_seen, 5);
        assert!(store.dirty());
        store.mark_saved();
        let refused = |result: Result<(), LinkError>| result.unwrap_err().code;
        assert_eq!(
            refused(store.admit("d-host", Role::Host, "key-h", "abd", 6)),
            "AUTH_INVALID"
        );
        assert_eq!(
            refused(store.admit("d-host", Role::Client, "key-h", "abc", 6)),
            "AUTH_INVALID"
        );
        assert_eq!(
            refused(store.admit("d-host", Role::Host, "key-x", "abc", 6)),
            "AUTH_INVALID"
        );
        assert!(!store.dirty());
        store
            .admit("d-new", Role::Client, "key-n", "token", 7)
            .unwrap();
        let record = store.get("d-new").unwrap();
        assert_eq!((record.first_seen, record.last_seen), (7, 7));
        assert_eq!(record.token_hash, token_hash("token"));
    }

    #[test]
    fn refuses_new_devices_when_full() {
        let mut store = DeviceStore::with_max_devices(1);
        store.admit("d-a", Role::Client, "a", "t", 1).unwrap();
        assert_eq!(
            store
                .admit("d-b", Role::Client, "b", "t", 1)
                .unwrap_err()
                .code,
            "SERVER_FULL"
        );
        assert!(store.admit("d-a", Role::Client, "a", "t", 2).is_ok());
    }

    #[test]
    fn prunes_devices_not_seen() {
        let mut store = DeviceStore::from_json(V1_FILE).unwrap();
        assert_eq!(store.prune(1_000, 1_700_000_500_500), 1);
        assert!(store.get("d-phone").is_none());
        assert!(store.get("d-host").is_some());
        assert!(store.dirty());
    }
}
