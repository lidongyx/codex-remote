use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use codex_proto::run::run_event::Payload as RunEventPayload;
use codex_proto::run::{AssistantText, ReasoningText, RunCompletion, RunEvent, RunStarted};
use codex_proto::thread::ThreadSummary;
use codex_proto::transport::server_frame::Payload as ServerPayload;
use codex_proto::transport::ServerFrame;
use prost::Message as ProstMessage;
use tokio::sync::{Mutex, mpsc};
use tokio::time::{Duration, sleep};
use tracing::info;
use uuid::Uuid;

#[derive(Clone)]
pub struct RuntimeSupervisor {
    inner: Arc<Mutex<RuntimeState>>,
}

struct RuntimeState {
    codex_process_online: bool,
    global_sequence: u64,
    threads_by_id: HashMap<String, ThreadRecord>,
}

#[derive(Clone)]
struct ThreadRecord {
    summary: ThreadSummary,
    latest_turn_id: Option<String>,
}

impl RuntimeSupervisor {
    pub async fn start() -> Result<Self> {
        info!("runtime supervisor started in placeholder mode");
        Ok(Self {
            inner: Arc::new(Mutex::new(RuntimeState {
                codex_process_online: false,
                global_sequence: 0,
                threads_by_id: HashMap::new(),
            })),
        })
    }

    pub async fn codex_process_online(&self) -> bool {
        self.inner.lock().await.codex_process_online
    }

    pub async fn thread_summaries(&self) -> (u64, Vec<ThreadSummary>) {
        let state = self.inner.lock().await;
        let mut threads = state
            .threads_by_id
            .values()
            .map(|record| record.summary.clone())
            .collect::<Vec<_>>();
        threads.sort_by(|left, right| right.updated_at_ms.cmp(&left.updated_at_ms));
        (state.global_sequence, threads)
    }

    pub async fn start_placeholder_run(
        &self,
        requested_thread_id: &str,
        text: &str,
        outbound_tx: mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>,
    ) -> String {
        let thread_id = if requested_thread_id.trim().is_empty() {
            format!("thread-{}", Uuid::new_v4())
        } else {
            requested_thread_id.trim().to_string()
        };
        let turn_id = format!("turn-{}", Uuid::new_v4());

        {
            let mut state = self.inner.lock().await;
            let updated_at_ms = now_epoch_ms();
            let preview = if text.trim().is_empty() {
                "New run".to_string()
            } else {
                text.trim().chars().take(140).collect()
            };
            let next_thread_number = state.threads_by_id.len() + 1;

            let record = state.threads_by_id.entry(thread_id.clone()).or_insert_with(|| ThreadRecord {
                summary: ThreadSummary {
                    thread_id: thread_id.clone(),
                    title: format!("Remote Thread {}", next_thread_number),
                    preview: preview.clone(),
                    updated_at_ms,
                    running: true,
                },
                latest_turn_id: None,
            });

            record.summary.preview = preview;
            record.summary.updated_at_ms = updated_at_ms;
            record.summary.running = true;
            record.latest_turn_id = Some(turn_id.clone());
        }

        let supervisor = self.clone();
        let spawned_thread_id = thread_id.clone();
        tokio::spawn(async move {
            supervisor
                .emit_placeholder_run(spawned_thread_id, turn_id, outbound_tx)
                .await;
        });

        thread_id
    }

    async fn emit_placeholder_run(
        &self,
        thread_id: String,
        turn_id: String,
        outbound_tx: mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>,
    ) {
        sleep(Duration::from_millis(120)).await;
        let started_sequence = self.next_sequence().await;
        let started = ServerFrame {
            payload: Some(ServerPayload::RunEvent(RunEvent {
                thread_id: thread_id.clone(),
                turn_id: turn_id.clone(),
                global_sequence: started_sequence,
                payload: Some(RunEventPayload::Started(RunStarted {
                    model: "codex-placeholder".to_string(),
                })),
            })),
        };
        let _ = outbound_tx.send(encode_server_frame(started));

        sleep(Duration::from_millis(120)).await;
        let reasoning_sequence = self.next_sequence().await;
        let reasoning = ServerFrame {
            payload: Some(ServerPayload::RunEvent(RunEvent {
                thread_id: thread_id.clone(),
                turn_id: turn_id.clone(),
                global_sequence: reasoning_sequence,
                payload: Some(RunEventPayload::Reasoning(ReasoningText {
                    item_id: format!("reasoning-{}", Uuid::new_v4()),
                    delta: "Planning the next coding step.".to_string(),
                })),
            })),
        };
        let _ = outbound_tx.send(encode_server_frame(reasoning));

        sleep(Duration::from_millis(120)).await;
        let assistant_sequence = self.next_sequence().await;
        let assistant = ServerFrame {
            payload: Some(ServerPayload::RunEvent(RunEvent {
                thread_id: thread_id.clone(),
                turn_id: turn_id.clone(),
                global_sequence: assistant_sequence,
                payload: Some(RunEventPayload::AssistantText(AssistantText {
                    delta: "Placeholder response from codexd V2.".to_string(),
                })),
            })),
        };
        let _ = outbound_tx.send(encode_server_frame(assistant));

        sleep(Duration::from_millis(120)).await;
        let completion_sequence = self.next_sequence().await;
        {
            let mut state = self.inner.lock().await;
            if let Some(record) = state.threads_by_id.get_mut(&thread_id) {
                record.summary.running = false;
                record.summary.updated_at_ms = now_epoch_ms();
                record.summary.preview = "Placeholder response from codexd V2.".to_string();
            }
        }
        let completion = ServerFrame {
            payload: Some(ServerPayload::RunCompletion(RunCompletion {
                thread_id,
                turn_id,
                global_sequence: completion_sequence,
                result: "completed".to_string(),
                error_message: String::new(),
            })),
        };
        let _ = outbound_tx.send(encode_server_frame(completion));
    }

    async fn next_sequence(&self) -> u64 {
        let mut state = self.inner.lock().await;
        state.global_sequence += 1;
        state.global_sequence
    }
}

fn encode_server_frame(frame: ServerFrame) -> tokio_tungstenite::tungstenite::Message {
    let mut encoded = Vec::new();
    frame.encode(&mut encoded).expect("encode server frame");
    tokio_tungstenite::tungstenite::Message::Binary(encoded)
}

fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
