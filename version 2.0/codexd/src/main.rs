use anyhow::Result;
use tracing_subscriber::EnvFilter;

use codexd::config::AppConfig;
use codexd::health::{run_server, HealthState};
use codexd::relay_client::RelayClient;
use codexd::runtime_supervisor::{RuntimeConfig, RuntimeSupervisor};
use codexd::session_registry::SessionRegistry;
use codexd::trust_store::TrustStore;

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    tracing_subscriber::fmt().with_env_filter(filter).init();
}

#[tokio::main]
async fn main() -> Result<()> {
    init_tracing();

    let config = AppConfig::from_env()?;
    let trust_store = TrustStore::load_or_create(&config.state_dir, &config.machine_name)?;
    let runtime_supervisor = RuntimeSupervisor::start(RuntimeConfig {
        codex_command: config.codex_command.clone(),
        workspace_root: config.codex_workspace_root.clone(),
        model: config.codex_model.clone(),
    })
    .await?;
    let session_registry = SessionRegistry::new();

    if config.relay_http_url.is_some() && config.relay_ws_base_url.is_some() {
        let relay_client = RelayClient::new(
            config.clone(),
            trust_store.clone(),
            session_registry.clone(),
            runtime_supervisor.clone(),
        );
        tokio::spawn(async move {
            relay_client.run_forever().await;
        });
    }

    let health_state = HealthState {
        config,
        trust_store,
        runtime_supervisor,
        session_registry,
    };

    run_server(health_state).await
}
