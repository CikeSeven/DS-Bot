use dsbot_link_host::{DEFAULT_MAX_LINKS, HostAction, HostConfig};
use serde::Deserialize;
use wasm_bindgen::prelude::*;

use crate::{Fields, IdentityKeys, from_js, ms, num};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HostOptions {
    server: String,
    identity: IdentityKeys,
    access_token: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    max_links: Option<usize>,
}

/// The computer's end of the link, without IO: `link/js/host.js` drives it.
#[wasm_bindgen]
pub struct HostCore {
    inner: dsbot_link_host::HostCore,
}

#[wasm_bindgen]
impl HostCore {
    /// `options`: `{server, identity: {deviceId?, publicKey, privateKey}, accessToken, name?, maxLinks?}`.
    #[wasm_bindgen(constructor)]
    pub fn new(options: JsValue, now: f64) -> Result<HostCore, JsValue> {
        let options: HostOptions = from_js(&options)?;
        let config = HostConfig {
            server: options.server,
            identity: options.identity.identity()?,
            access_token: options.access_token,
            name: options.name,
            max_links: options.max_links.unwrap_or(DEFAULT_MAX_LINKS),
        };
        Ok(HostCore {
            inner: dsbot_link_host::HostCore::new(config, ms(now)),
        })
    }

    /// `'stopped' | 'connecting' | 'online' | 'offline'`.
    pub fn status(&self) -> String {
        self.inner.status().as_str().into()
    }

    pub fn error(&self) -> Option<String> {
        self.inner.error().map(String::from)
    }

    #[wasm_bindgen(js_name = connectedDevices)]
    pub fn connected_devices(&self) -> Vec<String> {
        self.inner.connected_devices()
    }

    #[wasm_bindgen(js_name = nextDeadline)]
    pub fn next_deadline(&self) -> Option<f64> {
        self.inner.next_deadline().map(|at| at as f64)
    }

    /// The next action, or `undefined`.
    #[wasm_bindgen(js_name = pollAction)]
    pub fn poll_action(&mut self) -> JsValue {
        self.inner.poll_action().map_or(JsValue::UNDEFINED, action)
    }

    pub fn start(&mut self, now: f64) {
        self.inner.start(ms(now));
    }

    pub fn stop(&mut self, now: f64) {
        self.inner.stop(ms(now));
    }

    #[wasm_bindgen(js_name = socketOpened)]
    pub fn socket_opened(&mut self, socket: f64, now: f64) {
        self.inner.socket_opened(socket as u64, ms(now));
    }

    #[wasm_bindgen(js_name = socketText)]
    pub fn socket_text(&mut self, socket: f64, text: &str, now: f64) {
        self.inner.socket_text(socket as u64, text, ms(now));
    }

    #[wasm_bindgen(js_name = socketBinary)]
    pub fn socket_binary(&mut self, socket: f64, data: &[u8], now: f64) {
        self.inner.socket_binary(socket as u64, data, ms(now));
    }

    #[wasm_bindgen(js_name = socketClosed)]
    pub fn socket_closed(&mut self, socket: f64, reason: Option<String>, now: f64) {
        self.inner
            .socket_closed(socket as u64, reason.as_deref(), ms(now));
    }

    pub fn tick(&mut self, now: f64) {
        self.inner.tick(ms(now));
    }

    pub fn authorize(&mut self, link: &str, allowed: bool, now: f64) {
        self.inner.authorize(link, allowed, ms(now));
    }

    /// `result` is the call's answer as JSON.
    pub fn respond(&mut self, link: &str, request: &str, result: &str, now: f64) {
        self.inner.respond(link, request, result, ms(now));
    }

    #[wasm_bindgen(js_name = respondError)]
    pub fn respond_error(
        &mut self,
        link: &str,
        request: &str,
        code: &str,
        message: &str,
        now: f64,
    ) {
        self.inner
            .respond_error(link, request, code, message, ms(now));
    }

    /// `data` is JSON.
    pub fn emit(&mut self, event: &str, data: &str, now: f64) {
        self.inner.emit(event, data, ms(now));
    }

    pub fn disconnect(&mut self, device_id: &str, now: f64) {
        self.inner.disconnect(device_id, ms(now));
    }
}

fn action(action: HostAction) -> JsValue {
    match action {
        HostAction::Connect { socket, url } => Fields::action("connect")
            .set("socket", num(socket))
            .set("url", url),
        HostAction::SendText { socket, text } => Fields::action("sendText")
            .set("socket", num(socket))
            .set("text", text),
        HostAction::SendBinary { socket, data } => Fields::action("sendBinary")
            .set("socket", num(socket))
            .set("data", js_sys::Uint8Array::from(data.as_slice())),
        HostAction::CloseSocket { socket } => {
            Fields::action("closeSocket").set("socket", num(socket))
        }
        HostAction::Status(status) => Fields::action("status").set("status", status.as_str()),
        HostAction::Authorize {
            link,
            device_id,
            identity_key,
            name,
            pairing_code,
        } => Fields::action("authorize")
            .set("link", link)
            .set("deviceId", device_id)
            .set("identityKey", identity_key)
            .opt("name", name)
            .opt("pairingCode", pairing_code),
        HostAction::Request {
            link,
            request,
            device_id,
            method,
            params,
        } => Fields::action("request")
            .set("link", link)
            .set("request", request)
            .set("deviceId", device_id)
            .set("method", method)
            .set("params", params),
        HostAction::Cancel { link, request } => Fields::action("cancel")
            .set("link", link)
            .set("request", request),
        HostAction::ReadyCount(count) => {
            Fields::action("readyCount").set("count", num(count as u64))
        }
    }
    .into()
}
