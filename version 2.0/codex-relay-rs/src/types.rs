use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RouteCandidate {
    pub kind: String,
    pub address: String,
    pub priority: u32,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PresenceRegisterRequest {
    pub mac_device_id: String,
    pub relay_session_id: String,
    pub daemon_version: String,
    pub machine_name: String,
    #[serde(default)]
    pub route_candidates: Vec<RouteCandidate>,
    #[serde(default = "default_ttl_seconds")]
    pub ttl_seconds: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PresenceRegisterResponse {
    pub ok: bool,
    pub expires_at_epoch_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SessionResolveRequest {
    pub mac_device_id: String,
    pub phone_device_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SessionResolveResponse {
    pub ok: bool,
    pub relay_session_id: String,
    pub machine_name: String,
    pub daemon_version: String,
    pub route_candidates: Vec<RouteCandidate>,
}

#[derive(Clone, Debug)]
pub struct MacPresence {
    pub mac_device_id: String,
    pub relay_session_id: String,
    pub daemon_version: String,
    pub machine_name: String,
    pub route_candidates: Vec<RouteCandidate>,
    pub expires_at_epoch_ms: u64,
}

pub fn default_ttl_seconds() -> u64 {
    90
}
