//! Identity keys, device ids and random tokens, the same as protocol v1.

use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use x25519_dalek::{PublicKey, StaticSecret};

use crate::b64;
use crate::error::LinkError;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyPair {
    pub public_key: String,
    pub private_key: String,
}

/// An identity: its key pair and the id the key gives it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub device_id: String,
    pub public_key: String,
    pub private_key: String,
}

impl Identity {
    pub fn new(public_key: &str, private_key: &str) -> Result<Self, LinkError> {
        let derived = generate_key_pair(Some(&key_bytes(private_key)?))?;
        if derived
            .public_key
            .as_bytes()
            .ct_eq(public_key.as_bytes())
            .unwrap_u8()
            == 0
        {
            return Err(LinkError::new(
                "INVALID_KEY",
                "The public key does not belong to the private key.",
            ));
        }
        Ok(Self {
            device_id: device_id_for(public_key)?,
            public_key: public_key.into(),
            private_key: private_key.into(),
        })
    }

    pub fn private_bytes(&self) -> [u8; 32] {
        key_bytes(&self.private_key).expect("checked when made")
    }

    pub fn public_bytes(&self) -> [u8; 32] {
        key_bytes(&self.public_key).expect("checked when made")
    }
}

pub fn random_bytes(len: usize) -> Vec<u8> {
    let mut bytes = vec![0; len];
    getrandom::fill(&mut bytes).expect("the system has no random source");
    bytes
}

pub fn generate_key_pair(private_key: Option<&[u8; 32]>) -> Result<KeyPair, LinkError> {
    let bytes: [u8; 32] = match private_key {
        Some(bytes) => *bytes,
        None => random_bytes(32).try_into().expect("32 bytes"),
    };
    let secret = StaticSecret::from(bytes);
    let public = PublicKey::from(&secret);
    Ok(KeyPair {
        public_key: b64::encode(public.as_bytes()),
        private_key: b64::encode(&secret.to_bytes()),
    })
}

/// A device's id is derived from its identity key, so the Server can check one against the other.
pub fn device_id_for(public_key: &str) -> Result<String, LinkError> {
    let key = key_bytes(public_key)?;
    Ok(format!("d-{}", b64::encode(&Sha256::digest(key)[..16])))
}

/// Short code both screens show at pairing, so the user can see they hold the same key.
pub fn identity_fingerprint(public_key: &str) -> Result<String, LinkError> {
    let key = key_bytes(public_key)?;
    Ok(Sha256::digest(key)[..6]
        .iter()
        .map(|byte| format!("{byte:02X}"))
        .collect())
}

pub fn random_token(bytes: usize) -> String {
    b64::encode(&random_bytes(bytes))
}

pub fn key_bytes(key: &str) -> Result<[u8; 32], LinkError> {
    b64::decode(key)
        .and_then(|bytes| <[u8; 32]>::try_from(bytes).ok())
        .ok_or_else(|| LinkError::new("INVALID_KEY", "X25519 keys must be 32 bytes."))
}

pub fn same_bytes(left: &[u8], right: &[u8]) -> bool {
    left.len() == right.len() && left.ct_eq(right).unwrap_u8() == 1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_matches_its_key() {
        let pair = generate_key_pair(None).unwrap();
        let identity = Identity::new(&pair.public_key, &pair.private_key).unwrap();
        assert!(identity.device_id.starts_with("d-"));
        assert_eq!(identity.device_id.len(), 2 + 22);
        let other = generate_key_pair(None).unwrap();
        assert!(Identity::new(&other.public_key, &pair.private_key).is_err());
        assert_eq!(identity_fingerprint(&pair.public_key).unwrap().len(), 12);
    }
}
