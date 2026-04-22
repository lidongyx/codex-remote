use std::env;
use std::net::SocketAddr;

use anyhow::{Context, Result};

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub bind_addr: SocketAddr,
}

impl AppConfig {
    pub fn from_env() -> Result<Self> {
        let raw = env::var("CODEX_RELAY_BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:9000".to_string());
        let bind_addr = raw
            .parse()
            .with_context(|| format!("invalid CODEX_RELAY_BIND_ADDR: {raw}"))?;

        Ok(Self { bind_addr })
    }
}
