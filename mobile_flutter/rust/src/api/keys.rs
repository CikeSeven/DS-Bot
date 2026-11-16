//! Keys, ids and the pairing link, the same as the computer's (link/crates/core).

use dsbot_link_core::{keys, pairing};
use flutter_rust_bridge::frb;

use super::link::LinkFailure;

pub struct KeyPair {
    pub public_key: String,
    pub private_key: String,
}

/// What the computer's pairing QR code carries to the phone.
pub struct PairingOffer {
    pub server: String,
    pub host_device_id: String,
    pub host_key: String,
    pub code: String,
    pub name: String,
}

#[frb(sync)]
pub fn generate_key_pair() -> KeyPair {
    let pair = keys::generate_key_pair(None).expect("a random key");
    KeyPair { public_key: pair.public_key, private_key: pair.private_key }
}

#[frb(sync)]
pub fn device_id_for(public_key: String) -> Result<String, LinkFailure> {
    Ok(keys::device_id_for(&public_key)?)
}

#[frb(sync)]
pub fn identity_fingerprint(public_key: String) -> Result<String, LinkFailure> {
    Ok(keys::identity_fingerprint(&public_key)?)
}

#[frb(sync)]
pub fn random_token(bytes: u32) -> String {
    keys::random_token(bytes as usize)
}

/// Checks the link too: its key must give the device id it names.
#[frb(sync)]
pub fn parse_pairing_uri(uri: String) -> Result<PairingOffer, LinkFailure> {
    let offer = pairing::parse_pairing_uri(&uri)?;
    Ok(PairingOffer {
        server: offer.server,
        host_device_id: offer.host_device_id,
        host_key: offer.host_key,
        code: offer.code,
        name: offer.name,
    })
}
