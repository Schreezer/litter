//! Per-thread chat state behind `AppStore.subscribe_chat`.
//!
//! The hub sits beside the canonical snapshot inside [`AppStoreReducer`]:
//!
//! - every thread gets a [`TurnMachine`] fed by [`SourceEvent`]s from all
//!   source adapters;
//! - sources that do not live in the app-server snapshot (hosted Think,
//!   Apple Foundation Models) keep their canonical items here, as a
//!   source-owned transcript, so they never leak into the session list;
//! - optimistic learner messages wait in an outbox until the source echoes
//!   them;
//! - a per-thread sequence number wakes chat subscribers, which derive the
//!   timeline at most once per frame and diff it against what they last
//!   delivered.
//!
//! Lock order: the snapshot `RwLock` is always taken before the hub mutex,
//! never the other way round.
//!
//! [`AppStoreReducer`]: super::AppStoreReducer

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard};

use tokio::sync::watch;

use crate::conversation_uniffi::{
    HydratedAssistantMessageData, HydratedConversationItem, HydratedConversationItemContent,
    HydratedDynamicToolCallData, HydratedErrorData, HydratedProposedPlanData,
    HydratedReasoningData, HydratedUserMessageData,
};
use crate::source::normalize::{extract_question, project_course_items, type_hermes_envelopes};
use crate::source::{
    ConnectionPhase, ExternalMessageRole, ExternalSourceEvent, InputRequest, SourceEvent,
    SourceKind, TextChannel, TurnOutcome,
};
use crate::types::{AppOperationStatus, ThreadKey, ThreadSummaryStatus};

use super::snapshot::{ServerHealthSnapshot, ServerSnapshot, ThreadSnapshot};
pub(crate) use super::timeline::PendingQuestionInput;
use super::timeline::{TimelineInput, TimelineRow, TimelineRowKind, derive_rows};
use super::turn::{LocalAction, TurnMachine, TurnPhase, TurnTiming};

/// `ThreadKey.server_id` of hosted Think sessions.
pub const HOSTED_SERVER_ID: &str = "learnfold-hosted";
/// `ThreadKey.server_id` of Apple Foundation Models sessions.
pub const APPLE_SERVER_ID: &str = "learnfold-apple";

/// Updates carrying more row churn than this are sent as a snapshot.
const SNAPSHOT_CHURN_THRESHOLD: usize = 64;

pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

// ── UniFFI surface ────────────────────────────────────────────────────────

/// How a chat subscription projects its thread.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct ChatViewOptions {
    /// Show only the learner's question for `<selected_course_passage>`
    /// prompts (selection discussions).
    pub hides_selection_envelope: bool,
    /// Show internal course turns and course tools that the course chat
    /// normally hides.
    pub shows_internal_course_activity: bool,
    /// Drop course-plan rows. Discussions about an existing course never
    /// propose a new plan, so a stray plan fence must not render as one.
    pub hides_plan_rows: bool,
}

/// One update on a chat subscription. `seq` is the thread's sequence
/// number: monotonic, not contiguous (coalesced changes skip numbers).
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ChatUpdate {
    /// Full state. Sent first, after `resync()`, and when a change is too
    /// large to diff usefully.
    Snapshot {
        rows: Vec<TimelineRow>,
        phase: TurnPhase,
        connection: ConnectionPhase,
        progress_label: Option<String>,
        active_turn_started_at_ms: Option<i64>,
        seq: u64,
    },
    /// Rows inserted or replaced (`upserts`) and removed. `order` is the
    /// complete row id order after the change.
    RowsChanged {
        upserts: Vec<TimelineRow>,
        removals: Vec<String>,
        order: Vec<String>,
        seq: u64,
    },
    /// Text appended to an `Answer` row's `text`. `digest` is the row's new
    /// digest.
    TextAppended {
        row_id: String,
        text: String,
        digest: u64,
        seq: u64,
    },
    PhaseChanged {
        phase: TurnPhase,
        progress_label: Option<String>,
        active_turn_started_at_ms: Option<i64>,
        seq: u64,
    },
    ConnectionChanged {
        connection: ConnectionPhase,
        seq: u64,
    },
}

// ── View ──────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct ChatView {
    pub rows: Vec<TimelineRow>,
    pub phase: TurnPhase,
    pub connection: ConnectionPhase,
    pub progress_label: Option<String>,
    pub active_turn_started_at_ms: Option<i64>,
    pub seq: u64,
}

impl ChatView {
    pub(crate) fn into_snapshot(self) -> ChatUpdate {
        ChatUpdate::Snapshot {
            rows: self.rows,
            phase: self.phase,
            connection: self.connection,
            progress_label: self.progress_label,
            active_turn_started_at_ms: self.active_turn_started_at_ms,
            seq: self.seq,
        }
    }
}

/// What changed between two views, as the smallest useful update list.
pub(crate) fn diff_views(old: &ChatView, new: &ChatView) -> Vec<ChatUpdate> {
    let seq = new.seq;
    let old_rows: HashMap<&str, &TimelineRow> =
        old.rows.iter().map(|row| (row.id.as_str(), row)).collect();
    let new_ids: HashSet<&str> = new.rows.iter().map(|row| row.id.as_str()).collect();

    let mut upserts = Vec::new();
    let mut appends = Vec::new();
    for row in &new.rows {
        match old_rows.get(row.id.as_str()) {
            Some(previous) if previous.digest == row.digest => {}
            Some(previous) => match appended_text(previous, row) {
                Some(text) => appends.push(ChatUpdate::TextAppended {
                    row_id: row.id.clone(),
                    text,
                    digest: row.digest,
                    seq,
                }),
                None => upserts.push(row.clone()),
            },
            None => upserts.push(row.clone()),
        }
    }
    let removals: Vec<String> = old
        .rows
        .iter()
        .filter(|row| !new_ids.contains(row.id.as_str()))
        .map(|row| row.id.clone())
        .collect();

    if upserts.len() + removals.len() > SNAPSHOT_CHURN_THRESHOLD
        && upserts.len() + removals.len() > new.rows.len() / 2
    {
        return vec![new.clone().into_snapshot()];
    }

    let mut updates = Vec::new();
    let order_changed = old.rows.len() != new.rows.len()
        || old
            .rows
            .iter()
            .zip(new.rows.iter())
            .any(|(lhs, rhs)| lhs.id != rhs.id);
    if !upserts.is_empty() || !removals.is_empty() || order_changed {
        updates.push(ChatUpdate::RowsChanged {
            upserts,
            removals,
            order: new.rows.iter().map(|row| row.id.clone()).collect(),
            seq,
        });
    }
    updates.extend(appends);
    if old.phase != new.phase
        || old.progress_label != new.progress_label
        || old.active_turn_started_at_ms != new.active_turn_started_at_ms
    {
        updates.push(ChatUpdate::PhaseChanged {
            phase: new.phase.clone(),
            progress_label: new.progress_label.clone(),
            active_turn_started_at_ms: new.active_turn_started_at_ms,
            seq,
        });
    }
    if old.connection != new.connection {
        updates.push(ChatUpdate::ConnectionChanged {
            connection: new.connection,
            seq,
        });
    }
    updates
}

/// The suffix when `new` is `old` with text appended and nothing else
/// changed.
fn appended_text(old: &TimelineRow, new: &TimelineRow) -> Option<String> {
    if old.turn_id != new.turn_id {
        return None;
    }
    match (&old.kind, &new.kind) {
        (
            TimelineRowKind::Answer {
                text: old_text,
                is_streaming: old_streaming,
                agent_label: old_label,
            },
            TimelineRowKind::Answer {
                text: new_text,
                is_streaming: new_streaming,
                agent_label: new_label,
            },
        ) if old_streaming == new_streaming && old_label == new_label => new_text
            .strip_prefix(old_text.as_str())
            .filter(|suffix| !suffix.is_empty())
            .map(str::to_string),
        _ => None,
    }
}

// ── Hub ───────────────────────────────────────────────────────────────────

pub(crate) struct ChatThreadState {
    source_kind: SourceKind,
    machine: TurnMachine,
    connection: ConnectionPhase,
    seq: u64,
    notify: watch::Sender<u64>,
    /// Canonical items for sources outside the app-server snapshot.
    owned: Option<Vec<HydratedConversationItem>>,
    /// Optimistic learner messages the source has not accepted yet.
    pending_ids: HashSet<String>,
    /// App-server learner messages staged before the thread reached the
    /// store (see `stage_local_user_message_overlay`).
    outbox: Vec<HydratedConversationItem>,
    pending_input_ids: HashSet<String>,
    /// Turn id → row id of the learner message that opened it, recorded when
    /// an optimistic message binds to its turn, so the row keeps the
    /// `user:<local id>` it was first shown with after the echo replaces it.
    user_row_aliases: HashMap<String, String>,
    /// Turns whose learner message the platform withdrew (`UserMessageFailed`
    /// after it put the text back in the composer). Nothing of such a turn
    /// stays in the transcript, including the notice of its failed settle,
    /// so the failure never attaches to the previous turn.
    withdrawn_turns: HashSet<String>,
    /// History an app-server thread carries over from the thread it replaced
    /// (`ExternalSourceEvent::CarriedOverTranscript`), shown before its items.
    carried_over: Vec<HydratedConversationItem>,
    /// Open `ChatSubscription`s.
    subscribers: usize,
    /// The last subscriber left mid-turn; drop the state once it settles.
    evict_when_resting: bool,
}

impl ChatThreadState {
    fn new(source_kind: SourceKind) -> Self {
        let owned = matches!(source_kind, SourceKind::Hosted | SourceKind::Apple).then(Vec::new);
        Self {
            source_kind,
            machine: TurnMachine::default(),
            connection: ConnectionPhase::Live,
            seq: 0,
            notify: watch::channel(0).0,
            owned,
            pending_ids: HashSet::new(),
            outbox: Vec::new(),
            pending_input_ids: HashSet::new(),
            user_row_aliases: HashMap::new(),
            withdrawn_turns: HashSet::new(),
            carried_over: Vec::new(),
            subscribers: 0,
            evict_when_resting: false,
        }
    }

    fn bump(&mut self) {
        self.seq += 1;
        self.notify.send_replace(self.seq);
    }

    /// True when dropping this state loses nothing a later subscriber could
    /// not rebuild: no subscriber, no unsent learner message, and no running
    /// turn in a source-owned transcript.
    fn can_evict(&self) -> bool {
        self.subscribers == 0
            && self.outbox.is_empty()
            && (self.owned.is_none() || !self.machine.phase().is_working())
    }

    fn alias_user_row(&mut self, turn_id: &str, client_msg_id: &str) {
        self.user_row_aliases
            .entry(turn_id.to_string())
            .or_insert_with(|| format!("user:{client_msg_id}"));
    }

    fn apply(&mut self, event: &SourceEvent, now: i64) -> bool {
        // An event about a turn that already settled (late turn/start
        // response, replayed start, duplicate settle) must not clear pending
        // input or claim a learner message. A late `TurnAccepted` still binds
        // its own `client_msg_id`; the machine ignores it.
        if self.machine.is_stale(event) && !matches!(event, SourceEvent::TurnAccepted { .. }) {
            return false;
        }
        let mut changed = false;
        match event {
            SourceEvent::InputRequested { request } => {
                changed |= self.pending_input_ids.insert(request.id().to_string());
            }
            SourceEvent::InputResolved { id } => {
                changed |= self.pending_input_ids.remove(id);
                // Another request is still open: the agent is still waiting.
                if !self.pending_input_ids.is_empty() {
                    return changed;
                }
            }
            SourceEvent::TurnStarted { turn_id } => {
                changed |= !self.pending_input_ids.is_empty();
                self.pending_input_ids.clear();
                // Like the app-server overlay binding: a started turn claims
                // the oldest unacknowledged learner message.
                let pending_ids = &self.pending_ids;
                let claimed = self
                    .owned
                    .iter_mut()
                    .flatten()
                    .chain(self.outbox.iter_mut())
                    .find(|item| item.source_turn_id.is_none() && pending_ids.contains(&item.id));
                if let Some(item) = claimed {
                    item.source_turn_id = Some(turn_id.clone());
                    let id = item.id.clone();
                    self.pending_ids.remove(&id);
                    self.alias_user_row(turn_id, &id);
                    changed = true;
                }
            }
            SourceEvent::TurnSettled { .. } => {
                changed |= !self.pending_input_ids.is_empty();
                self.pending_input_ids.clear();
            }
            SourceEvent::TurnAccepted {
                client_msg_id: Some(client_msg_id),
                turn_id,
            } => {
                changed |= self.pending_ids.remove(client_msg_id);
                for item in self
                    .owned
                    .iter_mut()
                    .flatten()
                    .chain(self.outbox.iter_mut())
                {
                    if item.id == *client_msg_id && item.source_turn_id.is_none() {
                        item.source_turn_id = Some(turn_id.clone());
                        changed = true;
                    }
                }
                self.alias_user_row(turn_id, client_msg_id);
            }
            SourceEvent::Connection { phase } => {
                changed |= self.connection != *phase;
                self.connection = *phase;
            }
            _ => {}
        }
        let withdrawn_settle = self.is_withdrawn_settle(event);
        if let Some(items) = self.owned.as_mut()
            && !withdrawn_settle
        {
            changed |= apply_to_transcript(items, event, self.machine.active_turn_id());
        }
        changed |= self.machine.apply(event, now);
        changed
    }

    /// A settle of a turn whose learner message was withdrawn.
    fn is_withdrawn_settle(&self, event: &SourceEvent) -> bool {
        let SourceEvent::TurnSettled { turn_id, .. } = event else {
            return false;
        };
        turn_id
            .as_deref()
            .or(self.machine.active_turn_id())
            .is_some_and(|turn_id| self.withdrawn_turns.contains(turn_id))
    }

    /// Drops an optimistic learner message the platform could not send, and
    /// anything its turn left behind (a hosted turn can settle as failed
    /// before the platform withdraws the message).
    fn withdraw_user_message(&mut self, client_msg_id: &str) {
        let turn_id = self
            .owned
            .iter()
            .flatten()
            .find(|item| item.id == client_msg_id)
            .and_then(|item| item.source_turn_id.clone())
            .or_else(|| {
                self.user_row_aliases
                    .iter()
                    .find(|(_, row)| row.strip_prefix("user:") == Some(client_msg_id))
                    .map(|(turn, _)| turn.clone())
            });
        if let Some(items) = self.owned.as_mut() {
            items.retain(|item| {
                item.id != client_msg_id && (turn_id.is_none() || item.source_turn_id != turn_id)
            });
        }
        self.pending_ids.remove(client_msg_id);
        if let Some(turn_id) = turn_id {
            self.user_row_aliases.remove(&turn_id);
            self.withdrawn_turns.insert(turn_id);
        }
    }

    fn apply_local(&mut self, action: &LocalAction, now: i64) -> bool {
        if matches!(action, LocalAction::Send) {
            self.pending_input_ids.clear();
        }
        self.machine.apply_local(action, now)
    }
}

/// Applies an event to a source-owned transcript. Returns true when items
/// changed.
fn apply_to_transcript(
    items: &mut Vec<HydratedConversationItem>,
    event: &SourceEvent,
    active_turn_id: Option<&str>,
) -> bool {
    match event {
        SourceEvent::TextDelta {
            item_id,
            channel,
            text,
        } => {
            if text.is_empty() {
                return false;
            }
            let index = match items.iter().position(|item| item.id == *item_id) {
                Some(index) => index,
                None => {
                    items.push(streamed_item(item_id, *channel, active_turn_id));
                    items.len() - 1
                }
            };
            append_text(&mut items[index], *channel, text);
            true
        }
        SourceEvent::ItemStarted { item }
        | SourceEvent::ItemUpdated { item }
        | SourceEvent::ItemCompleted { item } => {
            let mut item = item.clone();
            if item.source_turn_id.is_none() {
                item.source_turn_id = active_turn_id.map(str::to_string);
            }
            match items.iter_mut().find(|existing| existing.id == item.id) {
                Some(existing) if *existing == item => false,
                Some(existing) => {
                    *existing = item;
                    true
                }
                None => {
                    items.push(item);
                    true
                }
            }
        }
        SourceEvent::TurnSettled {
            turn_id,
            outcome: TurnOutcome::Failed { message },
        } => {
            let turn_id = turn_id.as_deref().or(active_turn_id);
            let id = format!("{TURN_ERROR_ITEM_PREFIX}{}", turn_id.unwrap_or("unscoped"));
            if items.iter().any(|item| item.id == id) {
                return false;
            }
            items.push(HydratedConversationItem {
                id,
                content: HydratedConversationItemContent::Error(HydratedErrorData {
                    title: "The agent stopped".to_string(),
                    message: message.clone(),
                    details: None,
                }),
                source_turn_id: turn_id.map(str::to_string),
                source_turn_index: None,
                timestamp: None,
                is_from_user_turn_boundary: false,
            });
            true
        }
        _ => false,
    }
}

/// Id prefix of the notice a failed turn leaves in a source-owned
/// transcript.
const TURN_ERROR_ITEM_PREFIX: &str = "turn-error:";

fn streamed_item(
    item_id: &str,
    channel: TextChannel,
    active_turn_id: Option<&str>,
) -> HydratedConversationItem {
    let content = match channel {
        TextChannel::Answer => {
            HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: String::new(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            })
        }
        TextChannel::Reasoning => {
            HydratedConversationItemContent::Reasoning(HydratedReasoningData {
                summary: Vec::new(),
                content: Vec::new(),
            })
        }
        TextChannel::Plan => {
            HydratedConversationItemContent::ProposedPlan(HydratedProposedPlanData {
                content: String::new(),
            })
        }
    };
    HydratedConversationItem {
        id: item_id.to_string(),
        content,
        source_turn_id: active_turn_id.map(str::to_string),
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: false,
    }
}

fn append_text(item: &mut HydratedConversationItem, channel: TextChannel, text: &str) {
    match (&mut item.content, channel) {
        (HydratedConversationItemContent::Assistant(data), _) => data.text.push_str(text),
        (HydratedConversationItemContent::Reasoning(data), _) => match data.content.last_mut() {
            Some(last) => last.push_str(text),
            None => data.content.push(text.to_string()),
        },
        (HydratedConversationItemContent::ProposedPlan(data), _) => data.content.push_str(text),
        (_, channel) => {
            // The id was reused for a different kind; restart it as text.
            *item = streamed_item(&item.id, channel, item.source_turn_id.as_deref());
            append_text(item, channel, text);
        }
    }
}

fn item_text(item: &HydratedConversationItem) -> Option<String> {
    match &item.content {
        HydratedConversationItemContent::Assistant(data) => Some(data.text.clone()),
        HydratedConversationItemContent::Reasoning(data) => Some(data.content.concat()),
        HydratedConversationItemContent::ProposedPlan(data) => Some(data.content.clone()),
        _ => None,
    }
}

pub(crate) fn tool_item(
    item_id: &str,
    name: &str,
    status: AppOperationStatus,
    arguments_json: Option<String>,
    summary: Option<String>,
    success: Option<bool>,
    turn_id: Option<&str>,
) -> HydratedConversationItem {
    HydratedConversationItem {
        id: item_id.to_string(),
        content: HydratedConversationItemContent::DynamicToolCall(HydratedDynamicToolCallData {
            namespace: None,
            tool: name.to_string(),
            status,
            duration_ms: None,
            success,
            arguments_json,
            content_summary: summary,
            display: None,
        }),
        source_turn_id: turn_id.map(str::to_string),
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: false,
    }
}

/// Carried-over rows get their own id space so they never collide with the
/// new thread's items.
fn carried_over_items(
    messages: &[crate::source::ExternalTranscriptMessage],
) -> Vec<HydratedConversationItem> {
    messages
        .iter()
        .map(|message| {
            let id = format!("carried:{}", message.id);
            match message.role {
                ExternalMessageRole::User => user_item(&id, &message.text, None),
                ExternalMessageRole::Assistant => assistant_item(&id, &message.text, None),
            }
        })
        .collect()
}

pub(crate) fn user_item(id: &str, text: &str, turn_id: Option<&str>) -> HydratedConversationItem {
    HydratedConversationItem {
        id: id.to_string(),
        content: HydratedConversationItemContent::User(HydratedUserMessageData {
            text: text.to_string(),
            image_data_uris: Vec::new(),
        }),
        source_turn_id: turn_id.map(str::to_string),
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: true,
    }
}

pub(crate) fn assistant_item(
    id: &str,
    text: &str,
    turn_id: Option<&str>,
) -> HydratedConversationItem {
    HydratedConversationItem {
        id: id.to_string(),
        content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
            text: text.to_string(),
            agent_nickname: None,
            agent_role: None,
            phase: None,
        }),
        source_turn_id: turn_id.map(str::to_string),
        source_turn_index: None,
        timestamp: None,
        is_from_user_turn_boundary: false,
    }
}

/// The fence question the learner owes an answer to, when the newest
/// learner-or-agent message is an agent message that asks one. Like Swift's
/// `CourseChatQuestionPolicy.pendingQuestion`, the raw message text is read,
/// so a question still parses when a plan fence before it was left open.
pub(crate) fn pending_fence_question(items: &[HydratedConversationItem]) -> Option<InputRequest> {
    let last = items.iter().rev().find(|item| {
        matches!(
            item.content,
            HydratedConversationItemContent::User(_)
                | HydratedConversationItemContent::Assistant(_)
        )
    })?;
    let HydratedConversationItemContent::Assistant(data) = &last.content else {
        return None;
    };
    let question = extract_question(&data.text).question?;
    Some(InputRequest::Question {
        id: format!("fence:{}", last.id),
        text: question.prompt,
        options: question.options,
    })
}

/// Everything a chat view needs, copied out under the store locks so the
/// timeline derivation runs without holding any of them.
pub(crate) struct ChatCapture {
    items: Vec<HydratedConversationItem>,
    pending_ids: HashSet<String>,
    pending_questions: Vec<PendingQuestionInput>,
    active_turn_id: Option<String>,
    phase: TurnPhase,
    timings: HashMap<String, TurnTiming>,
    connection: ConnectionPhase,
    progress_label: Option<String>,
    active_turn_started_at_ms: Option<i64>,
    seq: u64,
    user_row_aliases: HashMap<String, String>,
}

/// Snapshot facts about one app-server thread, read under the snapshot lock.
pub(crate) struct ThreadFacts<'a> {
    pub thread: &'a ThreadSnapshot,
    pub server: Option<&'a ServerSnapshot>,
    /// Ids of pending approvals and user-input requests for this thread.
    pub pending_request_ids: Vec<String>,
}

#[derive(Default)]
pub(crate) struct ChatHub {
    threads: Mutex<HashMap<ThreadKey, ChatThreadState>>,
    /// Number of tracked threads, read without the lock so the reducer's hot
    /// path skips all chat work while no chat is open.
    tracked: AtomicUsize,
}

impl ChatHub {
    fn lock(&self) -> MutexGuard<'_, HashMap<ThreadKey, ChatThreadState>> {
        self.threads.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn sync_tracked(&self, threads: &HashMap<ThreadKey, ChatThreadState>) {
        self.tracked.store(threads.len(), Ordering::Release);
    }

    fn with_state<R>(
        &self,
        key: &ThreadKey,
        default_kind: impl FnOnce() -> SourceKind,
        f: impl FnOnce(&mut ChatThreadState) -> R,
    ) -> R {
        let mut threads = self.lock();
        let state = threads
            .entry(key.clone())
            .or_insert_with(|| ChatThreadState::new(default_kind()));
        let result = f(state);
        if state.evict_when_resting && state.can_evict() {
            threads.remove(key);
        }
        self.sync_tracked(&threads);
        result
    }

    /// True when `key` has chat state (an open subscription, an outbox entry
    /// or a source-owned transcript). Lock-free when no chat state exists.
    pub(crate) fn is_tracked(&self, key: &ThreadKey) -> bool {
        self.tracked.load(Ordering::Acquire) > 0 && self.lock().contains_key(key)
    }

    fn any_tracked(&self) -> bool {
        self.tracked.load(Ordering::Acquire) > 0
    }

    /// Wakes subscribers of `key` after a canonical change the hub did not
    /// see as an event (thread upserts, item upserts, metadata).
    pub(crate) fn touch(&self, key: &ThreadKey) {
        if !self.any_tracked() {
            return;
        }
        if let Some(state) = self.lock().get_mut(key) {
            state.bump();
        }
    }

    pub(crate) fn touch_server(&self, server_id: &str) {
        if !self.any_tracked() {
            return;
        }
        for (key, state) in self.lock().iter_mut() {
            if key.server_id == server_id {
                state.bump();
            }
        }
    }

    pub(crate) fn touch_all(&self) {
        if !self.any_tracked() {
            return;
        }
        for state in self.lock().values_mut() {
            state.bump();
        }
    }

    /// The thread left the store: drop its chat state unless a chat is still
    /// open on it.
    pub(crate) fn remove_thread(&self, key: &ThreadKey) {
        if !self.any_tracked() {
            return;
        }
        let mut threads = self.lock();
        match threads.get_mut(key) {
            Some(state) if state.subscribers > 0 => state.bump(),
            Some(_) => {
                threads.remove(key);
            }
            None => {}
        }
        self.sync_tracked(&threads);
    }

    pub(crate) fn apply_events(
        &self,
        key: &ThreadKey,
        source_kind: SourceKind,
        events: &[SourceEvent],
        now: i64,
    ) {
        if events.is_empty() {
            return;
        }
        self.with_state(
            key,
            || source_kind,
            |state| {
                let mut changed = false;
                for event in events {
                    changed |= state.apply(event, now);
                }
                if changed {
                    state.bump();
                }
            },
        );
    }

    /// Like `apply_events`, for server-owned threads: does nothing unless the
    /// thread is tracked, so threads without an open chat cost nothing.
    pub(crate) fn apply_events_if_tracked(
        &self,
        key: &ThreadKey,
        events: &[SourceEvent],
        now: i64,
    ) {
        if events.is_empty() || !self.any_tracked() {
            return;
        }
        let mut threads = self.lock();
        let Some(state) = threads.get_mut(key) else {
            return;
        };
        let mut changed = false;
        for event in events {
            changed |= state.apply(event, now);
        }
        if changed {
            state.bump();
        }
        if state.evict_when_resting && state.can_evict() {
            threads.remove(key);
            self.sync_tracked(&threads);
        }
    }

    /// A bounded authoritative history query can recover a missed settle
    /// notification. Compare identities under the hub lock so an older page
    /// never settles a turn accepted after the query started.
    pub(crate) fn settle_matching_turn_if_tracked(
        &self,
        key: &ThreadKey,
        turn_id: &str,
        outcome: TurnOutcome,
        question: Option<InputRequest>,
        now: i64,
    ) {
        if !self.any_tracked() {
            return;
        }
        let mut threads = self.lock();
        let Some(state) = threads.get_mut(key) else {
            return;
        };
        if state.machine.active_turn_id() != Some(turn_id) {
            return;
        }
        let completed = outcome == TurnOutcome::Completed;
        let mut changed = state.apply(
            &SourceEvent::TurnSettled {
                turn_id: Some(turn_id.to_string()),
                outcome,
            },
            now,
        );
        if completed && let Some(request) = question {
            changed |= state.apply(&SourceEvent::InputRequested { request }, now);
        }
        if changed {
            state.bump();
        }
        if state.evict_when_resting && state.can_evict() {
            threads.remove(key);
            self.sync_tracked(&threads);
        }
    }

    pub(crate) fn apply_local(
        &self,
        key: &ThreadKey,
        source_kind: SourceKind,
        action: LocalAction,
    ) {
        let now = now_ms();
        self.with_state(
            key,
            || source_kind,
            |state| {
                if state.apply_local(&action, now) {
                    state.bump();
                }
            },
        );
    }

    pub(crate) fn apply_local_if_tracked(&self, key: &ThreadKey, action: LocalAction) {
        if !self.any_tracked() {
            return;
        }
        let now = now_ms();
        if let Some(state) = self.lock().get_mut(key)
            && state.apply_local(&action, now)
        {
            state.bump();
        }
    }

    /// An app-server overlay (`local_id`) was bound to `turn_id` in the
    /// snapshot; its row keeps the id it was shown with.
    pub(crate) fn bind_user_row_if_tracked(&self, key: &ThreadKey, turn_id: &str, local_id: &str) {
        if !self.any_tracked() {
            return;
        }
        if let Some(state) = self.lock().get_mut(key) {
            state.alias_user_row(turn_id, local_id);
        }
    }

    /// Stages an app-server learner message for a thread the snapshot does
    /// not know yet, so the bubble survives until the echo arrives.
    pub(crate) fn outbox_push(&self, key: &ThreadKey, item: HydratedConversationItem) {
        let now = now_ms();
        self.with_state(
            key,
            || SourceKind::app_server(""),
            |state| {
                state.pending_ids.insert(item.id.clone());
                state.outbox.retain(|existing| existing.id != item.id);
                state.outbox.push(item);
                state.apply_local(&LocalAction::Send, now);
                state.bump();
            },
        );
    }

    /// Drops an optimistic message that failed to send.
    pub(crate) fn outbox_fail(&self, key: &ThreadKey, item_id: &str) {
        if !self.any_tracked() {
            return;
        }
        let now = now_ms();
        let mut threads = self.lock();
        let Some(state) = threads.get_mut(key) else {
            return;
        };
        state.pending_ids.remove(item_id);
        state.outbox.retain(|item| item.id != item_id);
        if let Some(items) = state.owned.as_mut() {
            items.retain(|item| item.id != item_id);
        }
        state.apply_local(&LocalAction::SendFailed, now);
        state.bump();
        if state.can_evict() && state.owned.is_none() {
            threads.remove(key);
            self.sync_tracked(&threads);
        }
    }

    /// Registers a chat subscription.
    pub(crate) fn subscribe(
        &self,
        key: &ThreadKey,
        default_kind: SourceKind,
    ) -> watch::Receiver<u64> {
        self.with_state(
            key,
            || default_kind,
            |state| {
                state.subscribers += 1;
                state.evict_when_resting = false;
                state.notify.subscribe()
            },
        )
    }

    /// A chat subscription closed. The state goes once nothing needs it; a
    /// source-owned transcript with a running turn waits for the settle.
    pub(crate) fn unsubscribe(&self, key: &ThreadKey) {
        let mut threads = self.lock();
        let Some(state) = threads.get_mut(key) else {
            return;
        };
        state.subscribers = state.subscribers.saturating_sub(1);
        if state.subscribers == 0 {
            if state.can_evict() {
                threads.remove(key);
            } else {
                state.evict_when_resting = true;
            }
        }
        self.sync_tracked(&threads);
    }

    pub(crate) fn owned_pending_fence_question(&self, key: &ThreadKey) -> Option<InputRequest> {
        self.lock()
            .get(key)?
            .owned
            .as_deref()
            .and_then(pending_fence_question)
    }

    /// Replaces the history shown before an app-server thread's own items.
    pub(crate) fn set_carried_over(
        &self,
        key: &ThreadKey,
        source_kind: SourceKind,
        messages: &[crate::source::ExternalTranscriptMessage],
    ) {
        let items = carried_over_items(messages);
        self.with_state(
            key,
            || source_kind,
            |state| {
                if state.carried_over != items {
                    state.carried_over = items;
                    state.bump();
                }
            },
        );
    }

    pub(crate) fn owns_transcript(&self, key: &ThreadKey) -> bool {
        self.lock()
            .get(key)
            .is_some_and(|state| state.owned.is_some())
    }

    /// Converts platform-run source events into canonical events against the
    /// source-owned transcript.
    pub(crate) fn ingest_external(
        &self,
        key: &ThreadKey,
        source_kind: SourceKind,
        events: Vec<ExternalSourceEvent>,
        now: i64,
    ) {
        self.with_state(
            key,
            || source_kind,
            |state| {
                if state.owned.is_none() {
                    state.owned = Some(Vec::new());
                }
                let mut changed = false;
                for event in events {
                    changed |= ingest_one(state, event, now);
                }
                if changed {
                    state.bump();
                }
            },
        );
    }

    /// Replaces a source-owned transcript (hosted history reload). Ignored
    /// while a turn is live so a reload never clobbers streaming items.
    ///
    /// Items the server does not persist survive the reload: learner
    /// messages still waiting for acceptance and the "The agent stopped"
    /// notice of a failed turn (re-attached after that turn's last item).
    /// They live only as long as this chat state, so a chat reopened after
    /// its state was dropped shows what the server returns.
    pub(crate) fn replace_owned_transcript(
        &self,
        key: &ThreadKey,
        source_kind: SourceKind,
        items: Vec<HydratedConversationItem>,
    ) {
        self.with_state(
            key,
            || source_kind,
            |state| {
                if state.machine.phase().is_working() {
                    return;
                }
                let next = merge_unpersisted(
                    state.owned.as_deref().unwrap_or(&[]),
                    items,
                    &state.pending_ids,
                );
                if state.owned.as_ref() != Some(&next) {
                    state.owned = Some(next);
                    state.bump();
                }
            },
        );
    }

    /// Copies what a view needs under the hub lock. Callers hold the snapshot
    /// read lock (lock order: snapshot, then hub) while passing `facts`, so
    /// reconciliation sees a snapshot at least as new as the hub.
    pub(crate) fn capture(
        &self,
        key: &ThreadKey,
        facts: Option<ThreadFacts<'_>>,
        pending_questions: Vec<PendingQuestionInput>,
    ) -> ChatCapture {
        let now = now_ms();
        let default_kind = || match &facts {
            Some(facts) => SourceKind::app_server(&facts.thread.agent_runtime_kind),
            None if key.server_id == HOSTED_SERVER_ID => SourceKind::Hosted,
            None if key.server_id == APPLE_SERVER_ID => SourceKind::Apple,
            None => SourceKind::app_server(""),
        };
        self.with_state(key, default_kind, |state| {
            let (items, connection, active_turn_id, pending_ids) = match (&state.owned, &facts) {
                (Some(owned), _) => (
                    owned.clone(),
                    state.connection,
                    state.machine.active_turn_id().map(str::to_string),
                    state.pending_ids.clone(),
                ),
                (None, Some(facts)) => {
                    let thread = facts.thread;
                    state.source_kind = SourceKind::app_server(&thread.agent_runtime_kind);
                    reconcile_with_thread(state, thread, &facts.pending_request_ids, now);
                    let mut items = state.carried_over.clone();
                    items.extend(super::boundary::merged_hydrated_items(
                        &thread.items,
                        &thread.local_overlay_items,
                    ));
                    // Outbox entries the server echoed (or the store took
                    // over) are done.
                    let before = state.outbox.len();
                    state
                        .outbox
                        .retain(|entry| !outbox_entry_echoed(entry, &items));
                    if state.outbox.len() != before {
                        let outbox_ids: HashSet<&str> =
                            state.outbox.iter().map(|entry| entry.id.as_str()).collect();
                        state
                            .pending_ids
                            .retain(|id| outbox_ids.contains(id.as_str()));
                    }
                    items.extend(state.outbox.iter().cloned());
                    // Pending: outbox entries the source has not accepted, and
                    // optimistic overlays not yet bound to a turn.
                    let mut pending_ids = state.pending_ids.clone();
                    pending_ids.extend(
                        thread
                            .local_overlay_items
                            .iter()
                            .filter(|overlay| {
                                overlay.source_turn_id.is_none()
                                    && matches!(
                                        overlay.content,
                                        HydratedConversationItemContent::User(_)
                                    )
                            })
                            .map(|overlay| overlay.id.clone()),
                    );
                    let active = thread
                        .active_turn_id
                        .clone()
                        .or_else(|| state.machine.active_turn_id().map(str::to_string));
                    (
                        items,
                        app_server_connection(thread, facts.server),
                        active,
                        pending_ids,
                    )
                }
                (None, None) => (
                    state
                        .carried_over
                        .iter()
                        .chain(state.outbox.iter())
                        .cloned()
                        .collect(),
                    ConnectionPhase::Syncing,
                    state.machine.active_turn_id().map(str::to_string),
                    state.pending_ids.clone(),
                ),
            };
            ChatCapture {
                items,
                pending_ids,
                pending_questions,
                active_turn_id,
                phase: state.machine.phase().clone(),
                timings: state.machine.timings().clone(),
                connection,
                progress_label: state.machine.progress_label().map(str::to_string),
                active_turn_started_at_ms: state.machine.active_work_started_at_ms(),
                seq: state.seq,
                user_row_aliases: state.user_row_aliases.clone(),
            }
        })
    }

    /// Capture and derive in one call (tests and threads outside the
    /// snapshot).
    #[cfg(test)]
    pub(crate) fn view(
        &self,
        key: &ThreadKey,
        facts: Option<ThreadFacts<'_>>,
        options: &ChatViewOptions,
    ) -> ChatView {
        derive_view(self.capture(key, facts, Vec::new()), options)
    }
}

/// Builds the rows for a capture. Runs without any store lock.
pub(crate) fn derive_view(capture: ChatCapture, options: &ChatViewOptions) -> ChatView {
    let ChatCapture {
        items,
        pending_ids,
        pending_questions,
        active_turn_id,
        phase,
        timings,
        connection,
        progress_label,
        active_turn_started_at_ms,
        seq,
        user_row_aliases,
    } = capture;
    let streaming_item_id = if phase.is_working() {
        items
            .iter()
            .rev()
            .find(|item| matches!(item.content, HydratedConversationItemContent::Assistant(_)))
            .map(|item| item.id.clone())
    } else {
        None
    };
    let items = type_hermes_envelopes(items, streaming_item_id.as_deref());
    let items = if options.shows_internal_course_activity {
        items
    } else {
        project_course_items(items, options.hides_selection_envelope)
    };
    let mut rows = derive_rows(&TimelineInput {
        items: &items,
        pending_item_ids: &pending_ids,
        pending_questions: &pending_questions,
        active_turn_id: active_turn_id.as_deref(),
        phase: &phase,
        timings: &timings,
        user_row_aliases: &user_row_aliases,
    });
    if options.hides_plan_rows {
        rows.retain(|row| !matches!(row.kind, TimelineRowKind::Plan { .. }));
    }
    ChatView {
        rows,
        phase,
        connection,
        progress_label,
        active_turn_started_at_ms,
        seq,
    }
}

/// Items the hosted server does not persist, carried across a reload.
fn merge_unpersisted(
    current: &[HydratedConversationItem],
    reloaded: Vec<HydratedConversationItem>,
    pending_ids: &HashSet<String>,
) -> Vec<HydratedConversationItem> {
    let mut next = reloaded;
    for notice in current
        .iter()
        .filter(|item| item.id.starts_with(TURN_ERROR_ITEM_PREFIX))
    {
        if next.iter().any(|item| item.id == notice.id) {
            continue;
        }
        let Some(turn_id) = notice.source_turn_id.as_deref() else {
            continue;
        };
        if let Some(last) = next
            .iter()
            .rposition(|item| item.source_turn_id.as_deref() == Some(turn_id))
        {
            next.insert(last + 1, notice.clone());
        }
    }
    let pending: Vec<HydratedConversationItem> = current
        .iter()
        .filter(|item| {
            pending_ids.contains(&item.id) && !next.iter().any(|kept| kept.id == item.id)
        })
        .cloned()
        .collect();
    next.extend(pending);
    next
}

/// An outbox entry is done once the store holds it (the thread loaded with
/// the overlay) or the server echoed a learner message for the turn it was
/// bound to. Never matched by text: the learner may send the same words
/// twice.
fn outbox_entry_echoed(
    entry: &HydratedConversationItem,
    items: &[HydratedConversationItem],
) -> bool {
    if !matches!(entry.content, HydratedConversationItemContent::User(_)) {
        return true;
    }
    items.iter().any(|item| {
        item.id == entry.id
            || (entry.source_turn_id.is_some()
                && item.is_from_user_turn_boundary
                && item.source_turn_id == entry.source_turn_id
                && matches!(item.content, HydratedConversationItemContent::User(_)))
    })
}

fn app_server_connection(
    thread: &ThreadSnapshot,
    server: Option<&ServerSnapshot>,
) -> ConnectionPhase {
    let Some(server) = server else {
        return ConnectionPhase::Offline;
    };
    match server.health {
        ServerHealthSnapshot::Connected | ServerHealthSnapshot::Unknown(_) => {
            if thread.initial_turns_loaded || !thread.items.is_empty() {
                ConnectionPhase::Live
            } else {
                ConnectionPhase::Syncing
            }
        }
        ServerHealthSnapshot::Connecting | ServerHealthSnapshot::Unresponsive => {
            ConnectionPhase::Reconnecting
        }
        ServerHealthSnapshot::Disconnected => ConnectionPhase::Offline,
    }
}

/// Keeps the machine honest against the authoritative snapshot when events
/// were missed: reconnects, thread reads, and chats opened mid-turn (the
/// hub ignores app-server events for threads without an open chat).
fn reconcile_with_thread(
    state: &mut ChatThreadState,
    thread: &ThreadSnapshot,
    pending_request_ids: &[String],
    now: i64,
) {
    let mut changed = false;
    // Server requests answered while their resolution event was missed.
    let resolved: Vec<String> = state
        .pending_input_ids
        .iter()
        .filter(|id| !id.starts_with("fence:") && !pending_request_ids.contains(id))
        .cloned()
        .collect();
    for id in resolved {
        changed |= state.apply(&SourceEvent::InputResolved { id }, now);
    }
    match thread.active_turn_id.as_deref() {
        Some(turn_id) => {
            if matches!(
                state.machine.phase(),
                TurnPhase::Idle
                    | TurnPhase::Queued
                    | TurnPhase::Accepted
                    | TurnPhase::Settled { .. }
            ) {
                changed |= state.apply(
                    &SourceEvent::TurnStarted {
                        turn_id: turn_id.to_string(),
                    },
                    now,
                );
            }
            // Approvals and questions the server is waiting on.
            for id in pending_request_ids {
                if state.machine.phase().is_live_turn() && !state.pending_input_ids.contains(id) {
                    changed |= state.apply(
                        &SourceEvent::InputRequested {
                            request: InputRequest::Approval {
                                id: id.clone(),
                                title: String::new(),
                                detail: None,
                            },
                        },
                        now,
                    );
                }
            }
        }
        None => {
            let phase = state.machine.phase().clone();
            let running = matches!(
                phase,
                TurnPhase::Thinking
                    | TurnPhase::Streaming
                    | TurnPhase::Acting
                    | TurnPhase::Stopping
            );
            if running && thread.info.status != ThreadSummaryStatus::Active {
                let outcome = match (&phase, &thread.info.status) {
                    (TurnPhase::Stopping, _) => TurnOutcome::Interrupted,
                    (_, ThreadSummaryStatus::SystemError) => TurnOutcome::Failed {
                        message: "The agent stopped with an error.".to_string(),
                    },
                    _ => TurnOutcome::Completed,
                };
                changed |= state.apply(
                    &SourceEvent::TurnSettled {
                        turn_id: None,
                        outcome: outcome.clone(),
                    },
                    now,
                );
                if outcome == TurnOutcome::Completed
                    && let Some(request) = pending_fence_question(&thread.items)
                {
                    changed |= state.apply(&SourceEvent::InputRequested { request }, now);
                }
            } else if phase == TurnPhase::Idle
                && let Some(request) = pending_fence_question(&thread.items)
            {
                // A chat opened on a thread whose last reply asks a question.
                changed |= state.apply(&SourceEvent::InputRequested { request }, now);
            }
        }
    }
    if changed {
        state.bump();
    }
}

fn ingest_one(state: &mut ChatThreadState, event: ExternalSourceEvent, now: i64) -> bool {
    match event {
        ExternalSourceEvent::UserMessage {
            client_msg_id,
            text,
        } => {
            let items = state.owned.get_or_insert_with(Vec::new);
            items.retain(|item| item.id != client_msg_id);
            items.push(user_item(&client_msg_id, &text, None));
            state.pending_ids.insert(client_msg_id);
            state.apply_local(&LocalAction::Send, now);
            true
        }
        ExternalSourceEvent::UserMessageFailed { client_msg_id } => {
            state.withdraw_user_message(&client_msg_id);
            state.apply_local(&LocalAction::SendFailed, now);
            true
        }
        ExternalSourceEvent::TurnAccepted {
            client_msg_id,
            turn_id,
        } => state.apply(
            &SourceEvent::TurnAccepted {
                client_msg_id,
                turn_id,
            },
            now,
        ),
        ExternalSourceEvent::TurnStarted { turn_id } => {
            state.apply(&SourceEvent::TurnStarted { turn_id }, now)
        }
        ExternalSourceEvent::TextDelta {
            item_id,
            channel,
            text,
        } => state.apply(
            &SourceEvent::TextDelta {
                item_id,
                channel,
                text,
            },
            now,
        ),
        ExternalSourceEvent::TextSnapshot {
            item_id,
            channel,
            text,
        } => {
            let existing = state
                .owned
                .iter()
                .flatten()
                .find(|item| item.id == item_id)
                .and_then(item_text)
                .unwrap_or_default();
            if let Some(suffix) = text.strip_prefix(existing.as_str()) {
                if suffix.is_empty() {
                    return false;
                }
                return state.apply(
                    &SourceEvent::TextDelta {
                        item_id,
                        channel,
                        text: suffix.to_string(),
                    },
                    now,
                );
            }
            // The model rewrote earlier text: replace the item.
            let mut item = streamed_item(&item_id, channel, state.machine.active_turn_id());
            append_text(&mut item, channel, &text);
            state.apply(&SourceEvent::ItemUpdated { item }, now)
        }
        ExternalSourceEvent::ToolStarted {
            item_id,
            name,
            arguments_json,
        } => state.apply(
            &SourceEvent::ItemStarted {
                item: tool_item(
                    &item_id,
                    &name,
                    AppOperationStatus::InProgress,
                    arguments_json,
                    None,
                    None,
                    None,
                ),
            },
            now,
        ),
        ExternalSourceEvent::ToolCompleted {
            item_id,
            name,
            success,
            summary,
        } => {
            let arguments_json = state
                .owned
                .iter()
                .flatten()
                .find(|item| item.id == item_id)
                .and_then(|item| match &item.content {
                    HydratedConversationItemContent::DynamicToolCall(data) => {
                        data.arguments_json.clone()
                    }
                    _ => None,
                });
            state.apply(
                &SourceEvent::ItemCompleted {
                    item: tool_item(
                        &item_id,
                        &name,
                        if success {
                            AppOperationStatus::Completed
                        } else {
                            AppOperationStatus::Failed
                        },
                        arguments_json,
                        summary,
                        Some(success),
                        None,
                    ),
                },
                now,
            )
        }
        ExternalSourceEvent::Progress { label } => {
            state.apply(&SourceEvent::Progress { label }, now)
        }
        ExternalSourceEvent::StopRequested => state.apply_local(&LocalAction::Stop, now),
        ExternalSourceEvent::StopFailed => state.apply_local(&LocalAction::StopFailed, now),
        ExternalSourceEvent::TurnSettled { outcome } => {
            let settled_turn = state.machine.active_turn_id().map(str::to_string);
            let mut changed = state.apply(
                &SourceEvent::TurnSettled {
                    turn_id: settled_turn,
                    outcome: outcome.clone(),
                },
                now,
            );
            if outcome == TurnOutcome::Completed
                && let Some(request) = state.owned.as_deref().and_then(pending_fence_question)
            {
                changed |= state.apply(&SourceEvent::InputRequested { request }, now);
            }
            changed
        }
        ExternalSourceEvent::Connection { phase } => {
            state.apply(&SourceEvent::Connection { phase }, now)
        }
        ExternalSourceEvent::CarriedOverTranscript { .. } => {
            tracing::warn!(
                target: "store",
                "ignoring carried-over transcript for a platform-owned chat"
            );
            false
        }
        ExternalSourceEvent::ReplaceTranscript { messages } => {
            // The platform's copy lags a live turn (it is written when the
            // turn settles), so replacing now would drop streamed items.
            if state.machine.phase().is_working() {
                return false;
            }
            let items: Vec<HydratedConversationItem> = messages
                .iter()
                .map(|message| match message.role {
                    ExternalMessageRole::User => {
                        user_item(&message.id, &message.text, message.turn_id.as_deref())
                    }
                    ExternalMessageRole::Assistant => {
                        assistant_item(&message.id, &message.text, message.turn_id.as_deref())
                    }
                })
                .collect();
            // A pending message the platform restored is no longer pending.
            for item in &items {
                state.pending_ids.remove(&item.id);
            }
            let current = state.owned.take().unwrap_or_default();
            let next = merge_unpersisted(&current, items, &state.pending_ids);
            state.owned = Some(next);
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::TextChannel;

    fn key(server: &str) -> ThreadKey {
        ThreadKey {
            server_id: server.to_string(),
            thread_id: "session-1".to_string(),
        }
    }

    fn view(hub: &ChatHub, key: &ThreadKey) -> ChatView {
        hub.view(key, None, &ChatViewOptions::default())
    }

    #[test]
    fn apple_ingest_streams_text_and_settles_with_a_fold() {
        let hub = ChatHub::default();
        let key = key(APPLE_SERVER_ID);
        hub.ingest_external(
            &key,
            SourceKind::Apple,
            vec![ExternalSourceEvent::UserMessage {
                client_msg_id: "c1".into(),
                text: "Teach me OLED".into(),
            }],
            1_000,
        );
        let queued = view(&hub, &key);
        assert_eq!(queued.phase, TurnPhase::Queued);
        assert!(matches!(
            &queued.rows[0].kind,
            TimelineRowKind::User {
                delivery: crate::store::timeline::MessageDelivery::Pending,
                ..
            }
        ));

        hub.ingest_external(
            &key,
            SourceKind::Apple,
            vec![
                ExternalSourceEvent::TurnAccepted {
                    client_msg_id: Some("c1".into()),
                    turn_id: "t1".into(),
                },
                ExternalSourceEvent::TurnStarted {
                    turn_id: "t1".into(),
                },
                ExternalSourceEvent::TextSnapshot {
                    item_id: "a1".into(),
                    channel: TextChannel::Answer,
                    text: "OLED".into(),
                },
            ],
            2_000,
        );
        let streaming = view(&hub, &key);
        assert_eq!(streaming.phase, TurnPhase::Streaming);
        assert_eq!(streaming.rows[0].id, "user:c1");

        hub.ingest_external(
            &key,
            SourceKind::Apple,
            vec![ExternalSourceEvent::TextSnapshot {
                item_id: "a1".into(),
                channel: TextChannel::Answer,
                text: "OLED pixels".into(),
            }],
            2_500,
        );
        let grown = view(&hub, &key);
        let updates = diff_views(&streaming, &grown);
        assert_eq!(
            updates,
            vec![ChatUpdate::TextAppended {
                row_id: "answer:a1".into(),
                text: " pixels".into(),
                digest: grown.rows[1].digest,
                seq: grown.seq,
            }]
        );

        hub.ingest_external(
            &key,
            SourceKind::Apple,
            vec![
                ExternalSourceEvent::ToolStarted {
                    item_id: "tool-1".into(),
                    name: "search".into(),
                    arguments_json: None,
                },
                ExternalSourceEvent::ToolCompleted {
                    item_id: "tool-1".into(),
                    name: "search".into(),
                    success: true,
                    summary: None,
                },
                ExternalSourceEvent::TextDelta {
                    item_id: "a2".into(),
                    channel: TextChannel::Answer,
                    text: "Done.".into(),
                },
                ExternalSourceEvent::TurnSettled {
                    outcome: TurnOutcome::Completed,
                },
            ],
            6_000,
        );
        let settled = view(&hub, &key);
        assert_eq!(
            settled.phase,
            TurnPhase::Settled {
                outcome: TurnOutcome::Completed
            }
        );
        let ids: Vec<&str> = settled.rows.iter().map(|row| row.id.as_str()).collect();
        assert_eq!(
            ids,
            vec![
                "user:c1",
                "fold:t1",
                "answer:a1",
                "work:tool-1",
                "answer:a2"
            ]
        );
        assert!(matches!(
            &settled.rows[1].kind,
            TimelineRowKind::Fold { label, .. } if label == "Worked for 4.0s"
        ));
    }

    #[test]
    fn fence_question_after_settle_awaits_input_and_send_requeues() {
        let hub = ChatHub::default();
        let key = key(APPLE_SERVER_ID);
        hub.ingest_external(
            &key,
            SourceKind::Apple,
            vec![
                ExternalSourceEvent::UserMessage {
                    client_msg_id: "c1".into(),
                    text: "Hi".into(),
                },
                ExternalSourceEvent::TurnStarted {
                    turn_id: "t1".into(),
                },
                ExternalSourceEvent::TextDelta {
                    item_id: "a1".into(),
                    channel: TextChannel::Answer,
                    text: "Lead.\n\n```learnfold-question\nPace?\n- Slow\n- Fast\n```".into(),
                },
                ExternalSourceEvent::TurnSettled {
                    outcome: TurnOutcome::Completed,
                },
            ],
            1,
        );
        assert_eq!(view(&hub, &key).phase, TurnPhase::AwaitingInput);
        hub.ingest_external(
            &key,
            SourceKind::Apple,
            vec![ExternalSourceEvent::UserMessage {
                client_msg_id: "c2".into(),
                text: "Slow".into(),
            }],
            2,
        );
        let queued = view(&hub, &key);
        assert_eq!(queued.phase, TurnPhase::Queued);
        // Like Swift, only the question still owed an answer has a row.
        assert!(
            !queued
                .rows
                .iter()
                .any(|row| matches!(&row.kind, TimelineRowKind::Question { .. }))
        );
    }

    #[test]
    fn failed_send_removes_the_pending_bubble() {
        let hub = ChatHub::default();
        let key = key(APPLE_SERVER_ID);
        hub.ingest_external(
            &key,
            SourceKind::Apple,
            vec![ExternalSourceEvent::UserMessage {
                client_msg_id: "c1".into(),
                text: "Hi".into(),
            }],
            1,
        );
        hub.ingest_external(
            &key,
            SourceKind::Apple,
            vec![ExternalSourceEvent::UserMessageFailed {
                client_msg_id: "c1".into(),
            }],
            2,
        );
        let failed = view(&hub, &key);
        assert!(failed.rows.is_empty());
        assert_eq!(failed.phase, TurnPhase::Idle);
    }

    fn start_turn(hub: &ChatHub, key: &ThreadKey, kind: SourceKind, id: &str, now: i64) {
        hub.ingest_external(
            key,
            kind,
            vec![
                ExternalSourceEvent::UserMessage {
                    client_msg_id: id.into(),
                    text: format!("question {id}"),
                },
                ExternalSourceEvent::TurnAccepted {
                    client_msg_id: Some(id.into()),
                    turn_id: id.into(),
                },
                ExternalSourceEvent::TurnStarted { turn_id: id.into() },
            ],
            now,
        );
    }

    fn failed() -> TurnOutcome {
        TurnOutcome::Failed {
            message: "boom".into(),
        }
    }

    fn has_error_notice(view: &ChatView) -> bool {
        view.rows.iter().any(|row| {
            matches!(
                row.kind,
                TimelineRowKind::Notice {
                    tone: crate::store::timeline::NoticeTone::Error,
                    ..
                }
            )
        })
    }

    /// Settles the first turn with an answer, so a failed second turn has a
    /// previous turn its notice could wrongly attach to.
    fn completed_first_turn(hub: &ChatHub, key: &ThreadKey, kind: SourceKind) {
        start_turn(hub, key, kind.clone(), "c1", 1);
        hub.ingest_external(
            key,
            kind,
            vec![
                ExternalSourceEvent::TextSnapshot {
                    item_id: "a1".into(),
                    channel: TextChannel::Answer,
                    text: "Answer".into(),
                },
                ExternalSourceEvent::TurnSettled {
                    outcome: TurnOutcome::Completed,
                },
            ],
            2,
        );
    }

    #[test]
    fn withdrawn_message_before_failed_settle_leaves_no_notice() {
        let hub = ChatHub::default();
        let key = key(APPLE_SERVER_ID);
        completed_first_turn(&hub, &key, SourceKind::Apple);
        start_turn(&hub, &key, SourceKind::Apple, "c2", 3);
        hub.ingest_external(
            &key,
            SourceKind::Apple,
            vec![
                ExternalSourceEvent::UserMessageFailed {
                    client_msg_id: "c2".into(),
                },
                ExternalSourceEvent::TurnSettled { outcome: failed() },
            ],
            4,
        );
        let view = view(&hub, &key);
        let ids: Vec<&str> = view.rows.iter().map(|row| row.id.as_str()).collect();
        assert_eq!(ids, vec!["user:c1", "answer:a1"]);
        assert!(!has_error_notice(&view));
        assert!(matches!(view.phase, TurnPhase::Settled { .. }));
    }

    #[test]
    fn withdrawn_message_after_failed_settle_removes_its_notice() {
        // Hosted order: the adapter settles the turn as failed before the
        // platform restores the draft and withdraws the message.
        let hub = ChatHub::default();
        let key = key(HOSTED_SERVER_ID);
        completed_first_turn(&hub, &key, SourceKind::Hosted);
        start_turn(&hub, &key, SourceKind::Hosted, "c2", 3);
        hub.apply_events(
            &key,
            SourceKind::Hosted,
            &[SourceEvent::TurnSettled {
                turn_id: Some("c2".into()),
                outcome: failed(),
            }],
            4,
        );
        assert!(has_error_notice(&view(&hub, &key)));
        hub.ingest_external(
            &key,
            SourceKind::Hosted,
            vec![ExternalSourceEvent::UserMessageFailed {
                client_msg_id: "c2".into(),
            }],
            5,
        );
        let view = view(&hub, &key);
        let ids: Vec<&str> = view.rows.iter().map(|row| row.id.as_str()).collect();
        assert_eq!(ids, vec!["user:c1", "answer:a1"]);
        assert!(!has_error_notice(&view));
    }

    #[test]
    fn replace_transcript_is_ignored_during_a_live_turn() {
        let hub = ChatHub::default();
        let key = key(APPLE_SERVER_ID);
        start_turn(&hub, &key, SourceKind::Apple, "c1", 1);
        hub.ingest_external(
            &key,
            SourceKind::Apple,
            vec![ExternalSourceEvent::TextSnapshot {
                item_id: "a1".into(),
                channel: TextChannel::Answer,
                text: "Streaming".into(),
            }],
            2,
        );
        hub.ingest_external(
            &key,
            SourceKind::Apple,
            vec![ExternalSourceEvent::ReplaceTranscript { messages: vec![] }],
            3,
        );
        let view = view(&hub, &key);
        assert_eq!(view.phase, TurnPhase::Streaming);
        assert_eq!(view.rows.len(), 2);
    }

    #[test]
    fn connection_changes_only_touch_the_connection_axis() {
        let hub = ChatHub::default();
        let key = key(HOSTED_SERVER_ID);
        hub.apply_events(
            &key,
            SourceKind::Hosted,
            &[SourceEvent::TurnStarted {
                turn_id: "t1".into(),
            }],
            1,
        );
        let before = view(&hub, &key);
        hub.apply_events(
            &key,
            SourceKind::Hosted,
            &[SourceEvent::Connection {
                phase: ConnectionPhase::Reconnecting,
            }],
            2,
        );
        let after = view(&hub, &key);
        assert_eq!(after.phase, TurnPhase::Thinking);
        assert_eq!(
            diff_views(&before, &after),
            vec![ChatUpdate::ConnectionChanged {
                connection: ConnectionPhase::Reconnecting,
                seq: after.seq,
            }]
        );
    }

    #[test]
    fn subscribers_are_woken_by_sequence_bumps() {
        let hub = ChatHub::default();
        let key = key(HOSTED_SERVER_ID);
        let mut rx = hub.subscribe(&key, SourceKind::Hosted);
        let start = *rx.borrow_and_update();
        hub.apply_events(
            &key,
            SourceKind::Hosted,
            &[SourceEvent::TextDelta {
                item_id: "a".into(),
                channel: TextChannel::Answer,
                text: "x".into(),
            }],
            1,
        );
        assert!(rx.has_changed().expect("sender alive"));
        assert!(*rx.borrow_and_update() > start);
    }

    #[test]
    fn large_churn_resyncs_with_a_snapshot() {
        let hub = ChatHub::default();
        let key = key(APPLE_SERVER_ID);
        let empty = view(&hub, &key);
        let messages = (0..200)
            .map(|index| crate::source::ExternalTranscriptMessage {
                id: format!("m{index}"),
                role: if index % 2 == 0 {
                    ExternalMessageRole::User
                } else {
                    ExternalMessageRole::Assistant
                },
                text: format!("message {index}"),
                turn_id: Some(format!("t{}", index / 2)),
            })
            .collect();
        hub.ingest_external(
            &key,
            SourceKind::Apple,
            vec![ExternalSourceEvent::ReplaceTranscript { messages }],
            1,
        );
        let full = view(&hub, &key);
        let updates = diff_views(&empty, &full);
        assert_eq!(updates.len(), 1);
        assert!(matches!(&updates[0], ChatUpdate::Snapshot { rows, .. } if rows.len() == 200));
    }
    #[test]
    fn turn_start_response_after_a_fast_failure_binds_without_reviving() {
        let hub = ChatHub::default();
        let key = key("srv");
        hub.outbox_push(&key, user_item("local-user-message:1", "Hi", None));
        assert_eq!(view(&hub, &key).phase, TurnPhase::Queued);
        let kind = || SourceKind::app_server("codex");
        hub.apply_events(
            &key,
            kind(),
            &[
                SourceEvent::TurnStarted {
                    turn_id: "t1".into(),
                },
                SourceEvent::TurnSettled {
                    turn_id: Some("t1".into()),
                    outcome: TurnOutcome::Failed {
                        message: "quota".into(),
                    },
                },
            ],
            2,
        );
        // turn/start's response is handled after the notifications.
        hub.apply_events(
            &key,
            kind(),
            &[SourceEvent::TurnAccepted {
                client_msg_id: Some("local-user-message:1".into()),
                turn_id: "t1".into(),
            }],
            3,
        );
        let settled = view(&hub, &key);
        assert!(matches!(
            settled.phase,
            TurnPhase::Settled {
                outcome: TurnOutcome::Failed { .. }
            }
        ));
        assert_eq!(settled.rows[0].id, "user:local-user-message:1");
        assert!(matches!(
            &settled.rows[0].kind,
            TimelineRowKind::User {
                delivery: crate::store::timeline::MessageDelivery::Sent,
                ..
            }
        ));
    }

    fn carried(
        id: &str,
        role: ExternalMessageRole,
        text: &str,
    ) -> crate::source::ExternalTranscriptMessage {
        crate::source::ExternalTranscriptMessage {
            id: id.into(),
            role,
            text: text.into(),
            turn_id: None,
        }
    }

    fn rebuilt_thread(key: &ThreadKey) -> crate::store::snapshot::ThreadSnapshot {
        let mut thread = crate::store::snapshot::ThreadSnapshot::from_info(
            &key.server_id,
            crate::types::ThreadInfo {
                id: key.thread_id.clone(),
                title: None,
                model: None,
                status: crate::types::ThreadSummaryStatus::Idle,
                preview: None,
                cwd: None,
                path: None,
                model_provider: None,
                agent_nickname: None,
                agent_role: None,
                parent_thread_id: None,
                forked_from_id: None,
                agent_status: None,
                created_at: None,
                updated_at: None,
            },
        );
        thread.items = vec![
            user_item("u2", "Telomeres shorten", Some("t2")),
            assistant_item("a2", "Good start", Some("t2")),
        ];
        thread
    }

    #[test]
    fn carried_over_transcript_precedes_a_rebuilt_app_server_thread() {
        // A Codex thread rebuilt after its rollout was lost holds only the new
        // turns; the conversation the learner already saw stays above them.
        let reducer = crate::store::AppStoreReducer::new();
        let key = key("srv");
        reducer.upsert_thread_snapshot(rebuilt_thread(&key));
        let _rx = reducer.chat_subscribe(&key);
        let carry = || {
            vec![ExternalSourceEvent::CarriedOverTranscript {
                messages: vec![
                    carried("m0", ExternalMessageRole::User, "Hey there"),
                    carried(
                        "m1",
                        ExternalMessageRole::Assistant,
                        "What would you like to learn?",
                    ),
                ],
            }]
        };
        reducer.chat_ingest_external(&key, SourceKind::app_server("codex"), carry());
        // The platform re-sends it whenever the chat reopens.
        reducer.chat_ingest_external(&key, SourceKind::app_server("codex"), carry());

        let view = reducer.chat_view(&key, &ChatViewOptions::default());
        let ids: Vec<&str> = view.rows.iter().map(|row| row.id.as_str()).collect();
        assert_eq!(
            ids,
            vec![
                "user:carried:m0",
                "answer:carried:m1",
                "user:turn:t2",
                "answer:a2"
            ]
        );
        assert!(!reducer.chat.owns_transcript(&key));
    }

    #[test]
    fn progress_for_an_unloaded_app_server_thread_never_creates_a_transcript() {
        let reducer = crate::store::AppStoreReducer::new();
        let key = key("srv");
        let _rx = reducer.chat_subscribe(&key);
        reducer.chat_ingest_external(
            &key,
            SourceKind::app_server("hermes"),
            vec![ExternalSourceEvent::Progress {
                label: Some("Retrying tool".into()),
            }],
        );
        assert!(!reducer.chat.owns_transcript(&key));
        assert_eq!(
            reducer
                .chat_view(&key, &ChatViewOptions::default())
                .progress_label
                .as_deref(),
            Some("Retrying tool")
        );
    }
}
