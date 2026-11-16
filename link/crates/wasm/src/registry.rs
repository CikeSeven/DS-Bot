use dsbot_link_core::pairing::{self, HandshakeHello, PairedDevice};
use wasm_bindgen::prelude::*;

use crate::{Fields, from_js, ms, num, to_js};

/// The phones this computer trusts and its one open pairing code.
#[wasm_bindgen]
pub struct DeviceRegistry {
    inner: pairing::DeviceRegistry,
}

#[wasm_bindgen]
impl DeviceRegistry {
    /// Entries that are not paired devices are skipped, so a damaged file loses only them.
    #[wasm_bindgen(constructor)]
    pub fn new(devices: JsValue) -> DeviceRegistry {
        let entries: Vec<serde_json::Value> = from_js(&devices).unwrap_or_default();
        let devices = entries
            .into_iter()
            .filter_map(|entry| serde_json::from_value::<PairedDevice>(entry).ok())
            .collect();
        DeviceRegistry {
            inner: pairing::DeviceRegistry::new(devices),
        }
    }

    pub fn list(&self) -> Result<JsValue, JsValue> {
        to_js(&self.inner.list())
    }

    #[wasm_bindgen(js_name = openPairing)]
    pub fn open_pairing(&mut self, ttl_ms: f64, now: f64) -> JsValue {
        let (code, expires_at) = self.inner.open_pairing(ms(ttl_ms), ms(now));
        Fields::new()
            .set("code", code)
            .set("expiresAt", num(expires_at))
            .into()
    }

    #[wasm_bindgen(js_name = closePairing)]
    pub fn close_pairing(&mut self) {
        self.inner.close_pairing();
    }

    #[wasm_bindgen(js_name = pairingOpen)]
    pub fn pairing_open(&mut self, now: f64) -> bool {
        self.inner.pairing_open(ms(now))
    }

    pub fn admits(&mut self, device_id: &str, identity_key: &str, now: f64) -> bool {
        self.inner.admits(device_id, identity_key, ms(now))
    }

    /// Returns `{allowed, changed}`; `changed` means the list is to be saved.
    pub fn authorize(
        &mut self,
        device_id: &str,
        identity_key: &str,
        name: Option<String>,
        pairing_code: Option<String>,
        now: f64,
    ) -> JsValue {
        let hello = HandshakeHello { name, pairing_code };
        let (allowed, changed) = self
            .inner
            .authorize(device_id, identity_key, &hello, ms(now));
        Fields::new()
            .set("allowed", allowed)
            .set("changed", changed)
            .into()
    }

    pub fn revoke(&mut self, device_id: &str) -> bool {
        self.inner.revoke(device_id)
    }
}
