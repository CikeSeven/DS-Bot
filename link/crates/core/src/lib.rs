//! The DS Bot phone link, protocol v2. See docs/plans/2026-11-16-link-v2.md.
//!
//! Nothing here does IO or reads a clock: the runtimes (the Relay Server, the
//! phone app's Rust library and the computer's WASM) pass time in and carry out
//! the frames this code returns.

pub mod b64;
pub mod backoff;
pub mod channel;
pub mod conn;
pub mod error;
pub mod frag;
pub mod keys;
pub mod message;
pub mod noise;
pub mod pairing;
pub mod wire;

#[cfg(test)]
mod vectors;

pub use error::LinkError;
