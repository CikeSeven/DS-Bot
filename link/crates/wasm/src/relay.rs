use dsbot_link_relay::{DeviceStore, Refusal, RelayAction, RelayConfig};
use serde::Deserialize;
use wasm_bindgen::prelude::*;

use crate::{Fields, from_js, js_error, ms, num};

#[derive(Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
struct RelayOptions {
    grace_ms: Option<u64>,
    max_sockets: Option<usize>,
    max_links: Option<usize>,
    max_sockets_per_address: Option<usize>,
    max_new_devices_per_hour: Option<u32>,
}

/// The Relay Server's rules, without IO. The computer runs it only in tests.
#[wasm_bindgen]
pub struct RelayCore {
    inner: dsbot_link_relay::RelayCore,
}

#[wasm_bindgen]
impl RelayCore {
    /// `options`: `{graceMs?, maxSockets?, maxLinks?, maxSocketsPerAddress?, maxNewDevicesPerHour?}`;
    /// `devices` is the device table's JSON, if there is one.
    #[wasm_bindgen(constructor)]
    pub fn new(options: JsValue, devices: Option<String>, now: f64) -> Result<RelayCore, JsValue> {
        let options: RelayOptions = if options.is_undefined() || options.is_null() {
            RelayOptions::default()
        } else {
            from_js(&options)?
        };
        let defaults = RelayConfig::default();
        let config = RelayConfig {
            grace_ms: options.grace_ms.unwrap_or(defaults.grace_ms),
            max_sockets: options.max_sockets.unwrap_or(defaults.max_sockets),
            max_links: options.max_links.unwrap_or(defaults.max_links),
            max_sockets_per_address: options
                .max_sockets_per_address
                .unwrap_or(defaults.max_sockets_per_address),
            max_new_devices_per_hour: options
                .max_new_devices_per_hour
                .unwrap_or(defaults.max_new_devices_per_hour),
            ..defaults
        };
        let store = match devices {
            Some(text) => DeviceStore::from_json(&text).map_err(|error| {
                js_error(dsbot_link_core::LinkError::invalid(format!(
                    "The device table is invalid: {error}"
                )))
            })?,
            None => DeviceStore::new(),
        };
        Ok(RelayCore {
            inner: dsbot_link_relay::RelayCore::new(config, store, ms(now)),
        })
    }

    /// The device table as JSON, to save.
    pub fn devices(&self) -> String {
        self.inner.store().to_json()
    }

    #[wasm_bindgen(js_name = linkCount)]
    pub fn link_count(&self) -> f64 {
        self.inner.link_count() as f64
    }

    /// The next action, or `undefined`.
    #[wasm_bindgen(js_name = pollAction)]
    pub fn poll_action(&mut self) -> JsValue {
        self.inner.poll_action().map_or(JsValue::UNDEFINED, action)
    }

    /// Before the WebSocket upgrade: `undefined` to go on, else the HTTP status to refuse with.
    #[wasm_bindgen(js_name = admitSocket)]
    pub fn admit_socket(&mut self, address: &str) -> Option<u16> {
        match self.inner.admit_socket(address) {
            Ok(()) => None,
            Err(Refusal::Forbidden) => Some(403),
            Err(Refusal::TooMany) => Some(429),
        }
    }

    /// The TCP socket of an admitted address ended, upgraded or not.
    #[wasm_bindgen(js_name = releaseSocket)]
    pub fn release_socket(&mut self, address: &str) {
        self.inner.release_socket(address);
    }

    #[wasm_bindgen(js_name = socketOpened)]
    pub fn socket_opened(&mut self, conn: f64, address: &str, now: f64) {
        self.inner.socket_opened(conn as u64, address, ms(now));
    }

    #[wasm_bindgen(js_name = socketText)]
    pub fn socket_text(&mut self, conn: f64, text: &str, now: f64) {
        self.inner.socket_text(conn as u64, text, ms(now));
    }

    #[wasm_bindgen(js_name = socketBinary)]
    pub fn socket_binary(&mut self, conn: f64, data: &[u8], now: f64) {
        self.inner.socket_binary(conn as u64, data, ms(now));
    }

    #[wasm_bindgen(js_name = socketPong)]
    pub fn socket_pong(&mut self, conn: f64, now: f64) {
        self.inner.socket_pong(conn as u64, ms(now));
    }

    #[wasm_bindgen(js_name = socketClosed)]
    pub fn socket_closed(&mut self, conn: f64, now: f64) {
        self.inner.socket_closed(conn as u64, ms(now));
    }

    pub fn tick(&mut self, now: f64) {
        self.inner.tick(ms(now));
    }
}

fn action(action: RelayAction) -> JsValue {
    match action {
        RelayAction::SendText { conn, text } => Fields::action("sendText")
            .set("conn", num(conn))
            .set("text", text),
        RelayAction::SendBinary { conn, data } => Fields::action("sendBinary")
            .set("conn", num(conn))
            .set("data", js_sys::Uint8Array::from(data.as_slice())),
        RelayAction::Ping { conn } => Fields::action("ping").set("conn", num(conn)),
        RelayAction::Close { conn, code, reason } => Fields::action("close")
            .set("conn", num(conn))
            .set("code", num(u64::from(code)))
            .set("reason", reason),
    }
    .into()
}
