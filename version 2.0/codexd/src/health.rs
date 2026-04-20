use std::sync::Arc;

use anyhow::Result;
use axum::routing::get;
use axum::{Json, Router};
use serde_json::json;
use tracing::info;

use crate::config::AppConfig;
use crate::runtime_supervisor::RuntimeSupervisor;
use crate::session_registry::SessionRegistry;
use crate::trust_store::TrustStore;

#[derive(Clone)]
pub struct HealthState {
    pub config: AppConfig,
    pub trust_store: TrustStore,
    pub runtime_supervisor: RuntimeSupervisor,
    pub session_registry: SessionRegistry,
}

pub async fn run_server(state: HealthState) -> Result<()> {
    let bind_addr = state.config.health_bind_addr;
    let shared_state = Arc::new(state);
    let app = Router::new().route(
        "/health",
        get({
            let shared_state = Arc::clone(&shared_state);
            move || {
                let shared_state = Arc::clone(&shared_state);
                async move {
                    Json(json!({
                        "ok": true,
                        "service": "codexd",
                        "version": shared_state.config.daemon_version,
                        "machineName": shared_state.trust_store.machine_name,
                        "macDeviceId": shared_state.trust_store.mac_device_id,
                        "trustedPhoneCount": shared_state.trust_store.trusted_phones.len(),
                        "relayConfigured": shared_state.config.relay_ws_base_url.is_some() && shared_state.config.relay_http_url.is_some(),
                        "relayConnected": shared_state.session_registry.relay_connected(),
                        "lastPresenceRefreshEpochMs": shared_state.session_registry.last_presence_refresh_epoch_ms(),
                        "codexProcessOnline": shared_state.runtime_supervisor.codex_process_online().await,
                        "activeSessions": shared_state.session_registry.active_sessions(),
                    }))
                }
            }
        }),
    );

    let listener = tokio::net::TcpListener::bind(bind_addr).await?;
    info!("codexd health server listening on {}", bind_addr);
    axum::serve(listener, app).await?;
    Ok(())
}
