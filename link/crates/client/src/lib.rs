//! The phone's end of the DS Bot link. `ClientCore` is the session without IO;
//! `runtime` drives it over tokio and a real WebSocket.

#[cfg(feature = "runtime")]
pub mod runtime;
mod session;

pub use session::{ClientAction, ClientConfig, ClientCore, LinkStatus};
