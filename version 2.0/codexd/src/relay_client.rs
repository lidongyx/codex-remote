use std::time::Duration;

use anyhow::{Context, Result};
use futures_util::StreamExt;
use reqwest::Client;
use serde::Serialize;
use tokio::time::sleep;
use tokio_tungstenite::connect_async;
use tracing::{info, warn};
use uuid::Uuid;

use crate::config::AppConfig;
use crate::session_registry::SessionRegistry;
use crate::trust_store::TrustStore;

#[derive(Clone)]
pub struct RelayClient {
    http_client: Client,
    config: AppConfig,
    trust_store: TrustStore,
    session_registry: SessionRegistry,
}

impl RelayClient {
    pub fn new(config: AppConfig, trust_store: TrustStore, session_registry: SessionRegistry) -> Self {
        Self {
            http_client: Client::new(),
            config,
            trust_store,
            session_registry,
        }
    }

    pub async fn run_forever(self) {
        let mut attempt: u32 = 0;

        loop {
            if let Err(error) = self.run_once().await {
                attempt = attempt.saturating_add(1);
                let backoff = (attempt.min(10) as u64) * 2;
                warn!("relay client loop failed: {error:#}; retrying in {}s", backoff.max(2));
                sleep(Duration::from_secs(backoff.max(2))).await;
            } else {
                attempt = 0;
            }
        }
    }

    async fn run_once(&self) -> Result<()> {
        let relay_http_url = self
            .config
            .relay_http_url
            .clone()
            .context("CODEXD_RELAY_HTTP_URL is not configured")?;
        let relay_ws_base_url = self
            .config
            .relay_ws_base_url
            .clone()
            .context("CODEXD_RELAY_WS_BASE_URL is not configured")?;
        let session_id = Uuid::new_v4().to_string();
        let ws_url = format!(
            "{}/v2/ws/{}?role=mac&device_id={}",
            relay_ws_base_url.trim_end_matches('/'),
            session_id,
            self.trust_store.mac_device_id
        );

        info!("connecting codexd relay websocket to {}", ws_url);
        let (mut websocket, _) = connect_async(&ws_url).await?;
        self.session_registry.set_active_sessions(1);
        self.register_presence(&relay_http_url, &session_id).await?;
        info!("relay websocket connected and presence registered");

        while let Some(next) = websocket.next().await {
            match next {
                Ok(message) => {
                    if message.is_close() {
                        break;
                    }
                }
                Err(error) => {
                    warn!("relay websocket receive error: {}", error);
                    break;
                }
            }
        }

        self.session_registry.set_active_sessions(0);
        warn!("relay websocket disconnected");
        Ok(())
    }

    async fn register_presence(&self, relay_http_url: &str, session_id: &str) -> Result<()> {
        let url = format!(
            "{}/v2/presence/register",
            relay_http_url.trim_end_matches('/')
        );
        let body = PresenceRegisterRequest {
            mac_device_id: self.trust_store.mac_device_id.clone(),
            relay_session_id: session_id.to_string(),
            daemon_version: self.config.daemon_version.clone(),
            machine_name: self.trust_store.machine_name.clone(),
            route_candidates: vec![RouteCandidate {
                kind: "relay".to_string(),
                address: format!("session:{session_id}"),
                priority: 100,
            }],
            ttl_seconds: 90,
        };

        self.http_client
            .post(url)
            .json(&body)
            .send()
            .await?
            .error_for_status()?;
        Ok(())
    }
}

#[derive(Serialize)]
struct PresenceRegisterRequest {
    mac_device_id: String,
    relay_session_id: String,
    daemon_version: String,
    machine_name: String,
    route_candidates: Vec<RouteCandidate>,
    ttl_seconds: u64,
}

#[derive(Serialize)]
struct RouteCandidate {
    kind: String,
    address: String,
    priority: u32,
}
