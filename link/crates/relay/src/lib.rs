//! The DS Bot phone link's Relay Server, protocol v2. See docs/plans/2026-11-16-link-v2.md.
//!
//! `RelayCore` and `DeviceStore` do no IO and read no clock, so the computer-side WASM can
//! embed them for tests. The `server` feature adds the tokio + axum runtime and the binary.

mod relay;
pub mod store;

#[cfg(feature = "server")]
pub mod server;

pub use relay::{ConnId, HEARTBEAT_MS, Refusal, RelayAction, RelayConfig, RelayCore};
pub use store::{DeviceRecord, DeviceStore};
