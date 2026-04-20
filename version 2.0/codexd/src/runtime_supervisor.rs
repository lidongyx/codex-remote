use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Result};
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
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncRead, BufReader};
use tokio::process::Command;
use tokio::sync::{mpsc, Mutex};
use tokio::task::AbortHandle;
use tracing::{info, warn};
use uuid::Uuid;

#[derive(Clone, Debug)]
pub struct RuntimeConfig {
    pub codex_command: String,
    pub workspace_root: PathBuf,
    pub model: Option<String>,
}

#[derive(Clone)]
pub struct RuntimeSupervisor {
    inner: Arc<Mutex<RuntimeState>>,
    config: Arc<RuntimeConfig>,
}

struct RuntimeState {
    codex_process_online: bool,
    global_sequence: u64,
    threads_by_id: HashMap<String, ThreadRecord>,
    active_runs_by_thread: HashMap<String, ActiveRun>,
}

struct ActiveRun {
    turn_id: String,
    abort_handle: AbortHandle,
}

#[derive(Clone)]
struct ThreadRecord {
    summary: ThreadSummary,
    latest_turn_id: Option<String>,
    latest_thread_sequence: u64,
    events: Vec<ThreadEvent>,
}

#[derive(Default)]
struct CodexExecOutputSummary {
    last_reasoning_preview: Option<String>,
    last_assistant_preview: Option<String>,
}

impl RuntimeSupervisor {
    pub async fn start(config: RuntimeConfig) -> Result<Self> {
        info!(
            "runtime supervisor started with codex exec runtime command={} workspace_root={}",
            config.codex_command,
            config.workspace_root.display()
        );

        Ok(Self {
            inner: Arc::new(Mutex::new(RuntimeState {
                codex_process_online: false,
                global_sequence: 0,
                threads_by_id: HashMap::new(),
                active_runs_by_thread: HashMap::new(),
            })),
            config: Arc::new(config),
        })
    }

    pub fn runtime_mode(&self) -> &'static str {
        "codex-exec"
    }

    pub fn workspace_root(&self) -> &PathBuf {
        &self.config.workspace_root
    }

    pub fn configured_model(&self) -> Option<&str> {
        self.config.model.as_deref()
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

    pub async fn start_run(
        &self,
        requested_thread_id: &str,
        text: &str,
        outbound_tx: mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>,
    ) -> Result<String> {
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
            if let Some(active_run) = state.active_runs_by_thread.get(&thread_id) {
                return Err(anyhow!(
                    "thread {} is already running turn {}",
                    thread_id,
                    active_run.turn_id
                ));
            }

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
        let spawned_turn_id = turn_id.clone();
        let prompt = text.to_string();
        let handle = tokio::spawn(async move {
            supervisor
                .emit_codex_exec_run(spawned_thread_id, spawned_turn_id, prompt, outbound_tx)
                .await;
        });

        {
            let mut state = self.inner.lock().await;
            state.active_runs_by_thread.insert(
                thread_id.clone(),
                ActiveRun {
                    turn_id,
                    abort_handle: handle.abort_handle(),
                },
            );
            state.codex_process_online = true;
        }

        Ok(thread_id)
    }

    pub async fn interrupt_run(
        &self,
        thread_id: &str,
        requested_turn_id: &str,
        outbound_tx: mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>,
    ) -> bool {
        let aborted_turn_id = {
            let mut state = self.inner.lock().await;
            let Some(active_run) = state.active_runs_by_thread.remove(thread_id) else {
                return false;
            };

            let requested_turn_id = requested_turn_id.trim();
            if !requested_turn_id.is_empty() && requested_turn_id != active_run.turn_id {
                state
                    .active_runs_by_thread
                    .insert(thread_id.to_string(), active_run);
                return false;
            }

            if let Some(record) = state.threads_by_id.get_mut(thread_id) {
                record.summary.running = false;
                record.summary.updated_at_ms = now_epoch_ms();
                record.summary.preview = "Stopped".to_string();
            }

            state.codex_process_online = !state.active_runs_by_thread.is_empty();
            active_run.abort_handle.abort();
            active_run.turn_id
        };

        self.append_thread_event(
            thread_id,
            ThreadEventPayload::StatusChanged(StatusChanged {
                turn_id: aborted_turn_id.clone(),
                status: "stopped".to_string(),
            }),
        )
        .await;

        let completion_sequence = self.next_global_sequence().await;
        let completion = ServerFrame {
            payload: Some(ServerPayload::RunCompletion(RunCompletion {
                thread_id: thread_id.to_string(),
                turn_id: aborted_turn_id,
                global_sequence: completion_sequence,
                result: "stopped".to_string(),
                error_message: String::new(),
            })),
        };
        let _ = outbound_tx.send(encode_server_frame(completion));
        true
    }

    async fn emit_codex_exec_run(
        &self,
        thread_id: String,
        turn_id: String,
        prompt: String,
        outbound_tx: mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>,
    ) {
        let started_sequence = self.next_global_sequence().await;
        let started = ServerFrame {
            payload: Some(ServerPayload::RunEvent(RunEvent {
                thread_id: thread_id.clone(),
                turn_id: turn_id.clone(),
                global_sequence: started_sequence,
                payload: Some(RunEventPayload::Started(RunStarted {
                    model: self
                        .config
                        .model
                        .clone()
                        .unwrap_or_else(|| "codex-exec".to_string()),
                })),
            })),
        };
        let _ = outbound_tx.send(encode_server_frame(started));

        let spawn_result = self.spawn_codex_child(&prompt);
        let mut child = match spawn_result {
            Ok(child) => child,
            Err(error) => {
                let message = format!("failed to start codex runtime: {error:#}");
                warn!("{message}");
                self.finish_run(
                    &thread_id,
                    &turn_id,
                    "failed",
                    &message,
                    Some(&message),
                    outbound_tx,
                )
                .await;
                return;
            }
        };

        let stdout = match child.stdout.take() {
            Some(stdout) => stdout,
            None => {
                let message = "codex runtime did not expose stdout".to_string();
                warn!("{message}");
                self.finish_run(
                    &thread_id,
                    &turn_id,
                    "failed",
                    &message,
                    Some(&message),
                    outbound_tx,
                )
                .await;
                return;
            }
        };

        let stderr = match child.stderr.take() {
            Some(stderr) => stderr,
            None => {
                let message = "codex runtime did not expose stderr".to_string();
                warn!("{message}");
                self.finish_run(
                    &thread_id,
                    &turn_id,
                    "failed",
                    &message,
                    Some(&message),
                    outbound_tx,
                )
                .await;
                return;
            }
        };

        let stdout_supervisor = self.clone();
        let stdout_thread_id = thread_id.clone();
        let stdout_turn_id = turn_id.clone();
        let stdout_tx = outbound_tx.clone();
        let stdout_task = tokio::spawn(async move {
            stdout_supervisor
                .consume_codex_stdout(stdout_thread_id, stdout_turn_id, stdout_tx, stdout)
                .await
        });

        let stderr_task = tokio::spawn(async move { read_all_lines(stderr).await });

        let exit_status = match child.wait().await {
            Ok(status) => status,
            Err(error) => {
                let message = format!("codex runtime wait failed: {error}");
                warn!("{message}");
                self.finish_run(
                    &thread_id,
                    &turn_id,
                    "failed",
                    &message,
                    Some(&message),
                    outbound_tx,
                )
                .await;
                return;
            }
        };

        let stdout_summary = match stdout_task.await {
            Ok(Ok(summary)) => summary,
            Ok(Err(error)) => {
                let message = format!("failed to read codex runtime stdout: {error}");
                warn!("{message}");
                self.finish_run(
                    &thread_id,
                    &turn_id,
                    "failed",
                    &message,
                    Some(&message),
                    outbound_tx,
                )
                .await;
                return;
            }
            Err(error) => {
                let message = format!("codex runtime stdout task failed: {error}");
                warn!("{message}");
                self.finish_run(
                    &thread_id,
                    &turn_id,
                    "failed",
                    &message,
                    Some(&message),
                    outbound_tx,
                )
                .await;
                return;
            }
        };

        let stderr_output = match stderr_task.await {
            Ok(output) => output,
            Err(error) => {
                warn!("codex runtime stderr task failed: {error}");
                String::new()
            }
        };

        if exit_status.success() {
            let preview = stdout_summary
                .last_assistant_preview
                .or(stdout_summary.last_reasoning_preview)
                .unwrap_or_else(|| "Run completed".to_string());
            self.finish_run(
                &thread_id,
                &turn_id,
                "completed",
                "",
                Some(&preview),
                outbound_tx,
            )
            .await;
            return;
        }

        let mut error_message = stderr_output.trim().to_string();
        if error_message.is_empty() {
            error_message = format!(
                "codex runtime exited with status {}",
                exit_status
                    .code()
                    .map(|code| code.to_string())
                    .unwrap_or_else(|| "unknown".to_string())
            );
        }

        let preview = stdout_summary
            .last_assistant_preview
            .or(stdout_summary.last_reasoning_preview)
            .unwrap_or_else(|| error_message.clone());

        self.finish_run(
            &thread_id,
            &turn_id,
            "failed",
            &error_message,
            Some(&preview),
            outbound_tx,
        )
        .await;
    }

    fn spawn_codex_child(&self, prompt: &str) -> Result<tokio::process::Child> {
        let mut command = Command::new(&self.config.codex_command);
        command
            .arg("exec")
            .arg("--json")
            .arg("--full-auto")
            .arg("--skip-git-repo-check")
            .arg("--cd")
            .arg(&self.config.workspace_root);

        if let Some(model) = &self.config.model {
            command.arg("--model").arg(model);
        }

        command
            .arg(prompt)
            .current_dir(&self.config.workspace_root)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        command.spawn().map_err(|error| anyhow!(error))
    }

    async fn consume_codex_stdout<R>(
        &self,
        thread_id: String,
        turn_id: String,
        outbound_tx: mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>,
        reader: R,
    ) -> Result<CodexExecOutputSummary>
    where
        R: AsyncRead + Unpin,
    {
        let mut lines = BufReader::new(reader).lines();
        let mut summary = CodexExecOutputSummary::default();

        while let Some(line) = lines.next_line().await? {
            if let Some(reasoning_delta) = parse_reasoning_delta(&line) {
                summary.last_reasoning_preview = Some(reasoning_delta.chars().take(140).collect());
                self.emit_reasoning_delta(
                    &thread_id,
                    &turn_id,
                    reasoning_delta,
                    outbound_tx.clone(),
                )
                .await;
                continue;
            }

            if let Some(assistant_delta) = parse_assistant_delta(&line) {
                summary.last_assistant_preview = Some(assistant_delta.chars().take(140).collect());
                self.emit_assistant_delta(
                    &thread_id,
                    &turn_id,
                    assistant_delta,
                    outbound_tx.clone(),
                )
                .await;
            }
        }

        Ok(summary)
    }

    async fn emit_reasoning_delta(
        &self,
        thread_id: &str,
        turn_id: &str,
        delta: String,
        outbound_tx: mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>,
    ) {
        let item_id = format!("reasoning-{}", Uuid::new_v4());
        let reasoning_sequence = self.next_global_sequence().await;
        let reasoning = ServerFrame {
            payload: Some(ServerPayload::RunEvent(RunEvent {
                thread_id: thread_id.to_string(),
                turn_id: turn_id.to_string(),
                global_sequence: reasoning_sequence,
                payload: Some(RunEventPayload::Reasoning(ReasoningText {
                    item_id: item_id.clone(),
                    delta: delta.clone(),
                })),
            })),
        };
        let _ = outbound_tx.send(encode_server_frame(reasoning));
        self.touch_thread(thread_id, None).await;
        self.append_thread_event(
            thread_id,
            ThreadEventPayload::ReasoningDelta(ThreadReasoningDelta {
                turn_id: turn_id.to_string(),
                item_id,
                delta,
            }),
        )
        .await;
    }

    async fn emit_assistant_delta(
        &self,
        thread_id: &str,
        turn_id: &str,
        delta: String,
        outbound_tx: mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>,
    ) {
        let assistant_sequence = self.next_global_sequence().await;
        let assistant = ServerFrame {
            payload: Some(ServerPayload::RunEvent(RunEvent {
                thread_id: thread_id.to_string(),
                turn_id: turn_id.to_string(),
                global_sequence: assistant_sequence,
                payload: Some(RunEventPayload::AssistantText(AssistantText {
                    delta: delta.clone(),
                })),
            })),
        };
        let _ = outbound_tx.send(encode_server_frame(assistant));
        self.touch_thread(thread_id, Some(delta.clone())).await;
        self.append_thread_event(
            thread_id,
            ThreadEventPayload::AssistantDelta(AssistantDelta {
                turn_id: turn_id.to_string(),
                delta,
            }),
        )
        .await;
    }

    async fn touch_thread(&self, thread_id: &str, preview: Option<String>) {
        let mut state = self.inner.lock().await;
        if let Some(record) = state.threads_by_id.get_mut(thread_id) {
            record.summary.updated_at_ms = now_epoch_ms();
            if let Some(preview) = preview {
                record.summary.preview = preview.chars().take(140).collect();
            }
        }
    }

    async fn finish_run(
        &self,
        thread_id: &str,
        turn_id: &str,
        result: &str,
        error_message: &str,
        preview: Option<&str>,
        outbound_tx: mpsc::UnboundedSender<tokio_tungstenite::tungstenite::Message>,
    ) {
        let should_emit = {
            let mut state = self.inner.lock().await;
            let Some(active_run) = state.active_runs_by_thread.get(thread_id) else {
                return;
            };
            if active_run.turn_id != turn_id {
                return;
            }

            state.active_runs_by_thread.remove(thread_id);
            state.codex_process_online = !state.active_runs_by_thread.is_empty();

            if let Some(record) = state.threads_by_id.get_mut(thread_id) {
                record.summary.running = false;
                record.summary.updated_at_ms = now_epoch_ms();
                if let Some(preview) = preview.filter(|value| !value.trim().is_empty()) {
                    record.summary.preview = preview.chars().take(140).collect();
                }
            }

            true
        };

        if !should_emit {
            return;
        }

        self.append_thread_event(
            thread_id,
            ThreadEventPayload::StatusChanged(StatusChanged {
                turn_id: turn_id.to_string(),
                status: result.to_string(),
            }),
        )
        .await;

        let completion_sequence = self.next_global_sequence().await;
        let completion = ServerFrame {
            payload: Some(ServerPayload::RunCompletion(RunCompletion {
                thread_id: thread_id.to_string(),
                turn_id: turn_id.to_string(),
                global_sequence: completion_sequence,
                result: result.to_string(),
                error_message: error_message.to_string(),
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

fn parse_reasoning_delta(line: &str) -> Option<String> {
    let value: Value = serde_json::from_str(line).ok()?;
    let event_type = value.get("type")?.as_str()?;
    if event_type != "item.completed" {
        return None;
    }

    let item = value.get("item")?;
    if item.get("type")?.as_str()? != "reasoning" {
        return None;
    }

    let text = item.get("text")?.as_str()?.trim();
    if text.is_empty() {
        return None;
    }

    Some(text.to_string())
}

fn parse_assistant_delta(line: &str) -> Option<String> {
    let value: Value = serde_json::from_str(line).ok()?;
    let event_type = value.get("type")?.as_str()?;
    if event_type != "item.completed" {
        return None;
    }

    let item = value.get("item")?;
    if item.get("type")?.as_str()? != "agent_message" {
        return None;
    }

    let text = item.get("text")?.as_str()?.trim();
    if text.is_empty() {
        return None;
    }

    Some(text.to_string())
}

async fn read_all_lines<R>(reader: R) -> String
where
    R: AsyncRead + Unpin,
{
    let mut lines = BufReader::new(reader).lines();
    let mut entries = Vec::new();
    while let Ok(Some(line)) = lines.next_line().await {
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            entries.push(trimmed.to_string());
        }
    }
    entries.join("\n")
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
