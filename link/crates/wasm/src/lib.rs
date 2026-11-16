//! The DS Bot phone link for the computer, as WebAssembly. `link/js` wraps it: the
//! JavaScript there owns the WebSockets and the timers, everything else is here.
//!
//! Actions leave as plain objects `{type, ...}`, bytes as `Uint8Array`, JSON payloads as
//! strings. Times are `Date.now()` milliseconds and socket ids are numbers. Errors are
//! `Error`s with a `code`.

mod client;
mod host;
mod registry;
mod relay;

use dsbot_link_core::LinkError;
use dsbot_link_core::keys::{self, Identity};
use dsbot_link_core::pairing::{self, PairingOffer};
use dsbot_link_core::wire;
use js_sys::{Object, Reflect};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use wasm_bindgen::prelude::*;

pub use client::ClientCore;
pub use host::HostCore;
pub use registry::DeviceRegistry;
pub use relay::RelayCore;

#[wasm_bindgen(js_name = linkPath)]
pub fn link_path() -> String {
    wire::LINK_PATH.into()
}

#[wasm_bindgen(js_name = deviceIdFor)]
pub fn device_id_for(public_key: &str) -> Result<String, JsValue> {
    keys::device_id_for(public_key).map_err(js_error)
}

#[wasm_bindgen(js_name = generateKeyPair)]
pub fn generate_key_pair(private_key: Option<Vec<u8>>) -> Result<JsValue, JsValue> {
    let bytes = private_key
        .map(|bytes| {
            <[u8; 32]>::try_from(bytes).map_err(|_| {
                js_error(LinkError::new(
                    "INVALID_KEY",
                    "X25519 private keys must be 32 bytes.",
                ))
            })
        })
        .transpose()?;
    let pair = keys::generate_key_pair(bytes.as_ref()).map_err(js_error)?;
    Ok(Fields::new()
        .set("publicKey", pair.public_key)
        .set("privateKey", pair.private_key)
        .into())
}

#[wasm_bindgen(js_name = identityFingerprint)]
pub fn identity_fingerprint(public_key: &str) -> Result<String, JsValue> {
    keys::identity_fingerprint(public_key).map_err(js_error)
}

#[wasm_bindgen(js_name = randomToken)]
pub fn random_token(bytes: Option<u32>) -> String {
    keys::random_token(bytes.unwrap_or(32) as usize)
}

#[wasm_bindgen(js_name = pairingUri)]
pub fn pairing_uri(offer: JsValue) -> Result<String, JsValue> {
    let offer: PairingOffer = from_js(&offer)?;
    Ok(pairing::pairing_uri(&offer))
}

#[wasm_bindgen(js_name = parsePairingUri)]
pub fn parse_pairing_uri(uri: &str) -> Result<JsValue, JsValue> {
    let offer = pairing::parse_pairing_uri(uri).map_err(js_error)?;
    to_js(&offer)
}

pub(crate) fn js_error(error: LinkError) -> JsValue {
    let js = js_sys::Error::new(&error.message);
    Reflect::set(&js, &"code".into(), &error.code.into()).expect("an Error takes fields");
    js.into()
}

/// Reads a plain JS value through JSON, so serde does the checking.
pub(crate) fn from_js<T: DeserializeOwned>(value: &JsValue) -> Result<T, JsValue> {
    let text = js_sys::JSON::stringify(value)
        .ok()
        .and_then(|text| text.as_string())
        .unwrap_or_default();
    serde_json::from_str(&text)
        .map_err(|error| js_error(LinkError::invalid(format!("Invalid argument: {error}"))))
}

pub(crate) fn to_js<T: serde::Serialize>(value: &T) -> Result<JsValue, JsValue> {
    js_sys::JSON::parse(&serde_json::to_string(value).expect("plain data"))
}

/// `Date.now()` as the cores count time.
pub(crate) fn ms(now: f64) -> u64 {
    now.max(0.0) as u64
}

/// An id or a count for JS; plain numbers, not BigInts.
pub(crate) fn num(value: u64) -> JsValue {
    JsValue::from_f64(value as f64)
}

/// A plain object built field by field; `None` fields are left out.
pub(crate) struct Fields(Object);

impl Fields {
    pub(crate) fn new() -> Self {
        Self(Object::new())
    }

    pub(crate) fn action(kind: &str) -> Self {
        Self::new().set("type", kind)
    }

    pub(crate) fn set(self, key: &str, value: impl Into<JsValue>) -> Self {
        Reflect::set(&self.0, &key.into(), &value.into()).expect("a plain object takes fields");
        self
    }

    pub(crate) fn opt(self, key: &str, value: Option<impl Into<JsValue>>) -> Self {
        match value {
            Some(value) => self.set(key, value),
            None => self,
        }
    }
}

impl From<Fields> for JsValue {
    fn from(fields: Fields) -> Self {
        fields.0.into()
    }
}

/// The key pair in the options of the cores. `deviceId`, when given, must match the key.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct IdentityKeys {
    #[serde(default)]
    device_id: Option<String>,
    public_key: String,
    private_key: String,
}

impl IdentityKeys {
    pub(crate) fn identity(&self) -> Result<Identity, JsValue> {
        let identity = Identity::new(&self.public_key, &self.private_key).map_err(js_error)?;
        if self
            .device_id
            .as_ref()
            .is_some_and(|id| *id != identity.device_id)
        {
            return Err(js_error(LinkError::new(
                "INVALID_KEY",
                "The device id does not match the identity key.",
            )));
        }
        Ok(identity)
    }
}
