//! One answer to "what is the agent doing?".
//!
//! `TurnPhase` replaces the provider-specific state holders that each decided
//! whether a chat was "working" (`ThreadSummaryStatus`, `active_turn_id`,
//! Swift's run phase, request lifecycle, hosted progress and Hermes recovery
//! progress). Every source feeds the same [`SourceEvent`]s through [`next`],
//! so no view needs a provider branch to pick an indicator.
//!
//! Connection health is a separate axis ([`ConnectionPhase`]). A
//! `Connection` event never changes the turn phase, so "reconnecting" can
//! never be mistaken for "thinking".

use std::collections::{HashMap, HashSet};

use crate::conversation_uniffi::{HydratedConversationItem, HydratedConversationItemContent};
use crate::source::{SourceEvent, TextChannel, TurnOutcome};

/// The phase of the current (or most recent) turn in one thread.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
pub enum TurnPhase {
    /// Nothing has happened in this thread since it was opened.
    Idle,
    /// The learner sent a message; the source has not acknowledged it.
    Queued,
    /// The source acknowledged the message; no turn activity yet.
    Accepted,
    /// A turn is running and the agent is reasoning or waiting on the model.
    Thinking,
    /// Answer (or plan) text is growing.
    Streaming,
    /// A tool, command, search or file change is running.
    Acting,
    /// The agent asked a question or needs an approval; the card owns the
    /// composer.
    AwaitingInput,
    /// The learner asked to stop; waiting for the source to settle.
    Stopping,
    /// The turn finished.
    Settled { outcome: TurnOutcome },
}

impl TurnPhase {
    /// True while the agent is doing work the learner is waiting on.
    pub fn is_working(&self) -> bool {
        matches!(
            self,
            Self::Queued
                | Self::Accepted
                | Self::Thinking
                | Self::Streaming
                | Self::Acting
                | Self::Stopping
        )
    }

    /// True when a turn is running at the source.
    pub fn is_live_turn(&self) -> bool {
        matches!(self, Self::Thinking | Self::Streaming | Self::Acting)
    }

    fn is_resting(&self) -> bool {
        matches!(self, Self::Idle | Self::Settled { .. })
    }
}

/// Actions that originate on the device rather than at the source.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LocalAction {
    /// The learner sent a message (optimistic outbox entry created).
    Send,
    /// The learner pressed stop.
    Stop,
    /// Sending failed before the source accepted the message; the draft is
    /// restored.
    SendFailed,
    /// The stop request itself failed (for example the interrupt RPC
    /// errored); the turn keeps running, so leave `Stopping`.
    StopFailed,
}

/// Pure transition for source events.
pub fn next(phase: &TurnPhase, event: &SourceEvent) -> TurnPhase {
    use TurnPhase as P;
    let current = phase.clone();
    // Stopping holds until the source settles; nothing but a settle (or a
    // connection change, which never touches the phase) may move it.
    if matches!(phase, P::Stopping) && !matches!(event, SourceEvent::TurnSettled { .. }) {
        return current;
    }
    match event {
        SourceEvent::Connection { .. } => current,
        SourceEvent::TurnAccepted { .. } => match phase {
            P::Idle | P::Queued | P::Settled { .. } => P::Accepted,
            _ => current,
        },
        SourceEvent::TurnStarted { .. } => match phase {
            P::Idle | P::Queued | P::Accepted | P::Settled { .. } | P::AwaitingInput => P::Thinking,
            _ => current,
        },
        SourceEvent::TextDelta { channel, .. } => {
            // A late delta must not revive a settled turn.
            if matches!(phase, P::Settled { .. }) {
                return current;
            }
            match channel {
                TextChannel::Answer | TextChannel::Plan => P::Streaming,
                TextChannel::Reasoning => P::Thinking,
            }
        }
        SourceEvent::ItemStarted { item } => {
            if matches!(phase, P::Settled { .. }) {
                return current;
            }
            match item_activity(item) {
                ItemActivity::Tool => P::Acting,
                ItemActivity::Answer => P::Streaming,
                ItemActivity::Reasoning => P::Thinking,
                ItemActivity::Other => current,
            }
        }
        SourceEvent::ItemUpdated { .. } => current,
        SourceEvent::ItemCompleted { item } => match (phase, item_activity(item)) {
            (P::Acting, ItemActivity::Tool) => P::Thinking,
            _ => current,
        },
        SourceEvent::InputRequested { .. } => P::AwaitingInput,
        SourceEvent::InputResolved { .. } => match phase {
            P::AwaitingInput => P::Thinking,
            _ => current,
        },
        SourceEvent::Progress { .. } => current,
        SourceEvent::TurnSettled { outcome, .. } => P::Settled {
            outcome: outcome.clone(),
        },
    }
}

/// Pure transition for device-originated actions.
pub fn next_local(phase: &TurnPhase, action: &LocalAction) -> TurnPhase {
    use TurnPhase as P;
    match action {
        LocalAction::Send => match phase {
            P::Idle | P::Settled { .. } | P::AwaitingInput => P::Queued,
            // Sending while a turn runs queues or steers a follow-up; the
            // running turn still decides the phase.
            _ => phase.clone(),
        },
        LocalAction::Stop => match phase {
            P::Queued | P::Accepted | P::Thinking | P::Streaming | P::Acting | P::AwaitingInput => {
                P::Stopping
            }
            _ => phase.clone(),
        },
        LocalAction::SendFailed => match phase {
            P::Queued | P::Accepted => P::Idle,
            _ => phase.clone(),
        },
        // `TurnMachine` restores the phase the turn reached while stopping;
        // the pure table can only fall back to "still working".
        LocalAction::StopFailed => match phase {
            P::Stopping => P::Thinking,
            _ => phase.clone(),
        },
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ItemActivity {
    Tool,
    Answer,
    Reasoning,
    Other,
}

fn item_activity(item: &HydratedConversationItem) -> ItemActivity {
    use HydratedConversationItemContent as C;
    match &item.content {
        C::CommandExecution(_)
        | C::FileChange(_)
        | C::McpToolCall(_)
        | C::DynamicToolCall(_)
        | C::MultiAgentAction(_)
        | C::WebSearch(_)
        | C::ImageGeneration(_)
        | C::Widget(_) => ItemActivity::Tool,
        C::Assistant(_) | C::ProposedPlan(_) => ItemActivity::Answer,
        C::Reasoning(_) => ItemActivity::Reasoning,
        _ => ItemActivity::Other,
    }
}

/// A tool item that arrives already finished (for example a replayed
/// `ItemStarted` of a completed command) never counts as running.
fn is_finished_tool(item: &HydratedConversationItem) -> bool {
    use crate::types::AppOperationStatus as S;
    use HydratedConversationItemContent as C;
    let status = match &item.content {
        C::CommandExecution(data) => data.status,
        C::FileChange(data) => data.status,
        C::McpToolCall(data) => data.status,
        C::DynamicToolCall(data) => data.status,
        C::MultiAgentAction(data) => data.status,
        C::ImageGeneration(data) => data.status,
        C::WebSearch(data) => {
            return !data.is_in_progress;
        }
        C::Widget(data) => {
            return data.is_finalized;
        }
        _ => return false,
    };
    matches!(status, S::Completed | S::Failed | S::Declined)
}

/// Timing for one turn. Recorded once when the event arrives, so values that
/// derive from it (the "Worked for 9s" fold) never change afterwards.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TurnTiming {
    pub requested_at_ms: Option<i64>,
    pub started_at_ms: Option<i64>,
    pub settled_at_ms: Option<i64>,
}

impl TurnTiming {
    /// Settled duration, or `None` when the start was never observed.
    pub fn duration_ms(&self) -> Option<u64> {
        let start = self.started_at_ms.or(self.requested_at_ms)?;
        let end = self.settled_at_ms?;
        Some(end.saturating_sub(start).max(0) as u64)
    }
}

/// Per-thread machine: the pure phase plus the turn identity and timings the
/// timeline needs. `now_ms` is passed in so tests stay deterministic.
#[derive(Debug, Clone)]
pub struct TurnMachine {
    phase: TurnPhase,
    active_turn_id: Option<String>,
    /// Set by `Send`/`TurnAccepted` before a turn id exists.
    pending_request_at_ms: Option<i64>,
    progress_label: Option<String>,
    timings: HashMap<String, TurnTiming>,
    /// While `Stopping`: the phase the turn would be in had stop not been
    /// pressed, restored by `StopFailed`.
    resume_phase: Option<TurnPhase>,
    /// Tool items of the current turn that started and have not completed.
    /// `Acting` holds until every one finishes.
    running_tools: HashSet<String>,
}

impl Default for TurnMachine {
    fn default() -> Self {
        Self::new(TurnPhase::Idle)
    }
}

impl TurnMachine {
    pub fn new(phase: TurnPhase) -> Self {
        Self {
            phase,
            active_turn_id: None,
            pending_request_at_ms: None,
            progress_label: None,
            timings: HashMap::new(),
            resume_phase: None,
            running_tools: HashSet::new(),
        }
    }

    pub fn phase(&self) -> &TurnPhase {
        &self.phase
    }

    pub fn active_turn_id(&self) -> Option<&str> {
        self.active_turn_id.as_deref()
    }

    pub fn progress_label(&self) -> Option<&str> {
        self.progress_label.as_deref()
    }

    pub fn timings(&self) -> &HashMap<String, TurnTiming> {
        &self.timings
    }

    /// When the working indicator should start counting from. Mirrors
    /// t3code's `deriveActiveWorkStartedAt`: the request time is the floor
    /// until the source reports the turn start.
    pub fn active_work_started_at_ms(&self) -> Option<i64> {
        if !self.phase.is_working() && !matches!(self.phase, TurnPhase::AwaitingInput) {
            return None;
        }
        self.active_turn_id
            .as_deref()
            .and_then(|turn_id| self.timings.get(turn_id))
            .and_then(|timing| timing.started_at_ms.or(timing.requested_at_ms))
            .or(self.pending_request_at_ms)
    }

    fn is_turn_settled(&self, turn_id: &str) -> bool {
        self.timings
            .get(turn_id)
            .is_some_and(|timing| timing.settled_at_ms.is_some())
    }

    /// True for an event about a turn that already settled and must not move
    /// the machine: a turn/start response (`TurnAccepted`) or a replayed
    /// `TurnStarted` arriving after that turn's completion, or a duplicate
    /// settle of an old turn while a newer one runs.
    pub fn is_stale(&self, event: &SourceEvent) -> bool {
        match event {
            SourceEvent::TurnAccepted { turn_id, .. } | SourceEvent::TurnStarted { turn_id } => {
                matches!(self.phase, TurnPhase::Settled { .. }) && self.is_turn_settled(turn_id)
            }
            SourceEvent::TurnSettled {
                turn_id: Some(turn_id),
                ..
            } => {
                self.is_turn_settled(turn_id)
                    && self
                        .active_turn_id
                        .as_deref()
                        .is_some_and(|active| active != turn_id)
            }
            _ => false,
        }
    }

    /// Applies a source event. Returns true when anything observable changed.
    pub fn apply(&mut self, event: &SourceEvent, now_ms: i64) -> bool {
        if self.is_stale(event) {
            return false;
        }
        let before_phase = self.phase.clone();
        let before_turn = self.active_turn_id.clone();
        let before_label = self.progress_label.clone();
        let mut timing_changed = false;

        match event {
            SourceEvent::TurnAccepted { turn_id, .. } => {
                if self.phase.is_resting() || matches!(self.phase, TurnPhase::Queued) {
                    let requested = self.pending_request_at_ms.unwrap_or(now_ms);
                    let timing = self.timings.entry(turn_id.clone()).or_default();
                    if timing.requested_at_ms.is_none() {
                        timing.requested_at_ms = Some(requested);
                        timing_changed = true;
                    }
                    self.active_turn_id = Some(turn_id.clone());
                }
            }
            SourceEvent::TurnStarted { turn_id } => {
                // While stopping, only the turn being stopped may be recorded.
                if !matches!(self.phase, TurnPhase::Stopping)
                    || self.active_turn_id.as_deref() == Some(turn_id.as_str())
                {
                    let requested = self.pending_request_at_ms;
                    let timing = self.timings.entry(turn_id.clone()).or_default();
                    if timing.started_at_ms.is_none() {
                        timing.started_at_ms = Some(now_ms);
                        timing_changed = true;
                    }
                    if timing.requested_at_ms.is_none() {
                        timing.requested_at_ms = requested;
                    }
                    if self.active_turn_id.as_deref() != Some(turn_id.as_str()) {
                        self.running_tools.clear();
                        self.progress_label = None;
                    }
                    self.active_turn_id = Some(turn_id.clone());
                    self.pending_request_at_ms = None;
                }
            }
            SourceEvent::TurnSettled { turn_id, .. } => {
                self.running_tools.clear();
                let settled_turn = turn_id.clone().or_else(|| self.active_turn_id.clone());
                if let Some(turn_id) = settled_turn {
                    let timing = self.timings.entry(turn_id).or_default();
                    if timing.settled_at_ms.is_none() {
                        timing.settled_at_ms = Some(now_ms);
                        timing_changed = true;
                    }
                }
                self.active_turn_id = None;
                self.pending_request_at_ms = None;
                self.progress_label = None;
            }
            SourceEvent::Progress { label } => {
                self.progress_label = label.clone().filter(|label| !label.trim().is_empty());
            }
            SourceEvent::TextDelta { .. } => {
                if !matches!(self.phase, TurnPhase::Settled { .. }) {
                    self.progress_label = None;
                }
            }
            SourceEvent::ItemStarted { item }
            | SourceEvent::ItemUpdated { item }
            | SourceEvent::ItemCompleted { item } => {
                if !matches!(self.phase, TurnPhase::Settled { .. }) {
                    if item
                        .source_turn_id
                        .as_deref()
                        .is_none_or(|turn_id| self.active_turn_id.as_deref() == Some(turn_id))
                    {
                        self.progress_label = None;
                    }
                    if matches!(event, SourceEvent::ItemStarted { .. })
                        && item_activity(item) == ItemActivity::Tool
                        && !is_finished_tool(item)
                    {
                        self.running_tools.insert(item.id.clone());
                    }
                }
                if matches!(event, SourceEvent::ItemCompleted { .. })
                    && item_activity(item) == ItemActivity::Tool
                {
                    self.running_tools.remove(&item.id);
                }
            }
            _ => {}
        }

        if matches!(self.phase, TurnPhase::Stopping) {
            if matches!(event, SourceEvent::TurnSettled { .. }) {
                self.resume_phase = None;
            } else if let Some(resume) = self.resume_phase.as_ref() {
                self.resume_phase = Some(next(resume, event));
            }
        }
        self.phase = next(&self.phase, event);
        // Parallel tools: one finishing does not end the acting phase.
        if matches!(event, SourceEvent::ItemCompleted { .. })
            && before_phase == TurnPhase::Acting
            && self.phase == TurnPhase::Thinking
            && !self.running_tools.is_empty()
        {
            self.phase = TurnPhase::Acting;
        }
        timing_changed
            || before_phase != self.phase
            || before_turn != self.active_turn_id
            || before_label != self.progress_label
    }

    /// Applies a device action. Returns true when the phase changed.
    pub fn apply_local(&mut self, action: &LocalAction, now_ms: i64) -> bool {
        let before = self.phase.clone();
        self.phase = next_local(&self.phase, action);
        match action {
            LocalAction::Stop if matches!(self.phase, TurnPhase::Stopping) && before != self.phase => {
                self.resume_phase = Some(before.clone());
            }
            LocalAction::StopFailed if matches!(before, TurnPhase::Stopping) => {
                if let Some(resume) = self.resume_phase.take() {
                    self.phase = resume;
                }
            }
            LocalAction::Send if matches!(self.phase, TurnPhase::Queued) && before != self.phase => {
                self.pending_request_at_ms = Some(now_ms);
                self.progress_label = None;
            }
            LocalAction::SendFailed if matches!(self.phase, TurnPhase::Idle) => {
                self.pending_request_at_ms = None;
                self.active_turn_id = None;
            }
            _ => {}
        }
        before != self.phase
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversation_uniffi::{
        HydratedAssistantMessageData, HydratedCommandExecutionData, HydratedReasoningData,
        HydratedUserMessageData,
    };
    use crate::source::{ConnectionPhase, InputRequest};
    use crate::types::AppOperationStatus;

    fn item(content: HydratedConversationItemContent) -> HydratedConversationItem {
        HydratedConversationItem {
            id: "item".into(),
            content,
            source_turn_id: Some("t".into()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    fn tool() -> HydratedConversationItem {
        item(HydratedConversationItemContent::CommandExecution(
            HydratedCommandExecutionData {
                command: "ls".into(),
                cwd: "/".into(),
                status: AppOperationStatus::InProgress,
                output: None,
                exit_code: None,
                duration_ms: None,
                process_id: None,
                actions: vec![],
            },
        ))
    }

    fn answer() -> HydratedConversationItem {
        item(HydratedConversationItemContent::Assistant(
            HydratedAssistantMessageData {
                text: "hi".into(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            },
        ))
    }

    fn reasoning() -> HydratedConversationItem {
        item(HydratedConversationItemContent::Reasoning(
            HydratedReasoningData {
                summary: vec![],
                content: vec![],
            },
        ))
    }

    fn user() -> HydratedConversationItem {
        item(HydratedConversationItemContent::User(HydratedUserMessageData {
            text: "hello".into(),
            image_data_uris: vec![],
        }))
    }

    fn all_phases() -> Vec<TurnPhase> {
        vec![
            TurnPhase::Idle,
            TurnPhase::Queued,
            TurnPhase::Accepted,
            TurnPhase::Thinking,
            TurnPhase::Streaming,
            TurnPhase::Acting,
            TurnPhase::AwaitingInput,
            TurnPhase::Stopping,
            TurnPhase::Settled {
                outcome: TurnOutcome::Completed,
            },
        ]
    }

    fn short(phase: &TurnPhase) -> &'static str {
        match phase {
            TurnPhase::Idle => "idle",
            TurnPhase::Queued => "queued",
            TurnPhase::Accepted => "accepted",
            TurnPhase::Thinking => "thinking",
            TurnPhase::Streaming => "streaming",
            TurnPhase::Acting => "acting",
            TurnPhase::AwaitingInput => "awaiting",
            TurnPhase::Stopping => "stopping",
            TurnPhase::Settled { outcome } => match outcome {
                TurnOutcome::Completed => "settled",
                TurnOutcome::Interrupted => "stopped",
                TurnOutcome::Failed { .. } => "failed",
            },
        }
    }

    /// Every event, in the table's column order.
    fn events() -> Vec<(&'static str, SourceEvent)> {
        vec![
            (
                "accepted",
                SourceEvent::TurnAccepted {
                    client_msg_id: Some("c".into()),
                    turn_id: "t".into(),
                },
            ),
            (
                "started",
                SourceEvent::TurnStarted {
                    turn_id: "t".into(),
                },
            ),
            (
                "answer",
                SourceEvent::TextDelta {
                    item_id: "a".into(),
                    channel: TextChannel::Answer,
                    text: "x".into(),
                },
            ),
            (
                "reason",
                SourceEvent::TextDelta {
                    item_id: "r".into(),
                    channel: TextChannel::Reasoning,
                    text: "x".into(),
                },
            ),
            (
                "plan",
                SourceEvent::TextDelta {
                    item_id: "p".into(),
                    channel: TextChannel::Plan,
                    text: "x".into(),
                },
            ),
            ("toolStart", SourceEvent::ItemStarted { item: tool() }),
            ("ansStart", SourceEvent::ItemStarted { item: answer() }),
            ("reasStart", SourceEvent::ItemStarted { item: reasoning() }),
            ("userStart", SourceEvent::ItemStarted { item: user() }),
            ("update", SourceEvent::ItemUpdated { item: tool() }),
            ("toolDone", SourceEvent::ItemCompleted { item: tool() }),
            ("ansDone", SourceEvent::ItemCompleted { item: answer() }),
            (
                "input",
                SourceEvent::InputRequested {
                    request: InputRequest::Question {
                        id: "q".into(),
                        text: "?".into(),
                        options: vec!["a".into(), "b".into()],
                    },
                },
            ),
            ("resolved", SourceEvent::InputResolved { id: "q".into() }),
            (
                "progress",
                SourceEvent::Progress {
                    label: Some("Waiting on model".into()),
                },
            ),
            (
                "done",
                SourceEvent::TurnSettled {
                    turn_id: None,
                    outcome: TurnOutcome::Completed,
                },
            ),
            (
                "stopped",
                SourceEvent::TurnSettled {
                    turn_id: None,
                    outcome: TurnOutcome::Interrupted,
                },
            ),
            (
                "fail",
                SourceEvent::TurnSettled {
                    turn_id: None,
                    outcome: TurnOutcome::Failed {
                        message: "boom".into(),
                    },
                },
            ),
        ]
    }

    /// Exhaustive table: row = starting phase, column = event (in the order
    /// of `events()`), cell = resulting phase.
    #[test]
    fn transition_table_is_exhaustive() {
        #[rustfmt::skip]
        let expected: [(&str, [&str; 18]); 9] = [
            //            accepted    started     answer       reason      plan         toolStart ansStart     reasStart   userStart   update      toolDone    ansDone     input       resolved    progress    done       stopped    fail
            ("idle",     ["accepted", "thinking", "streaming", "thinking", "streaming", "acting", "streaming", "thinking", "idle",     "idle",     "idle",     "idle",     "awaiting", "idle",     "idle",     "settled", "stopped", "failed"]),
            ("queued",   ["accepted", "thinking", "streaming", "thinking", "streaming", "acting", "streaming", "thinking", "queued",   "queued",   "queued",   "queued",   "awaiting", "queued",   "queued",   "settled", "stopped", "failed"]),
            ("accepted", ["accepted", "thinking", "streaming", "thinking", "streaming", "acting", "streaming", "thinking", "accepted", "accepted", "accepted", "accepted", "awaiting", "accepted", "accepted", "settled", "stopped", "failed"]),
            ("thinking", ["thinking", "thinking", "streaming", "thinking", "streaming", "acting", "streaming", "thinking", "thinking", "thinking", "thinking", "thinking", "awaiting", "thinking", "thinking", "settled", "stopped", "failed"]),
            ("streaming",["streaming","streaming","streaming", "thinking", "streaming", "acting", "streaming", "thinking", "streaming","streaming","streaming","streaming","awaiting", "streaming","streaming","settled", "stopped", "failed"]),
            ("acting",   ["acting",   "acting",   "streaming", "thinking", "streaming", "acting", "streaming", "thinking", "acting",   "acting",   "thinking", "acting",   "awaiting", "acting",   "acting",   "settled", "stopped", "failed"]),
            ("awaiting", ["awaiting", "thinking", "streaming", "thinking", "streaming", "acting", "streaming", "thinking", "awaiting", "awaiting", "awaiting", "awaiting", "awaiting", "thinking", "awaiting", "settled", "stopped", "failed"]),
            ("stopping", ["stopping", "stopping", "stopping",  "stopping", "stopping",  "stopping","stopping", "stopping", "stopping", "stopping", "stopping", "stopping", "stopping", "stopping", "stopping", "settled", "stopped", "failed"]),
            ("settled",  ["accepted", "thinking", "settled",   "settled",  "settled",   "settled","settled",   "settled",  "settled",  "settled",  "settled",  "settled",  "awaiting", "settled",  "settled",  "settled", "stopped", "failed"]),
        ];
        let events = events();
        let phases = all_phases();
        assert_eq!(phases.len(), expected.len());
        for (phase, (row_name, row)) in phases.iter().zip(expected.iter()) {
            assert_eq!(short(phase), *row_name);
            assert_eq!(row.len(), events.len());
            for ((event_name, event), expected_phase) in events.iter().zip(row.iter()) {
                let actual = next(phase, event);
                assert_eq!(
                    short(&actual),
                    *expected_phase,
                    "{row_name} --{event_name}--> expected {expected_phase}, got {}",
                    short(&actual)
                );
            }
        }
    }

    #[test]
    fn local_action_table() {
        #[rustfmt::skip]
        let expected: [(&str, [&str; 4]); 9] = [
            //             send        stop        sendFailed  stopFailed
            ("idle",      ["queued",   "idle",     "idle",     "idle"]),
            ("queued",    ["queued",   "stopping", "idle",     "queued"]),
            ("accepted",  ["accepted", "stopping", "idle",     "accepted"]),
            ("thinking",  ["thinking", "stopping", "thinking", "thinking"]),
            ("streaming", ["streaming","stopping", "streaming","streaming"]),
            ("acting",    ["acting",   "stopping", "acting",   "acting"]),
            ("awaiting",  ["queued",   "stopping", "awaiting", "awaiting"]),
            ("stopping",  ["stopping", "stopping", "stopping", "thinking"]),
            ("settled",   ["queued",   "settled",  "settled",  "settled"]),
        ];
        let actions = [
            LocalAction::Send,
            LocalAction::Stop,
            LocalAction::SendFailed,
            LocalAction::StopFailed,
        ];
        for (phase, (row_name, row)) in all_phases().iter().zip(expected.iter()) {
            assert_eq!(short(phase), *row_name);
            for (action, expected_phase) in actions.iter().zip(row.iter()) {
                assert_eq!(
                    short(&next_local(phase, action)),
                    *expected_phase,
                    "{row_name} --{action:?}"
                );
            }
        }
    }

    #[test]
    fn connection_events_never_change_turn_phase() {
        let connections = [
            ConnectionPhase::Live,
            ConnectionPhase::Syncing,
            ConnectionPhase::Reconnecting,
            ConnectionPhase::Offline,
        ];
        let mut phases = all_phases();
        phases.push(TurnPhase::Settled {
            outcome: TurnOutcome::Interrupted,
        });
        phases.push(TurnPhase::Settled {
            outcome: TurnOutcome::Failed {
                message: "x".into(),
            },
        });
        for phase in &phases {
            for connection in connections {
                let event = SourceEvent::Connection { phase: connection };
                assert_eq!(&next(phase, &event), phase);
                let mut machine = TurnMachine::new(phase.clone());
                machine.apply(&event, 1);
                assert_eq!(machine.phase(), phase);
            }
        }
    }

    #[test]
    fn machine_records_stable_turn_timing() {
        let mut machine = TurnMachine::default();
        assert!(machine.apply_local(&LocalAction::Send, 1_000));
        assert_eq!(machine.active_work_started_at_ms(), Some(1_000));
        machine.apply(
            &SourceEvent::TurnAccepted {
                client_msg_id: None,
                turn_id: "t1".into(),
            },
            1_100,
        );
        machine.apply(
            &SourceEvent::TurnStarted {
                turn_id: "t1".into(),
            },
            1_500,
        );
        // A duplicate start must not move the recorded start time.
        machine.apply(
            &SourceEvent::TurnStarted {
                turn_id: "t1".into(),
            },
            4_000,
        );
        assert_eq!(machine.active_work_started_at_ms(), Some(1_500));
        machine.apply(
            &SourceEvent::TurnSettled {
                turn_id: Some("t1".into()),
                outcome: TurnOutcome::Completed,
            },
            10_500,
        );
        let timing = machine.timings().get("t1").cloned().expect("timing");
        assert_eq!(timing.requested_at_ms, Some(1_000));
        assert_eq!(timing.duration_ms(), Some(9_000));
        assert_eq!(machine.active_turn_id(), None);
        assert_eq!(machine.active_work_started_at_ms(), None);
    }

    #[test]
    fn progress_label_clears_when_output_arrives() {
        let mut machine = TurnMachine::new(TurnPhase::Thinking);
        machine.apply(
            &SourceEvent::Progress {
                label: Some("Waiting on model…".into()),
            },
            1,
        );
        assert_eq!(machine.progress_label(), Some("Waiting on model…"));
        machine.apply(
            &SourceEvent::TextDelta {
                item_id: "a".into(),
                channel: TextChannel::Answer,
                text: "Hi".into(),
            },
            2,
        );
        assert_eq!(machine.progress_label(), None);
        assert_eq!(machine.phase(), &TurnPhase::Streaming);
    }

    #[test]
    fn progress_label_clears_when_item_activity_resumes() {
        for event in [
            SourceEvent::ItemStarted { item: answer() },
            SourceEvent::ItemUpdated { item: answer() },
            SourceEvent::ItemCompleted { item: answer() },
        ] {
            let mut machine = TurnMachine::new(TurnPhase::Streaming);
            machine.apply(
                &SourceEvent::TurnStarted {
                    turn_id: "t".into(),
                },
                0,
            );
            machine.apply(
                &SourceEvent::Progress {
                    label: Some("Reconnecting... 1/5".into()),
                },
                1,
            );
            assert_eq!(machine.progress_label(), Some("Reconnecting... 1/5"));
            machine.apply(&event, 2);
            assert_eq!(machine.progress_label(), None, "resumed event: {event:?}");
        }
    }

    #[test]
    fn progress_label_ignores_item_activity_from_an_older_turn() {
        let mut machine = TurnMachine::new(TurnPhase::Streaming);
        machine.apply(
            &SourceEvent::TurnStarted {
                turn_id: "new-turn".into(),
            },
            0,
        );
        machine.apply(
            &SourceEvent::Progress {
                label: Some("Reconnecting... 1/5".into()),
            },
            1,
        );
        for event in [
            SourceEvent::ItemStarted { item: answer() },
            SourceEvent::ItemUpdated { item: answer() },
            SourceEvent::ItemCompleted { item: answer() },
        ] {
            machine.apply(&event, 2);
            assert_eq!(machine.progress_label(), Some("Reconnecting... 1/5"));
        }
        let mut unscoped = answer();
        unscoped.source_turn_id = None;
        machine.apply(&SourceEvent::ItemUpdated { item: unscoped }, 3);
        assert_eq!(machine.progress_label(), None);
    }

    #[test]
    fn failed_stop_restores_the_phase_the_turn_reached() {
        let mut machine = TurnMachine::new(TurnPhase::Thinking);
        machine.apply(
            &SourceEvent::TurnStarted {
                turn_id: "t1".into(),
            },
            1,
        );
        assert!(machine.apply_local(&LocalAction::Stop, 2));
        assert_eq!(machine.phase(), &TurnPhase::Stopping);
        // The turn keeps streaming while the interrupt is in flight.
        machine.apply(
            &SourceEvent::TextDelta {
                item_id: "a".into(),
                channel: TextChannel::Answer,
                text: "x".into(),
            },
            3,
        );
        assert_eq!(machine.phase(), &TurnPhase::Stopping);
        assert!(machine.apply_local(&LocalAction::StopFailed, 4));
        assert_eq!(machine.phase(), &TurnPhase::Streaming);
        // A late StopFailed after the turn settled changes nothing.
        machine.apply_local(&LocalAction::Stop, 5);
        machine.apply(
            &SourceEvent::TurnSettled {
                turn_id: Some("t1".into()),
                outcome: TurnOutcome::Interrupted,
            },
            6,
        );
        assert!(!machine.apply_local(&LocalAction::StopFailed, 7));
        assert_eq!(
            machine.phase(),
            &TurnPhase::Settled {
                outcome: TurnOutcome::Interrupted
            }
        );
    }

    #[test]
    fn late_turn_start_response_does_not_revive_a_settled_turn() {
        // turn/start's response is processed after the turn already ran and
        // failed (fast error): the TurnAccepted must not leave the chat
        // stuck in "Accepted".
        let mut machine = TurnMachine::default();
        machine.apply_local(&LocalAction::Send, 1);
        machine.apply(
            &SourceEvent::TurnStarted {
                turn_id: "t1".into(),
            },
            2,
        );
        machine.apply(
            &SourceEvent::TurnSettled {
                turn_id: Some("t1".into()),
                outcome: TurnOutcome::Failed {
                    message: "boom".into(),
                },
            },
            3,
        );
        assert!(!machine.apply(
            &SourceEvent::TurnAccepted {
                client_msg_id: Some("c1".into()),
                turn_id: "t1".into(),
            },
            4,
        ));
        assert!(!machine.apply(
            &SourceEvent::TurnStarted {
                turn_id: "t1".into(),
            },
            5,
        ));
        assert!(matches!(
            machine.phase(),
            TurnPhase::Settled {
                outcome: TurnOutcome::Failed { .. }
            }
        ));
    }

    #[test]
    fn duplicate_settle_of_an_old_turn_does_not_end_the_running_turn() {
        let mut machine = TurnMachine::default();
        for (turn, at) in [("t1", 1), ("t2", 10)] {
            machine.apply(
                &SourceEvent::TurnStarted {
                    turn_id: turn.into(),
                },
                at,
            );
            if turn == "t1" {
                machine.apply(
                    &SourceEvent::TurnSettled {
                        turn_id: Some("t1".into()),
                        outcome: TurnOutcome::Completed,
                    },
                    5,
                );
            }
        }
        assert_eq!(machine.phase(), &TurnPhase::Thinking);
        assert!(!machine.apply(
            &SourceEvent::TurnSettled {
                turn_id: Some("t1".into()),
                outcome: TurnOutcome::Completed,
            },
            11,
        ));
        assert_eq!(machine.phase(), &TurnPhase::Thinking);
        assert_eq!(machine.active_turn_id(), Some("t2"));
        // A corrected outcome for the same turn still applies.
        machine.apply(
            &SourceEvent::TurnSettled {
                turn_id: None,
                outcome: TurnOutcome::Completed,
            },
            12,
        );
        machine.apply(
            &SourceEvent::TurnSettled {
                turn_id: Some("t2".into()),
                outcome: TurnOutcome::Interrupted,
            },
            13,
        );
        assert_eq!(
            machine.phase(),
            &TurnPhase::Settled {
                outcome: TurnOutcome::Interrupted
            }
        );
    }
}
