use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TrustedPhone {
    pub phone_device_id: String,
    pub phone_public_key: String,
    pub last_seen_at_epoch_ms: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TrustStore {
    pub mac_device_id: String,
    pub machine_name: String,
    pub mac_public_key: String,
    pub trusted_phones: Vec<TrustedPhone>,
}

impl TrustStore {
    pub fn load_or_create(state_dir: &Path, machine_name: &str) -> Result<Self> {
        fs::create_dir_all(state_dir)
            .with_context(|| format!("failed to create state dir {}", state_dir.display()))?;
        let path = store_path(state_dir);

        if path.exists() {
            let raw = fs::read_to_string(&path)
                .with_context(|| format!("failed to read trust store {}", path.display()))?;
            let store = serde_json::from_str(&raw)
                .with_context(|| format!("failed to decode trust store {}", path.display()))?;
            return Ok(store);
        }

        let store = Self {
            mac_device_id: Uuid::new_v4().to_string(),
            machine_name: machine_name.to_string(),
            mac_public_key: format!("placeholder-mac-pub-{}", Uuid::new_v4()),
            trusted_phones: Vec::new(),
        };
        store.save(state_dir)?;
        Ok(store)
    }

    pub fn save(&self, state_dir: &Path) -> Result<()> {
        fs::create_dir_all(state_dir)
            .with_context(|| format!("failed to create state dir {}", state_dir.display()))?;
        let path = store_path(state_dir);
        let raw = serde_json::to_string_pretty(self)?;
        fs::write(&path, raw).with_context(|| format!("failed to write trust store {}", path.display()))?;
        Ok(())
    }

    pub fn path(state_dir: &Path) -> PathBuf {
        store_path(state_dir)
    }
}

fn store_path(state_dir: &Path) -> PathBuf {
    state_dir.join("trust-store.json")
}
