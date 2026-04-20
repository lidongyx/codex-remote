use std::time::Duration;

use anyhow::{Context, Result};
use codex_proto::session::SessionReady;
use codex_proto::thread::ThreadListSnapshot;
use codex_proto::run::RunStartRequest;
use codex_proto::transport::client_frame::Payload as ClientPayload;
use codex_proto::transport::server_frame::Payload as ServerPayload;
use codex_proto::transport::{ClientFrame, ServerFrame};
use futures_util::{SinkExt, StreamExt};
use prost::Message as ProstMessage;
use reqwest::Client;
use serde::Serialize;
use tokio::sync::mpsc;
use tokio::time::{interval, sleep};
use tokio_tungstenite::connect_async;
use tracing::{info, warn};
use uuid::Uuid;

use crate::config::AppConfig;
use crate::runtime_supervisor::RuntimeSupervisor;
use crate::session_registry::SessionRegistry;
use crate::trust_store::TrustStore;

#[derive(Clone)]
pub struct RelayClient {
    http_client: Client,
    config: AppConfig,
    trust_store: TrustStore,
    session_registry: SessionRegistry,
    runtime_supervisor: RuntimeSupervisor,
}

impl RelayClient {
    pub fn new(
        config: AppConfig,
        trust_store: TrustStore,
        session_registry: SessionRegistry,
        runtime_supervisor: RuntimeSupervisor,
    ) -> Self {
        Self {
            http_client: Client::new(),
            config,
            trust_store,
            session_registry,
            runtime_supervisor,
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
        let (websocket, _) = connect_async(&ws_url).await?;
        let (mut write, mut read) = websocket.split();
        let (outbound_tx, mut outbound_rx) = mpsc::unbounded_channel::<tokio_tungstenite::tungstenite::Message>();
        let ping_outbound_tx = outbound_tx.clone();
        self.session_registry.set_active_sessions(1);
        self.session_registry.set_relay_connected(true);
        self.register_presence(&relay_http_url, &session_id).await?;
        info!("relay websocket connected and presence registered");

        let writer_task = tokio::spawn(async move {
            while let Some(message) = outbound_rx.recv().await {
                if write.send(message).await.is_err() {
                    break;
                }
            }
        });

        let presence_refresh_client = self.http_client.clone();
        let presence_refresh_registry = self.session_registry.clone();
        let refresh_body = PresenceRegisterRequest {
            mac_device_id: self.trust_store.mac_device_id.clone(),
            relay_session_id: session_id.clone(),
            daemon_version: self.config.daemon_version.clone(),
            machine_name: self.trust_store.machine_name.clone(),
            route_candidates: vec![RouteCandidate {
                kind: "relay".to_string(),
                address: format!("session:{session_id}"),
                priority: 100,
            }],
            ttl_seconds: 90,
        };
        let refresh_url = format!(
            "{}/v2/presence/register",
            relay_http_url.trim_end_matches('/')
        );

        let refresh_task = tokio::spawn(async move {
            let mut ticker = interval(Duration::from_secs(30));
            loop {
                ticker.tick().await;
                let result = presence_refresh_client
                    .post(&refresh_url)
                    .json(&refresh_body)
                    .send()
                    .await
                    .and_then(|response| response.error_for_status());
                match result {
                    Ok(_) => {
                        presence_refresh_registry
                            .set_last_presence_refresh_epoch_ms(now_epoch_ms());
                    }
                    Err(error) => {
                        warn!("presence refresh failed: {}", error);
                    }
                }
            }
        });

        let ping_task = tokio::spawn(async move {
            let mut ticker = interval(Duration::from_secs(20));
            loop {
                ticker.tick().await;
                if ping_outbound_tx
                    .send(tokio_tungstenite::tungstenite::Message::Ping(Vec::new()))
                    .is_err()
                {
                    break;
                }
            }
        });

        while let Some(next) = read.next().await {
            match next {
                Ok(message) => {
                    if message.is_close() {
                        break;
                    }
                    if self
                        .handle_incoming_message(&session_id, message, outbound_tx.clone())
                        .await
                        .is_err()
                    {
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
        self.session_registry.set_relay_connected(false);
        refresh_task.abort();
        ping_task.abort();
        writer_task.abort();
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
        self.session_registry
            .set_last_presence_refresh_epoch_ms(now_epoch_ms());
        Ok(())
    }

    // Temporary mixed-mode surface while the binary protocol is being wired end to end.
    async fn handle_incoming_message(
        &self,
        session_id: &str,
        message: tokio_tungstenite::tungstenite::Message,
        outbound_tx: mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>,
    ) -> Result<()> {
        match message {
            tokio_tungstenite::tungstenite::Message::Binary(bytes) => {
                self.handle_incoming_binary_frame(session_id, &bytes, outbound_tx)
                    .await?;
                Ok(())
            }
            tokio_tungstenite::tungstenite::Message::Text(text) => {
                let trimmed = text.trim();
                if trimmed.eq_ignore_ascii_case("ping") {
                    outbound_tx
                        .send(tokio_tungstenite::tungstenite::Message::Text("pong".into()))
                        .ok();
                    return Ok(());
                }

                if trimmed.eq_ignore_ascii_case("session_info") {
                    let response = serde_json::json!({
                        "type": "session_info",
                        "sessionId": session_id,
                        "macDeviceId": self.trust_store.mac_device_id,
                        "machineName": self.trust_store.machine_name,
                        "daemonVersion": self.config.daemon_version,
                        "relayConnected": self.session_registry.relay_connected(),
                    });
                    outbound_tx
                        .send(tokio_tungstenite::tungstenite::Message::Text(
                            response.to_string().into(),
                        ))
                        .ok();
                    return Ok(());
                }

                Ok(())
            }
            _ => Ok(()),
        }
    }

    async fn handle_incoming_binary_frame(
        &self,
        session_id: &str,
        bytes: &[u8],
        outbound_tx: mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>,
    ) -> Result<()> {
        let frame = ClientFrame::decode(bytes)?;
        match frame.payload.context("missing client payload")? {
            ClientPayload::SessionResume(request) => {
                let response = ServerFrame {
                    payload: Some(ServerPayload::SessionReady(SessionReady {
                        session_id: session_id.to_string(),
                        connection_mode: "relay".to_string(),
                        global_sequence: request.global_sequence,
                    })),
                };
                let mut encoded = Vec::new();
                response.encode(&mut encoded)?;
                outbound_tx
                    .send(tokio_tungstenite::tungstenite::Message::Binary(encoded))
                    .ok();
                Ok(())
            }
            ClientPayload::ThreadListRequest(_request) => {
                let (global_sequence, threads) = self.runtime_supervisor.thread_summaries().await;
                let response = ServerFrame {
                    payload: Some(ServerPayload::ThreadListSnapshot(
                        ThreadListSnapshot {
                            global_sequence,
                            threads,
                        },
                    )),
                };
                let mut encoded = Vec::new();
                response.encode(&mut encoded)?;
                outbound_tx
                    .send(tokio_tungstenite::tungstenite::Message::Binary(encoded))
                    .ok();
                Ok(())
            }
            ClientPayload::RunStartRequest(RunStartRequest { thread_id, text, .. }) => {
                self.runtime_supervisor
                    .start_placeholder_run(&thread_id, &text, outbound_tx.clone())
                    .await;
                let (global_sequence, threads) = self.runtime_supervisor.thread_summaries().await;
                let response = ServerFrame {
                    payload: Some(ServerPayload::ThreadListSnapshot(
                        ThreadListSnapshot {
                            global_sequence,
                            threads,
                        },
                    )),
                };
                let mut encoded = Vec::new();
                response.encode(&mut encoded)?;
                let _ = outbound_tx.send(tokio_tungstenite::tungstenite::Message::Binary(encoded));
                Ok(())
            }
            _ => Ok(()),
        }
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

fn now_epoch_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};

    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
