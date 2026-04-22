use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::extract::ws::Message;
use dashmap::DashMap;
use tokio::sync::mpsc;

use crate::types::{MacPresence, PresenceRegisterRequest};

#[derive(Clone)]
pub struct AppState {
    pub presence_by_mac: Arc<DashMap<String, MacPresence>>,
    pub sessions: Arc<DashMap<String, RelayRoom>>,
}

impl AppState {
    pub fn new() -> Self {
        Self {
            presence_by_mac: Arc::new(DashMap::new()),
            sessions: Arc::new(DashMap::new()),
        }
    }

    pub fn register_presence(&self, request: PresenceRegisterRequest) -> MacPresence {
        let expires_at_epoch_ms = now_epoch_ms() + Duration::from_secs(request.ttl_seconds).as_millis() as u64;
        let presence = MacPresence {
            mac_device_id: request.mac_device_id.clone(),
            relay_session_id: request.relay_session_id,
            daemon_version: request.daemon_version,
            machine_name: request.machine_name,
            route_candidates: request.route_candidates,
            expires_at_epoch_ms,
        };

        self.presence_by_mac
            .insert(request.mac_device_id, presence.clone());
        presence
    }

    pub fn resolve_presence(&self, mac_device_id: &str) -> Option<MacPresence> {
        let presence = self.presence_by_mac.get(mac_device_id)?;
        if presence.expires_at_epoch_ms <= now_epoch_ms() {
            drop(presence);
            self.presence_by_mac.remove(mac_device_id);
            return None;
        }
        let session_id = presence.relay_session_id.clone();
        drop(presence);

        let room = self.sessions.get(&session_id)?;
        if room.mac.is_none() {
            drop(room);
            self.presence_by_mac.remove(mac_device_id);
            return None;
        }

        let presence = self.presence_by_mac.get(mac_device_id)?;
        Some(presence.clone())
    }

    pub fn remove_presence_for_session(&self, mac_device_id: &str, relay_session_id: &str) {
        if let Some(existing) = self.presence_by_mac.get(mac_device_id) {
            if existing.relay_session_id == relay_session_id {
                drop(existing);
                self.presence_by_mac.remove(mac_device_id);
            }
        }
    }
}

pub type PeerTx = mpsc::UnboundedSender<Message>;

#[derive(Clone)]
pub struct RelayRoom {
    pub mac_device_id: Option<String>,
    pub mac: Option<PeerTx>,
    pub phones: HashMap<String, PeerTx>,
}

impl RelayRoom {
    pub fn empty() -> Self {
        Self {
            mac_device_id: None,
            mac: None,
            phones: HashMap::new(),
        }
    }
}

pub fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
