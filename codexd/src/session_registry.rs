use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

#[derive(Clone, Default)]
pub struct SessionRegistry {
    active_sessions: Arc<AtomicU64>,
    relay_connected: Arc<AtomicBool>,
    last_presence_refresh_epoch_ms: Arc<AtomicU64>,
}

impl SessionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn active_sessions(&self) -> u64 {
        self.active_sessions.load(Ordering::Relaxed)
    }

    pub fn set_active_sessions(&self, count: u64) {
        self.active_sessions.store(count, Ordering::Relaxed);
    }

    pub fn relay_connected(&self) -> bool {
        self.relay_connected.load(Ordering::Relaxed)
    }

    pub fn set_relay_connected(&self, connected: bool) {
        self.relay_connected.store(connected, Ordering::Relaxed);
    }

    pub fn last_presence_refresh_epoch_ms(&self) -> u64 {
        self.last_presence_refresh_epoch_ms.load(Ordering::Relaxed)
    }

    pub fn set_last_presence_refresh_epoch_ms(&self, timestamp: u64) {
        self.last_presence_refresh_epoch_ms
            .store(timestamp, Ordering::Relaxed);
    }
}
