//! HostedAdapter: the hosted Think stream as canonical source events.
//!
//! `HostedAgentClient::send` keeps its UniFFI contract and still reports to
//! `HostedAgentEventListener`. In parallel it drives this adapter, which
//! turns `cf_agent` chunks into [`SourceEvent`]s on the shared store under
//! [`hosted_thread_key`], so hosted turns become real thread items that a
//! chat subscription renders like any other source.

use std::collections::HashSet;
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::Value;

use crate::conversation_uniffi::{
    HydratedConversationItem, HydratedConversationItemContent, HydratedReasoningData,
};
use crate::store::AppStoreReducer;
use crate::store::chat::{HOSTED_SERVER_ID, assistant_item, tool_item, user_item};
use crate::types::{AppOperationStatus, ThreadKey};

use super::{ConnectionPhase, SourceEvent, SourceKind, TextChannel, TurnOutcome};

/// The store thread key of a hosted Think session.
pub fn hosted_thread_key(session_id: &str) -> ThreadKey {
    ThreadKey {
        server_id: HOSTED_SERVER_ID.to_string(),
        thread_id: session_id.to_string(),
    }
}

pub(crate) struct HostedAdapter {
    sink: Option<Arc<AppStoreReducer>>,
    key: ThreadKey,
    turn_id: Option<String>,
    /// Assistant message the stream is writing (`start.messageId`).
    message_id: Option<String>,
    /// Text segment of that message; a tool call after text starts the next
    /// one. Mirrors `hydrated_items`, so live and reloaded ids agree.
    segment: usize,
    segment_has_text: bool,
}

fn observed_active_sessions() -> &'static Mutex<HashSet<String>> {
    static SESSIONS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashSet::new()))
}

impl HostedAdapter {
    pub(crate) fn has_started(&self) -> bool {
        self.turn_id.is_some()
    }

    /// Routes into the process-wide store when one exists. Without a store
    /// (unit tests, early launch) the adapter is inert.
    pub(crate) fn attach(session_id: &str) -> Self {
        let sink = crate::ffi::shared::shared_mobile_client_if_initialized()
            .map(|client| Arc::clone(&client.app_store));
        Self::with_sink(sink, session_id)
    }

    pub(crate) fn with_sink(sink: Option<Arc<AppStoreReducer>>, session_id: &str) -> Self {
        Self {
            sink,
            key: hosted_thread_key(session_id),
            turn_id: None,
            message_id: None,
            segment: 0,
            segment_has_text: false,
        }
    }

    fn emit(&self, events: Vec<SourceEvent>) {
        if let Some(sink) = &self.sink {
            sink.apply_source_events(&self.key, SourceKind::Hosted, &events);
        }
    }

    fn turn(&self) -> &str {
        self.turn_id.as_deref().unwrap_or("hosted-turn")
    }

    /// The learner message is part of the request, so it is accepted as soon
    /// as the request is built. The turn is keyed by the learner message id,
    /// which Think persists, so `hydrate` rebuilds the same turn ids (stable
    /// row ids, kept "Worked for" timings) after a reload.
    pub(crate) fn begin(&mut self, message_id: &str, prompt: &str) {
        self.turn_id = Some(message_id.to_string());
        let turn_id = message_id.to_string();
        self.emit(vec![
            SourceEvent::ItemCompleted {
                item: user_item(message_id, prompt, Some(&turn_id)),
            },
            SourceEvent::TurnAccepted {
                client_msg_id: Some(message_id.to_string()),
                turn_id: turn_id.clone(),
            },
            SourceEvent::TurnStarted { turn_id },
            SourceEvent::Progress {
                label: Some("Waiting on model…".to_string()),
            },
        ]);
    }

    pub(crate) fn recovering(&self, recovering: bool) {
        self.emit(vec![SourceEvent::Connection {
            phase: if recovering {
                ConnectionPhase::Reconnecting
            } else {
                ConnectionPhase::Live
            },
        }]);
    }

    /// One `cf_agent_use_chat_response` body chunk.
    pub(crate) fn chunk(&mut self, chunk: &Value) {
        let kind = chunk.get("type").and_then(Value::as_str).unwrap_or("");
        if kind == "start" {
            let message_id = chunk.get("messageId").and_then(Value::as_str);
            if message_id.is_some() && message_id != self.message_id.as_deref() {
                self.message_id = message_id.map(str::to_string);
                self.segment = 0;
                self.segment_has_text = false;
            }
            return;
        }
        let channel = match kind {
            "text-delta" => TextChannel::Answer,
            "reasoning-delta" => TextChannel::Reasoning,
            _ => return,
        };
        let Some(delta) = chunk.get("delta").and_then(Value::as_str) else {
            return;
        };
        if delta.is_empty() {
            return;
        }
        let message_id = self
            .message_id
            .clone()
            .unwrap_or_else(|| format!("hosted:{}", self.turn()));
        let item_id = match channel {
            TextChannel::Reasoning => reasoning_item_id(&message_id, self.segment),
            _ => {
                self.segment_has_text = true;
                text_item_id(&message_id, self.segment)
            }
        };
        self.emit(vec![SourceEvent::TextDelta {
            item_id,
            channel,
            text: delta.to_string(),
        }]);
    }

    fn tool_item(
        &self,
        tool_call_id: &str,
        tool_name: &str,
        status: AppOperationStatus,
        arguments_json: Option<String>,
        success: Option<bool>,
        summary: Option<String>,
    ) -> HydratedConversationItem {
        tool_item(
            &format!("hosted-tool:{tool_call_id}"),
            tool_name,
            status,
            arguments_json,
            summary,
            success,
            Some(self.turn()),
        )
    }

    pub(crate) fn tool_started(
        &mut self,
        tool_call_id: &str,
        tool_name: &str,
        arguments_json: &str,
    ) {
        if self.segment_has_text {
            self.segment += 1;
            self.segment_has_text = false;
        }
        let item = self.tool_item(
            tool_call_id,
            tool_name,
            AppOperationStatus::InProgress,
            Some(arguments_json.to_string()),
            None,
            None,
        );
        self.emit(vec![SourceEvent::ItemStarted { item }]);
    }

    pub(crate) fn tool_finished(
        &mut self,
        tool_call_id: &str,
        tool_name: &str,
        arguments_json: &str,
        success: bool,
        error_message: Option<&str>,
    ) {
        let item = self.tool_item(
            tool_call_id,
            tool_name,
            if success {
                AppOperationStatus::Completed
            } else {
                AppOperationStatus::Failed
            },
            Some(arguments_json.to_string()),
            Some(success),
            error_message.map(str::to_string),
        );
        self.emit(vec![SourceEvent::ItemCompleted { item }]);
    }

    /// Settles the turn from `send`'s result.
    pub(crate) fn finish<T>(&self, result: &Result<T, crate::hosted_agent::HostedAgentError>) {
        use crate::hosted_agent::HostedAgentError;
        let outcome = match result {
            Ok(_) => TurnOutcome::Completed,
            Err(HostedAgentError::Cancelled) => TurnOutcome::Interrupted,
            Err(error) => TurnOutcome::Failed {
                message: error.to_string(),
            },
        };
        let mut events = vec![SourceEvent::TurnSettled {
            turn_id: self.turn_id.clone(),
            outcome: outcome.clone(),
        }];
        if outcome == TurnOutcome::Completed
            && let Some(sink) = &self.sink
            && let Some(request) = sink.chat_pending_fence_question(&self.key)
        {
            events.push(SourceEvent::InputRequested { request });
        }
        self.emit(events);
    }

    /// Mirrors the server-authoritative Think transcript (raw `cf_agent`
    /// messages) into the store.
    ///
    /// Learner messages open turns keyed by their id, as `begin` does, and
    /// assistant parts keep their order: text segments become answers and
    /// `tool-*` / `dynamic-tool` parts become tool items with the same ids
    /// the live turn used, so work rows and the "Worked for" fold survive a
    /// reload. Think does not persist why a turn failed; the hub keeps the
    /// "The agent stopped" notice across reloads for as long as the chat
    /// state lives (see `ChatHub::replace_owned_transcript`).
    pub(crate) fn hydrate(&self, messages: &[Value]) {
        let Some(sink) = &self.sink else {
            return;
        };
        sink.chat_replace_owned_transcript(&self.key, SourceKind::Hosted, hydrated_items(messages));
    }

    /// A history snapshot does not imply the originating device's work ended.
    /// Keep that turn busy until a later authoritative idle history load.
    pub(crate) fn hydrate_activity(
        &self,
        messages: &[Value],
        originating_device: bool,
        waiting_for_tools: bool,
    ) {
        let turn_id = messages
            .iter()
            .rev()
            .find(|message| message.get("role").and_then(Value::as_str) == Some("user"))
            .and_then(|message| message.get("id").and_then(Value::as_str));
        let Some(turn_id) = turn_id else {
            return;
        };
        observed_active_sessions()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .insert(self.key.thread_id.clone());
        let label = if waiting_for_tools && originating_device {
            "This Hosted task is waiting for its original device's course tools."
        } else {
            "Hosted is still working on the original device. Sync the course when it finishes, then reopen this discussion."
        };
        self.emit(vec![
            SourceEvent::TurnStarted {
                turn_id: turn_id.to_string(),
            },
            SourceEvent::Progress {
                label: Some(label.to_string()),
            },
        ]);
    }

    pub(crate) fn hydrate_idle_activity(&self, messages: &[Value], terminal_status: Option<&str>) {
        if !observed_active_sessions()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(&self.key.thread_id)
        {
            return;
        }
        let turn_id = messages
            .iter()
            .rev()
            .find(|message| message.get("role").and_then(Value::as_str) == Some("user"))
            .and_then(|message| message.get("id").and_then(Value::as_str));
        let outcome = match terminal_status {
            Some("completed") => TurnOutcome::Completed,
            Some("error") => TurnOutcome::Failed {
                message: "The Hosted task stopped before it completed. Its history is saved."
                    .into(),
            },
            _ => TurnOutcome::Interrupted,
        };
        self.emit(vec![SourceEvent::TurnSettled {
            turn_id: turn_id.map(str::to_string),
            outcome,
        }]);
    }
}

/// Raw Think messages as source-owned transcript items.
pub(crate) fn hydrated_items(messages: &[Value]) -> Vec<HydratedConversationItem> {
    let mut items = Vec::new();
    let mut current_turn: Option<String> = None;
    for message in messages {
        let (Some(id), Some(role)) = (
            message.get("id").and_then(Value::as_str),
            message.get("role").and_then(Value::as_str),
        ) else {
            continue;
        };
        let parts = message
            .get("parts")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        match role {
            "user" => {
                let text: String = parts
                    .iter()
                    .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
                    .filter_map(|part| part.get("text").and_then(Value::as_str))
                    .collect();
                if !text.is_empty() {
                    items.push(user_item(id, &text, Some(id)));
                    current_turn = Some(id.to_string());
                }
            }
            "assistant" => {
                let turn = current_turn.as_deref();
                let mut segment = 0usize;
                let mut segment_has_text = false;
                for part in parts {
                    let kind = part.get("type").and_then(Value::as_str).unwrap_or("");
                    let (item_id, item) = match kind {
                        "text" | "reasoning" => {
                            let Some(text) = part.get("text").and_then(Value::as_str) else {
                                continue;
                            };
                            if text.is_empty() {
                                continue;
                            }
                            if kind == "text" {
                                segment_has_text = true;
                                let item_id = text_item_id(id, segment);
                                (item_id.clone(), assistant_item(&item_id, text, turn))
                            } else {
                                let item_id = reasoning_item_id(id, segment);
                                (item_id.clone(), reasoning_item(&item_id, text, turn))
                            }
                        }
                        _ => {
                            let Some(tool) = hydrated_tool(part, kind, turn) else {
                                continue;
                            };
                            if segment_has_text {
                                segment += 1;
                                segment_has_text = false;
                            }
                            (tool.id.clone(), tool)
                        }
                    };
                    // Consecutive parts of one segment extend its item, as
                    // the live deltas did.
                    match items
                        .iter_mut()
                        .find(|existing: &&mut HydratedConversationItem| existing.id == item_id)
                    {
                        Some(existing) => append_item_text(existing, &item),
                        None => items.push(item),
                    }
                }
            }
            _ => {}
        }
    }
    items
}

fn text_item_id(message_id: &str, segment: usize) -> String {
    if segment == 0 {
        message_id.to_string()
    } else {
        format!("{message_id}:{segment}")
    }
}

fn reasoning_item_id(message_id: &str, segment: usize) -> String {
    format!("{message_id}:reasoning:{segment}")
}

fn reasoning_item(id: &str, text: &str, turn: Option<&str>) -> HydratedConversationItem {
    HydratedConversationItem {
        id: id.to_string(),
        content: HydratedConversationItemContent::Reasoning(HydratedReasoningData {
            summary: Vec::new(),
            content: vec![text.to_string()],
        }),
        source_turn_id: turn.map(str::to_string),
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: false,
    }
}

fn append_item_text(existing: &mut HydratedConversationItem, next: &HydratedConversationItem) {
    match (&mut existing.content, &next.content) {
        (
            HydratedConversationItemContent::Assistant(existing),
            HydratedConversationItemContent::Assistant(next),
        ) => existing.text.push_str(&next.text),
        (
            HydratedConversationItemContent::Reasoning(existing),
            HydratedConversationItemContent::Reasoning(next),
        ) => match existing.content.last_mut() {
            Some(last) => last.push_str(&next.content.concat()),
            None => existing.content.extend(next.content.iter().cloned()),
        },
        _ => *existing = next.clone(),
    }
}

/// A persisted `tool-<name>` or `dynamic-tool` part.
fn hydrated_tool(part: &Value, kind: &str, turn: Option<&str>) -> Option<HydratedConversationItem> {
    let name = match kind.strip_prefix("tool-") {
        Some(name) => name.to_string(),
        None if kind == "dynamic-tool" => part.get("toolName")?.as_str()?.to_string(),
        None => return None,
    };
    let call_id = part.get("toolCallId")?.as_str()?;
    let (status, success, summary) = match part.get("state").and_then(Value::as_str) {
        Some("output-available") => (AppOperationStatus::Completed, Some(true), None),
        Some("output-error") => (
            AppOperationStatus::Failed,
            Some(false),
            part.get("errorText")
                .and_then(Value::as_str)
                .map(str::to_string),
        ),
        // A call the stored turn never finished is not running any more.
        _ => (AppOperationStatus::Unknown, None, None),
    };
    let arguments_json = part
        .get("input")
        .and_then(|input| serde_json::to_string(input).ok());
    Some(tool_item(
        &format!("hosted-tool:{call_id}"),
        &name,
        status,
        arguments_json,
        summary,
        success,
        turn,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::chat::ChatViewOptions;
    use crate::store::timeline::TimelineRowKind;
    use crate::store::turn::{LocalAction, TurnPhase};
    use serde_json::json;

    fn kinds(rows: &[crate::store::timeline::TimelineRow]) -> Vec<&'static str> {
        rows.iter()
            .map(|row| match &row.kind {
                TimelineRowKind::User { .. } => "user",
                TimelineRowKind::Answer { .. } => "answer",
                TimelineRowKind::Work { .. } => "work",
                TimelineRowKind::Fold { .. } => "fold",
                TimelineRowKind::Notice { .. } => "notice",
                _ => "other",
            })
            .collect()
    }

    fn all_activity() -> ChatViewOptions {
        ChatViewOptions {
            shows_internal_course_activity: true,
            ..ChatViewOptions::default()
        }
    }

    /// Recorded `cf_agent` chunk stream of one hosted turn with a client
    /// tool call and its continuation, plus the transcript Think returns
    /// for it afterwards.
    #[test]
    fn fixture_hosted_turn_with_tool_then_reload() {
        let reducer = Arc::new(AppStoreReducer::new());
        let session = "7b0c3f6e-2f55-4b8e-9b6e-4a9c1b3d2e10";
        let key = hosted_thread_key(session);
        let _chat = reducer.chat_subscribe(&key);
        let mut adapter = HostedAdapter::with_sink(Some(Arc::clone(&reducer)), session);

        adapter.begin("m1", "Teach me OLED");
        let view = reducer.chat_view(&key, &ChatViewOptions::default());
        assert_eq!(view.phase, TurnPhase::Thinking);
        assert_eq!(view.progress_label.as_deref(), Some("Waiting on model…"));

        let recorded = [
            ("req-1", json!({"type": "start", "messageId": "srv-a1"})),
            (
                "req-1",
                json!({"type": "reasoning-delta", "id": "r1", "delta": "Need the page."}),
            ),
            (
                "req-1",
                json!({"type": "text-delta", "id": "p1", "delta": "Let me "}),
            ),
            (
                "req-1",
                json!({"type": "text-delta", "id": "p1", "delta": "check."}),
            ),
        ];
        for (_request, chunk) in &recorded {
            adapter.chunk(chunk);
        }
        assert_eq!(
            reducer.chat_view(&key, &ChatViewOptions::default()).phase,
            TurnPhase::Streaming
        );
        adapter.tool_started("call-1", "native-editor-fetch", r#"{"page":"intro"}"#);
        assert_eq!(
            reducer.chat_view(&key, &ChatViewOptions::default()).phase,
            TurnPhase::Acting
        );
        adapter.tool_finished(
            "call-1",
            "native-editor-fetch",
            r#"{"page":"intro"}"#,
            true,
            None,
        );
        adapter
            .chunk(&json!({"type": "text-delta", "id": "p1", "delta": "OLED pixels emit light."}));
        adapter.finish::<()>(&Ok(()));

        let live = reducer.chat_view(&key, &all_activity());
        assert!(matches!(live.phase, TurnPhase::Settled { .. }));
        assert_eq!(
            kinds(&live.rows),
            vec!["user", "fold", "work", "answer", "work", "answer"]
        );
        assert_eq!(live.rows[0].id, "user:m1");
        // The hosted session never appears in the app-server session list.
        assert!(reducer.snapshot().threads.is_empty());

        adapter.hydrate(&[
            json!({"id": "m1", "role": "user", "parts": [{"type": "text", "text": "Teach me OLED"}]}),
            json!({"id": "srv-a1", "role": "assistant", "parts": [
                {"type": "reasoning", "text": "Need the page."},
                {"type": "text", "text": "Let me check."},
                {"type": "tool-native-editor-fetch", "toolCallId": "call-1",
                 "state": "output-available", "input": {"page": "intro"}, "output": {"ok": true}},
                {"type": "text", "text": "OLED pixels emit light."}
            ]}),
        ]);
        let reloaded = reducer.chat_view(&key, &all_activity());
        // Same rows, same ids, same digests: the reload is a no-op diff.
        assert_eq!(reloaded.rows, live.rows);
    }

    #[test]
    fn failures_settle_with_an_error_notice_that_survives_reload() {
        let reducer = Arc::new(AppStoreReducer::new());
        let session = "7b0c3f6e-2f55-4b8e-9b6e-4a9c1b3d2e11";
        let key = hosted_thread_key(session);
        let _chat = reducer.chat_subscribe(&key);
        let mut adapter = HostedAdapter::with_sink(Some(Arc::clone(&reducer)), session);
        adapter.begin("m1", "Hi");
        adapter.chunk(&json!({"type": "text-delta", "delta": "Partial"}));
        adapter.finish::<()>(&Err(crate::hosted_agent::HostedAgentError::Request {
            detail: "model overloaded".into(),
        }));
        let view = reducer.chat_view(&key, &ChatViewOptions::default());
        assert!(matches!(
            &view.phase,
            TurnPhase::Settled { outcome: TurnOutcome::Failed { message } } if message.contains("model overloaded")
        ));
        let notice = |rows: &[crate::store::timeline::TimelineRow]| {
            rows.iter().any(|row| {
                matches!(
                    &row.kind,
                    TimelineRowKind::Notice { title, .. } if title == "The agent stopped"
                )
            })
        };
        assert!(notice(&view.rows));

        adapter.hydrate(&[
            json!({"id": "m1", "role": "user", "parts": [{"type": "text", "text": "Hi"}]}),
            json!({"id": "a1", "role": "assistant", "parts": [{"type": "text", "text": "Partial"}]}),
        ]);
        let reloaded = reducer.chat_view(&key, &ChatViewOptions::default());
        assert_eq!(kinds(&reloaded.rows), vec!["user", "answer", "notice"]);
        assert!(notice(&reloaded.rows));
    }

    #[test]
    fn cancel_shows_stopping_until_send_settles() {
        let reducer = Arc::new(AppStoreReducer::new());
        let session = "7b0c3f6e-2f55-4b8e-9b6e-4a9c1b3d2e14";
        let key = hosted_thread_key(session);
        let mut adapter = HostedAdapter::with_sink(Some(Arc::clone(&reducer)), session);
        adapter.begin("m1", "Hi");
        reducer.chat_local_action(&key, LocalAction::Stop);
        assert_eq!(
            reducer.chat_view(&key, &ChatViewOptions::default()).phase,
            TurnPhase::Stopping
        );
        adapter.finish::<()>(&Err(crate::hosted_agent::HostedAgentError::Cancelled));
        assert_eq!(
            reducer.chat_view(&key, &ChatViewOptions::default()).phase,
            TurnPhase::Settled {
                outcome: TurnOutcome::Interrupted
            }
        );
    }

    #[test]
    fn hydration_rebuilds_turns() {
        let reducer = Arc::new(AppStoreReducer::new());
        let session = "7b0c3f6e-2f55-4b8e-9b6e-4a9c1b3d2e12";
        let adapter = HostedAdapter::with_sink(Some(Arc::clone(&reducer)), session);
        adapter.hydrate(&[
            json!({"id": "u1", "role": "user", "parts": [{"type": "text", "text": "Hi"}]}),
            json!({"id": "a1", "role": "assistant", "parts": [
                {"type": "text", "text": "Hello"},
                {"type": "dynamic-tool", "toolName": "course_bash", "toolCallId": "c9",
                 "state": "output-error", "input": {}, "errorText": "denied"}
            ]}),
            json!({"id": "s1", "role": "system", "parts": [{"type": "text", "text": "x"}]}),
        ]);
        let view = reducer.chat_view(&hosted_thread_key(session), &all_activity());
        let ids: Vec<&str> = view.rows.iter().map(|row| row.id.as_str()).collect();
        assert_eq!(
            ids,
            vec![
                "user:turn:u1",
                "answer:a1",
                "fold:u1",
                "work:hosted-tool:c9"
            ]
        );
        assert!(matches!(
            &view.rows[3].kind,
            TimelineRowKind::Work {
                has_failure: true,
                ..
            }
        ));
    }
}
