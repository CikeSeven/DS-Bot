# DS Bot phone link

The encrypted link between the DS Bot phone app and the computer, and the Relay Server between them. Protocol v2, written in Rust. The design is in [docs/plans/2026-11-16-link-v2.md](../docs/plans/2026-11-16-link-v2.md).

A link outlives its socket. When the phone's network drops, the Relay Server keeps the link for a grace period; the phone dials again, attaches to the same link and both ends send what the other has not acked. No new handshake, no resync, no lost events, and a call that was running gets its answer.

| Crate | What it is |
|---|---|
| `crates/core` | Keys, pairing, frames, Noise, the reliable channel, the socket supervisor. No IO, no clock. |
| `crates/client` | `ClientCore`, the phone's session; with the `runtime` feature, its tokio driver. The Flutter app calls it through `mobile_flutter/rust`. |
| `crates/host` | `HostCore`, the computer's end. `ds-bot` runs it as WebAssembly. |
| `crates/relay` | `RelayCore` and the `dsbot-link-relay` server. |
| `crates/wasm` | The WebAssembly build for `ds-bot/link.js` and `ds-bot/link.wasm`. |
| `crates/e2e` | The phone, the Relay Server and the computer together on a simulated network with faults. |
| `js/` | The JavaScript around the WebAssembly that `ds-bot/link.js` is bundled from. |

The phone and the computer each keep an X25519 identity key. The device id is derived from the key. The computer shows a QR code with its key and a one-time pairing code; the phone sends the code inside the encrypted handshake, so the Server never sees it.

## Build and test

Needs Rust (stable) with the `wasm32-unknown-unknown` target, and `wasm-bindgen-cli` 0.2.130 to rebuild `ds-bot/link.wasm`.

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all --check
cd ../ds-bot && npm run build   # rebuilds link.js and link.wasm when the Rust source changed
```

## Run the Relay Server

```sh
PORT=8787 DSBOT_LINK_DATA=./data/devices.json cargo run --release -p dsbot-link-relay
```

It speaks plain `ws://` on `/v2/link`. Put it behind a TLS proxy and give phones the `wss://` address. DS Bot uses `wss://bot.sisct.xyz/v2/link` unless the user enters another Server in Settings → Phone. A Docker image and proxy examples are in [docker/](docker/README.md).

Settings, all optional:

| Variable | Default | |
|---|---|---|
| `HOST`, `PORT` | `0.0.0.0`, `8787` | Where the Server listens |
| `DSBOT_LINK_DATA` | none (memory only) | File for the known devices; the v1 file works as is |
| `DSBOT_LINK_TRUST_PROXY` | off | `1`: take the client address from the last `X-Forwarded-For` entry. Set it only behind a proxy that writes this header |
| `DSBOT_LINK_GRACE_SECONDS` | `120` | How long a link waits for a side whose socket dropped |
| `DSBOT_LINK_MAX_SOCKETS` | `1024` | Open sockets in total |
| `DSBOT_LINK_MAX_LINKS` | `1024` | Phone-to-computer links in total |
| `DSBOT_LINK_MAX_SOCKETS_PER_ADDRESS` | `256` | Open sockets from one address |
| `DSBOT_LINK_MAX_NEW_DEVICES_PER_HOUR` | `20` | New devices one address may register in an hour |
| `DSBOT_LINK_MAX_MB_PER_HOUR` | `512` | MiB one address may send in an hour |
| `DSBOT_LINK_DEVICE_TTL_DAYS` | none | Forget devices not seen for this many days |
| `RUST_LOG` | `info` | Log filter |

Protocol v1 (`/v1/link`) is not served here. Keep the old Server running beside this one until every phone and computer runs the new version.
