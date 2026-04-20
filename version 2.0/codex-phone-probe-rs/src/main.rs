use anyhow::{Context, Result};
use codex_proto::session::SessionResumeRequest;
use codex_proto::thread::ThreadListRequest;
use codex_proto::transport::client_frame::Payload as ClientPayload;
use codex_proto::transport::server_frame::Payload as ServerPayload;
use codex_proto::transport::{ClientFrame, ServerFrame};
use futures_util::{SinkExt, StreamExt};
use prost::Message;
use reqwest::Client;
use serde::Deserialize;
use tokio_tungstenite::connect_async;
use tracing_subscriber::EnvFilter;
use uuid::Uuid;

#[derive(Debug, Deserialize)]
struct SessionResolveResponse {
    ok: bool,
    relay_session_id: String,
}

#[derive(Debug, Deserialize)]
struct DaemonHealth {
    #[serde(rename = "macDeviceId")]
    mac_device_id: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .init();

    let relay_http_url = std::env::var("RELAY_HTTP_URL").unwrap_or_else(|_| "http://127.0.0.1:9910".to_string());
    let relay_ws_base_url = std::env::var("RELAY_WS_BASE_URL").unwrap_or_else(|_| "ws://127.0.0.1:9910".to_string());
    let daemon_health_url =
        std::env::var("DAEMON_HEALTH_URL").unwrap_or_else(|_| "http://127.0.0.1:9911/health".to_string());
    let mac_device_id = match std::env::args().nth(1) {
        Some(value) => value,
        None => {
            let health: DaemonHealth = Client::new()
                .get(&daemon_health_url)
                .send()
                .await?
                .error_for_status()?
                .json()
                .await?;
            health.mac_device_id
        }
    };

    let resolved: SessionResolveResponse = Client::new()
        .post(format!("{}/v2/session/resolve", relay_http_url.trim_end_matches('/')))
        .json(&serde_json::json!({
            "mac_device_id": mac_device_id,
            "phone_device_id": "phone-probe",
        }))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    if !resolved.ok {
        anyhow::bail!("relay returned a non-ok resolve response");
    }

    let phone_device_id = format!("phone-probe-{}", Uuid::new_v4());
    let ws_url = format!(
        "{}/v2/ws/{}?role=phone&device_id={}",
        relay_ws_base_url.trim_end_matches('/'),
        resolved.relay_session_id,
        phone_device_id
    );
    let (mut websocket, _) = connect_async(&ws_url).await?;

    let resume_frame = ClientFrame {
        payload: Some(ClientPayload::SessionResume(SessionResumeRequest {
            mac_device_id: mac_device_id.clone(),
            phone_device_id: phone_device_id.clone(),
            global_sequence: 0,
            thread_cursors: Vec::new(),
        })),
    };
    let mut encoded = Vec::new();
    resume_frame.encode(&mut encoded)?;
    websocket
        .send(tokio_tungstenite::tungstenite::Message::Binary(encoded))
        .await?;

    let thread_list_frame = ClientFrame {
        payload: Some(ClientPayload::ThreadListRequest(ThreadListRequest {
            since_global_sequence: 0,
        })),
    };
    let mut encoded = Vec::new();
    thread_list_frame.encode(&mut encoded)?;
    websocket
        .send(tokio_tungstenite::tungstenite::Message::Binary(encoded))
        .await?;

    let mut saw_session_ready = false;
    let mut saw_thread_list = false;

    while let Some(next) = websocket.next().await {
        let message = next?;
        match message {
            tokio_tungstenite::tungstenite::Message::Binary(bytes) => {
                let frame = ServerFrame::decode(bytes.as_ref()).context("decode server frame")?;
                match frame.payload {
                    Some(ServerPayload::SessionReady(ready)) => {
                        println!(
                            "{}",
                            serde_json::json!({
                                "type": "session_ready",
                                "sessionId": ready.session_id,
                                "connectionMode": ready.connection_mode,
                                "globalSequence": ready.global_sequence,
                            })
                        );
                        saw_session_ready = true;
                    }
                    Some(ServerPayload::ThreadListSnapshot(snapshot)) => {
                        println!(
                            "{}",
                            serde_json::json!({
                                "type": "thread_list_snapshot",
                                "globalSequence": snapshot.global_sequence,
                                "threadCount": snapshot.threads.len(),
                            })
                        );
                        saw_thread_list = true;
                    }
                    Some(other) => {
                        println!("{}", serde_json::json!({ "type": "unexpected", "payload": format!("{:?}", other) }));
                    }
                    None => {}
                }
            }
            tokio_tungstenite::tungstenite::Message::Text(text) => {
                println!("{}", serde_json::json!({ "type": "text", "payload": text.to_string() }));
            }
            tokio_tungstenite::tungstenite::Message::Close(_) => break,
            _ => {}
        }

        if saw_session_ready && saw_thread_list {
            break;
        }
    }

    anyhow::ensure!(saw_session_ready, "did not receive SessionReady");
    anyhow::ensure!(saw_thread_list, "did not receive ThreadListSnapshot");
    Ok(())
}
