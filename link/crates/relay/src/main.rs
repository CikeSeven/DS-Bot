//! `dsbot-link-relay`: the DS Bot phone link's Relay Server. Settings come from the
//! environment; the first line on stdout is the WebSocket address it serves.

use std::io::IsTerminal;
use std::process::ExitCode;

use dsbot_link_relay::server::{self, Settings};
use tokio::net::TcpListener;
use tracing::{error, info};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> ExitCode {
    // Logs go to stderr so stdout carries only the address.
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .with_ansi(std::io::stderr().is_terminal())
        .init();
    match start().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            error!("{message}");
            ExitCode::FAILURE
        }
    }
}

async fn start() -> Result<(), String> {
    let settings = Settings::from_env()?;
    let (host, port) = server::listen_from_env()?;
    let listener = TcpListener::bind((host.as_str(), port))
        .await
        .map_err(|error| format!("Cannot listen on {host}:{port}: {error}"))?;
    let address = listener.local_addr().map_err(|error| error.to_string())?;
    println!("{}", server::link_url(address));
    info!(url = %server::link_url(address), "DS Bot link Relay Server is listening");
    server::run(listener, settings, shutdown_signal())
        .await
        .map_err(|error| error.to_string())
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        let mut terminate = signal(SignalKind::terminate()).expect("a SIGTERM handler");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}
