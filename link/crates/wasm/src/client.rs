use dsbot_link_client::{ClientAction, ClientConfig, LinkStatus};
use serde::Deserialize;
use wasm_bindgen::prelude::*;

use crate::{Fields, IdentityKeys, from_js, ms, num};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClientOptions {
    server: String,
    identity: IdentityKeys,
    access_token: String,
    host_device_id: String,
    host_key: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    pairing_code: Option<String>,
}

/// The phone's end of the link, without IO. The computer runs it only in tests.
#[wasm_bindgen]
pub struct ClientCore {
    inner: dsbot_link_client::ClientCore,
}

#[wasm_bindgen]
impl ClientCore {
    /// `options`: `{server, identity: {deviceId?, publicKey, privateKey}, accessToken, hostDeviceId, hostKey, name?, pairingCode?}`.
    #[wasm_bindgen(constructor)]
    pub fn new(options: JsValue, now: f64) -> Result<ClientCore, JsValue> {
        let options: ClientOptions = from_js(&options)?;
        let config = ClientConfig {
            server: options.server,
            identity: options.identity.identity()?,
            access_token: options.access_token,
            host_device_id: options.host_device_id,
            host_key: options.host_key,
            name: options.name,
            pairing_code: options.pairing_code,
        };
        Ok(ClientCore {
            inner: dsbot_link_client::ClientCore::new(config, ms(now)),
        })
    }

    /// The status as the `status` action carries it, or `undefined` before `start`.
    pub fn status(&self) -> JsValue {
        self.inner.status().map_or(JsValue::UNDEFINED, |status| {
            status_fields(Fields::new(), status).into()
        })
    }

    #[wasm_bindgen(js_name = hostName)]
    pub fn host_name(&self) -> Option<String> {
        self.inner.host_name().map(String::from)
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

    #[wasm_bindgen(js_name = networkChanged)]
    pub fn network_changed(&mut self, now: f64) {
        self.inner.network_changed(ms(now));
    }

    #[wasm_bindgen(js_name = setForeground)]
    pub fn set_foreground(&mut self, foreground: bool, now: f64) {
        self.inner.set_foreground(foreground, ms(now));
    }

    /// Sends a call with JSON `params`; returns the id its `rpcDone` action carries.
    /// A `timeoutMs` of 0 means the default.
    pub fn rpc(&mut self, method: &str, params: &str, timeout_ms: f64, now: f64) -> f64 {
        self.inner.rpc(method, params, ms(timeout_ms), ms(now)) as f64
    }

    pub fn close(&mut self, now: f64) {
        self.inner.close(ms(now));
    }
}

fn status_fields(fields: Fields, status: &LinkStatus) -> Fields {
    match status {
        LinkStatus::Connecting { attempt, error } => fields
            .set("status", "connecting")
            .set("attempt", num(u64::from(*attempt)))
            .opt("error", error.clone()),
        LinkStatus::Online { resumed } => fields.set("status", "online").set("resumed", *resumed),
        LinkStatus::Reconnecting { attempt, error } => fields
            .set("status", "reconnecting")
            .set("attempt", num(u64::from(*attempt)))
            .opt("error", error.clone()),
        LinkStatus::HostAway => fields.set("status", "hostAway"),
        LinkStatus::Rejected { code, message } => fields
            .set("status", "rejected")
            .set("code", code.clone())
            .set("message", message.clone()),
        LinkStatus::Closed => fields.set("status", "closed"),
    }
}

fn action(action: ClientAction) -> JsValue {
    match action {
        ClientAction::Connect { socket, url } => Fields::action("connect")
            .set("socket", num(socket))
            .set("url", url),
        ClientAction::SendText { socket, text } => Fields::action("sendText")
            .set("socket", num(socket))
            .set("text", text),
        ClientAction::SendBinary { socket, data } => Fields::action("sendBinary")
            .set("socket", num(socket))
            .set("data", js_sys::Uint8Array::from(data.as_slice())),
        ClientAction::CloseSocket { socket } => {
            Fields::action("closeSocket").set("socket", num(socket))
        }
        ClientAction::Status(status) => status_fields(Fields::action("status"), &status),
        ClientAction::Event { name, data } => {
            Fields::action("event").set("name", name).set("data", data)
        }
        ClientAction::RpcDone {
            call,
            result: Ok(result),
        } => Fields::action("rpcDone")
            .set("call", num(call))
            .set("ok", true)
            .set("result", result),
        ClientAction::RpcDone {
            call,
            result: Err(error),
        } => Fields::action("rpcDone")
            .set("call", num(call))
            .set("ok", false)
            .set("code", error.code)
            .set("message", error.message),
    }
    .into()
}
