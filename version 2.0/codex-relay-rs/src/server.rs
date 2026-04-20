use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Result;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use futures_util::{sink::SinkExt, stream::StreamExt};
use tokio::sync::mpsc;
use tracing::{info, warn};
use uuid::Uuid;

use crate::config::AppConfig;
use crate::state::{AppState, RelayRoom};
use crate::types::{
    PresenceRegisterRequest, PresenceRegisterResponse, SessionResolveRequest, SessionResolveResponse,
};

pub async fn run(config: AppConfig) -> Result<()> {
    let state = Arc::new(AppState::new());
    let app = router(state);

    let listener = tokio::net::TcpListener::bind(config.bind_addr).await?;
    info!("codex-relay-rs listening on {}", config.bind_addr);
    axum::serve(listener, app).await?;
    Ok(())
}

fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/v2/presence/register", post(register_presence))
        .route("/v2/session/resolve", post(resolve_session))
        .route("/v2/ws/:session_id", get(ws_upgrade))
        .with_state(state)
}

async fn health() -> impl IntoResponse {
    Json(serde_json::json!({
        "ok": true,
        "service": "codex-relay-rs",
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

async fn register_presence(
    State(state): State<Arc<AppState>>,
    Json(request): Json<PresenceRegisterRequest>,
) -> impl IntoResponse {
    let presence = state.register_presence(request);
    (
        StatusCode::OK,
        Json(PresenceRegisterResponse {
            ok: true,
            expires_at_epoch_ms: presence.expires_at_epoch_ms,
        }),
    )
}

async fn resolve_session(
    State(state): State<Arc<AppState>>,
    Json(request): Json<SessionResolveRequest>,
) -> impl IntoResponse {
    let _phone_device_id = request.phone_device_id;

    match state.resolve_presence(&request.mac_device_id) {
        Some(presence) => (
            StatusCode::OK,
            Json(SessionResolveResponse {
                ok: true,
                relay_session_id: presence.relay_session_id,
                machine_name: presence.machine_name,
                daemon_version: presence.daemon_version,
                route_candidates: presence.route_candidates,
            }),
        )
            .into_response(),
        None => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({
                "ok": false,
                "error": "No live presence for requested Mac.",
                "code": "presence_unavailable",
            })),
        )
            .into_response(),
    }
}

async fn ws_upgrade(
    State(state): State<Arc<AppState>>,
    Path(session_id): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    upgrade: WebSocketUpgrade,
) -> impl IntoResponse {
    let role = params.get("role").cloned().unwrap_or_default();
    let device_id = params
        .get("device_id")
        .cloned()
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    if role != "mac" && role != "phone" {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({
                "ok": false,
                "error": "role must be mac or phone",
            })),
        )
            .into_response();
    }

    upgrade
        .on_upgrade(move |socket| handle_socket(state, socket, session_id, role, device_id))
        .into_response()
}

async fn handle_socket(
    state: Arc<AppState>,
    socket: WebSocket,
    session_id: String,
    role: String,
    device_id: String,
) {
    let (mut sender, mut receiver) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    {
        let mut room = state
            .sessions
            .entry(session_id.clone())
            .or_insert_with(RelayRoom::empty);
        if role == "mac" {
            room.mac_device_id = Some(device_id.clone());
            room.mac = Some(tx.clone());
        } else {
            room.phones.insert(device_id.clone(), tx.clone());
        }
    }

    info!("peer connected role={} session={} device={}", role, session_id, device_id);

    let write_task = tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            if sender.send(message).await.is_err() {
                break;
            }
        }
    });

    while let Some(next) = receiver.next().await {
        match next {
            Ok(Message::Binary(bytes)) => forward_binary(&state, &session_id, &role, &device_id, bytes.to_vec()),
            Ok(Message::Text(text)) => forward_text(&state, &session_id, &role, &device_id, text.to_string()),
            Ok(Message::Close(_)) => break,
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) => {}
            Err(error) => {
                warn!(
                    "peer receive error role={} session={} device={} error={}",
                    role, session_id, device_id, error
                );
                break;
            }
        }
    }

    write_task.abort();
    unregister_peer(&state, &session_id, &role, &device_id);
    info!("peer disconnected role={} session={} device={}", role, session_id, device_id);
}

fn forward_binary(
    state: &Arc<AppState>,
    session_id: &str,
    role: &str,
    device_id: &str,
    bytes: Vec<u8>,
) {
    if let Some(room) = state.sessions.get(session_id) {
        if role == "mac" {
            for (phone_id, phone_tx) in &room.phones {
                if phone_id != device_id {
                    let _ = phone_tx.send(Message::Binary(bytes.clone()));
                } else {
                    let _ = phone_tx.send(Message::Binary(bytes.clone()));
                }
            }
        } else if let Some(mac_tx) = &room.mac {
            let _ = mac_tx.send(Message::Binary(bytes));
        }
    }
}

fn forward_text(
    state: &Arc<AppState>,
    session_id: &str,
    role: &str,
    _device_id: &str,
    text: String,
) {
    if let Some(room) = state.sessions.get(session_id) {
        if role == "mac" {
            for phone_tx in room.phones.values() {
                let _ = phone_tx.send(Message::Text(text.clone().into()));
            }
        } else if let Some(mac_tx) = &room.mac {
            let _ = mac_tx.send(Message::Text(text.into()));
        }
    }
}

fn unregister_peer(state: &Arc<AppState>, session_id: &str, role: &str, device_id: &str) {
    let should_remove_room = if let Some(mut room) = state.sessions.get_mut(session_id) {
        if role == "mac" {
            if let Some(mac_device_id) = room.mac_device_id.clone() {
                state.remove_presence_for_session(&mac_device_id, session_id);
            }
            room.mac_device_id = None;
            room.mac = None;
        } else {
            room.phones.remove(device_id);
        }
        room.mac.is_none() && room.phones.is_empty()
    } else {
        false
    };

    if should_remove_room {
        state.sessions.remove(session_id);
    }
}
