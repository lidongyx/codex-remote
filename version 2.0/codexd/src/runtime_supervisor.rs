use anyhow::Result;
use tracing::info;

#[derive(Clone)]
pub struct RuntimeSupervisor {
    codex_process_online: bool,
}

impl RuntimeSupervisor {
    pub async fn start() -> Result<Self> {
        info!("runtime supervisor started in placeholder mode");
        Ok(Self {
            codex_process_online: false,
        })
    }

    pub fn codex_process_online(&self) -> bool {
        self.codex_process_online
    }
}
