use std::env;
use std::net::SocketAddr;
use std::path::PathBuf;

use anyhow::{Context, Result};

#[derive(Clone, Debug)]
pub struct AppConfig {
    pub relay_http_url: Option<String>,
    pub relay_ws_base_url: Option<String>,
    pub daemon_version: String,
    pub machine_name: String,
    pub health_bind_addr: SocketAddr,
    pub state_dir: PathBuf,
}

impl AppConfig {
    pub fn from_env() -> Result<Self> {
        let relay_http_url = env::var("CODEXD_RELAY_HTTP_URL").ok().filter(|value| !value.trim().is_empty());
        let relay_ws_base_url = env::var("CODEXD_RELAY_WS_BASE_URL")
            .ok()
            .filter(|value| !value.trim().is_empty());
        let daemon_version = env!("CARGO_PKG_VERSION").to_string();
        let machine_name = env::var("CODEXD_MACHINE_NAME")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .or_else(default_machine_name)
            .unwrap_or_else(|| "Unknown Mac".to_string());
        let raw_health_bind_addr =
            env::var("CODEXD_HEALTH_BIND_ADDR").unwrap_or_else(|_| "127.0.0.1:8787".to_string());
        let health_bind_addr = raw_health_bind_addr
            .parse()
            .with_context(|| format!("invalid CODEXD_HEALTH_BIND_ADDR: {raw_health_bind_addr}"))?;
        let state_dir = resolve_state_dir()?;

        Ok(Self {
            relay_http_url,
            relay_ws_base_url,
            daemon_version,
            machine_name,
            health_bind_addr,
            state_dir,
        })
    }
}

fn default_machine_name() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        std::env::var("HOSTNAME").ok().filter(|value| !value.trim().is_empty())
    }

    #[cfg(not(target_os = "macos"))]
    {
        std::env::var("HOSTNAME").ok().filter(|value| !value.trim().is_empty())
    }
}

fn resolve_state_dir() -> Result<PathBuf> {
    if let Ok(raw) = env::var("CODEXD_STATE_DIR") {
        let trimmed = raw.trim();
        if !trimmed.is_empty() {
            return Ok(PathBuf::from(trimmed));
        }
    }

    let home_dir = dirs::home_dir().context("could not resolve home directory for codexd state")?;
    Ok(home_dir.join(".codex-remote-v2"))
}
