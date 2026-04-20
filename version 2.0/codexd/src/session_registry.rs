use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Clone, Default)]
pub struct SessionRegistry {
    active_sessions: Arc<AtomicU64>,
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
}
