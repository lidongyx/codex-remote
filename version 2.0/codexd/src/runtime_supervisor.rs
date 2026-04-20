use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use codex_proto::run::run_event::Payload as RunEventPayload;
use codex_proto::run::{AssistantText, ReasoningText, RunCompletion, RunEvent, RunStarted};
use codex_proto::thread::thread_event::Payload as ThreadEventPayload;
use codex_proto::thread::{
    AssistantDelta, ReasoningDelta as ThreadReasoningDelta, StatusChanged, ThreadCatchUpBatch,
    ThreadEvent, ThreadSummary, UserMessage,
};
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
    latest_thread_sequence: u64,
    events: Vec<ThreadEvent>,
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

    pub async fn thread_catch_up(
        &self,
        thread_id: &str,
        since_thread_sequence: u64,
    ) -> ThreadCatchUpBatch {
        let state = self.inner.lock().await;
        if let Some(record) = state.threads_by_id.get(thread_id) {
            let events = record
                .events
                .iter()
                .filter(|event| event.sequence > since_thread_sequence)
                .cloned()
                .collect::<Vec<_>>();
            ThreadCatchUpBatch {
                thread_id: thread_id.to_string(),
                latest_thread_sequence: record.latest_thread_sequence,
                events,
                has_more: false,
            }
        } else {
            ThreadCatchUpBatch {
                thread_id: thread_id.to_string(),
                latest_thread_sequence: 0,
                events: Vec::new(),
                has_more: false,
            }
        }
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
        let preview = if text.trim().is_empty() {
            "New run".to_string()
        } else {
            text.trim().chars().take(140).collect()
        };

        {
            let mut state = self.inner.lock().await;
            let updated_at_ms = now_epoch_ms();
            let next_thread_number = state.threads_by_id.len() + 1;

            let record = state
                .threads_by_id
                .entry(thread_id.clone())
                .or_insert_with(|| ThreadRecord {
                    summary: ThreadSummary {
                        thread_id: thread_id.clone(),
                        title: format!("Remote Thread {}", next_thread_number),
                        preview: preview.clone(),
                        updated_at_ms,
                        running: true,
                    },
                    latest_turn_id: None,
                    latest_thread_sequence: 0,
                    events: Vec::new(),
                });

            record.summary.preview = preview.clone();
            record.summary.updated_at_ms = updated_at_ms;
            record.summary.running = true;
            record.latest_turn_id = Some(turn_id.clone());
        }

        if !text.trim().is_empty() {
            self.append_thread_event(
                &thread_id,
                ThreadEventPayload::UserMessage(UserMessage {
                    turn_id: turn_id.clone(),
                    text: text.to_string(),
                }),
            )
            .await;
        }

        self.append_thread_event(
            &thread_id,
            ThreadEventPayload::StatusChanged(StatusChanged {
                turn_id: turn_id.clone(),
                status: "running".to_string(),
            }),
        )
        .await;

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
        let started_sequence = self.next_global_sequence().await;
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
        let reasoning_delta = "Planning the next coding step.".to_string();
        let reasoning_item_id = format!("reasoning-{}", Uuid::new_v4());
        let reasoning_sequence = self.next_global_sequence().await;
        let reasoning = ServerFrame {
            payload: Some(ServerPayload::RunEvent(RunEvent {
                thread_id: thread_id.clone(),
                turn_id: turn_id.clone(),
                global_sequence: reasoning_sequence,
                payload: Some(RunEventPayload::Reasoning(ReasoningText {
                    item_id: reasoning_item_id.clone(),
                    delta: reasoning_delta.clone(),
                })),
            })),
        };
        let _ = outbound_tx.send(encode_server_frame(reasoning));
        self.append_thread_event(
            &thread_id,
            ThreadEventPayload::ReasoningDelta(ThreadReasoningDelta {
                turn_id: turn_id.clone(),
                item_id: reasoning_item_id,
                delta: reasoning_delta,
            }),
        )
        .await;

        sleep(Duration::from_millis(120)).await;
        let assistant_delta = "Placeholder response from codexd V2.".to_string();
        let assistant_sequence = self.next_global_sequence().await;
        let assistant = ServerFrame {
            payload: Some(ServerPayload::RunEvent(RunEvent {
                thread_id: thread_id.clone(),
                turn_id: turn_id.clone(),
                global_sequence: assistant_sequence,
                payload: Some(RunEventPayload::AssistantText(AssistantText {
                    delta: assistant_delta.clone(),
                })),
            })),
        };
        let _ = outbound_tx.send(encode_server_frame(assistant));
        self.append_thread_event(
            &thread_id,
            ThreadEventPayload::AssistantDelta(AssistantDelta {
                turn_id: turn_id.clone(),
                delta: assistant_delta.clone(),
            }),
        )
        .await;

        sleep(Duration::from_millis(120)).await;
        let completion_sequence = self.next_global_sequence().await;
        {
            let mut state = self.inner.lock().await;
            if let Some(record) = state.threads_by_id.get_mut(&thread_id) {
                record.summary.running = false;
                record.summary.updated_at_ms = now_epoch_ms();
                record.summary.preview = assistant_delta;
            }
        }
        self.append_thread_event(
            &thread_id,
            ThreadEventPayload::StatusChanged(StatusChanged {
                turn_id: turn_id.clone(),
                status: "completed".to_string(),
            }),
        )
        .await;
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

    async fn append_thread_event(&self, thread_id: &str, payload: ThreadEventPayload) -> u64 {
        let mut state = self.inner.lock().await;
        if let Some(record) = state.threads_by_id.get_mut(thread_id) {
            record.latest_thread_sequence += 1;
            let sequence = record.latest_thread_sequence;
            record.events.push(ThreadEvent {
                sequence,
                payload: Some(payload),
            });
            sequence
        } else {
            0
        }
    }

    async fn next_global_sequence(&self) -> u64 {
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
