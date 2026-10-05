//! One intake for every agent source.
//!
//! Codex app-server (local, remote, Hermes), the hosted Think agent, Apple
//! Foundation Models (which run in Swift) and voice all reach the chat
//! through the same [`SourceEvent`]s. Each source has a thin adapter:
//!
//! - [`app_server`] maps the reducer's existing `UiEvent`s.
//! - [`hosted`] maps `cf_agent` stream chunks from `hosted_agent.rs`.
//! - [`ExternalSourceEvent`] is the UniFFI shape Swift-run sources push
//!   through `AppStore::ingest_source_events`.
//!
//! [`normalize`] turns agent prose (question/plan fences, Hermes tool
//! envelopes, internal prompt markers) into typed values so no platform
//! parses payloads out of text.

pub mod app_server;
pub mod hosted;
pub mod normalize;

use crate::conversation_uniffi::HydratedConversationItem;

/// The agent runtime behind an app-server thread. Typed so no platform
/// matches on runtime id strings; ids the app does not know yet arrive as
/// `Other`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum ChatRuntime {
    Codex,
    Claude,
    Hermes,
    Amp,
    Opencode,
    Droid,
    Other { id: String },
}

impl ChatRuntime {
    /// Maps a thread's `agent_runtime_kind` id.
    pub fn from_id(id: &str) -> Self {
        match id.trim().to_ascii_lowercase().as_str() {
            "" | "codex" => Self::Codex,
            "claude" => Self::Claude,
            "hermes" => Self::Hermes,
            "amp" => Self::Amp,
            "opencode" => Self::Opencode,
            "droid" => Self::Droid,
            _ => Self::Other { id: id.to_string() },
        }
    }
}

/// Which kind of agent source owns a thread's events.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum SourceKind {
    /// A Codex app-server runtime (local, remote, or Hermes).
    AppServer { runtime: ChatRuntime },
    /// Learnfold's hosted Think agent (Muse Spark).
    Hosted,
    /// Apple Foundation Models, run on-device by Swift.
    Apple,
    /// The realtime voice transcript.
    Voice,
}

impl SourceKind {
    pub fn app_server(runtime_id: &str) -> Self {
        Self::AppServer {
            runtime: ChatRuntime::from_id(runtime_id),
        }
    }
}

/// The stream a text delta belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, uniffi::Enum)]
pub enum TextChannel {
    Answer,
    Reasoning,
    Plan,
}

/// How a turn ended.
#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize, uniffi::Enum)]
pub enum TurnOutcome {
    Completed,
    Interrupted,
    Failed { message: String },
}

/// Transport health for a thread's source. Never affects the turn phase.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, uniffi::Enum)]
pub enum ConnectionPhase {
    Live,
    Syncing,
    Reconnecting,
    Offline,
}

/// Something the agent needs from the learner before it can continue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InputRequest {
    Question {
        id: String,
        text: String,
        options: Vec<String>,
    },
    Approval {
        id: String,
        title: String,
        detail: Option<String>,
    },
}

impl InputRequest {
    pub fn id(&self) -> &str {
        match self {
            Self::Question { id, .. } | Self::Approval { id, .. } => id,
        }
    }
}

/// Canonical internal event. Every source adapter produces these.
#[derive(Debug, Clone, PartialEq)]
pub enum SourceEvent {
    /// The source accepted a learner message. `client_msg_id` reconciles the
    /// optimistic outbox entry when the source echoes it.
    TurnAccepted {
        client_msg_id: Option<String>,
        turn_id: String,
    },
    TurnStarted {
        turn_id: String,
    },
    TextDelta {
        item_id: String,
        channel: TextChannel,
        text: String,
    },
    ItemStarted {
        item: HydratedConversationItem,
    },
    ItemUpdated {
        item: HydratedConversationItem,
    },
    ItemCompleted {
        item: HydratedConversationItem,
    },
    InputRequested {
        request: InputRequest,
    },
    /// A pending input request was answered or withdrawn at the source.
    InputResolved {
        id: String,
    },
    /// A human-readable status line ("Waiting on model…", Hermes recovery
    /// steps). `None` clears it.
    Progress {
        label: Option<String>,
    },
    TurnSettled {
        turn_id: Option<String>,
        outcome: TurnOutcome,
    },
    Connection {
        phase: ConnectionPhase,
    },
}

/// Speaker of a hydrated transcript message pushed from a platform source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ExternalMessageRole {
    User,
    Assistant,
}

/// One message of a transcript the platform already holds (for example an
/// Apple Foundation Models session restored from disk).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExternalTranscriptMessage {
    pub id: String,
    pub role: ExternalMessageRole,
    pub text: String,
    /// Turn this message belongs to, when the platform knows it.
    pub turn_id: Option<String>,
}

/// UniFFI shape for sources that run on the platform (Apple Foundation
/// Models). Swift hands raw events across instead of keeping a transcript;
/// Rust owns items, normalization, turn phase and the chat stream.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ExternalSourceEvent {
    /// Optimistic learner message. Shown as pending until `TurnAccepted`
    /// carries the same `client_msg_id`.
    UserMessage { client_msg_id: String, text: String },
    /// The learner message could not be sent; the pending bubble is removed
    /// so the platform can restore the draft.
    UserMessageFailed { client_msg_id: String },
    TurnAccepted {
        client_msg_id: Option<String>,
        turn_id: String,
    },
    TurnStarted { turn_id: String },
    /// Append `text` to the item's stream.
    TextDelta {
        item_id: String,
        channel: TextChannel,
        text: String,
    },
    /// The full text so far (Apple `streamResponse` partials are cumulative).
    /// Rust turns it into a delta when it extends the previous text and into
    /// an item update otherwise.
    TextSnapshot {
        item_id: String,
        channel: TextChannel,
        text: String,
    },
    ToolStarted {
        item_id: String,
        name: String,
        arguments_json: Option<String>,
    },
    ToolCompleted {
        item_id: String,
        name: String,
        success: bool,
        summary: Option<String>,
    },
    Progress { label: Option<String> },
    /// The learner pressed stop and the platform asked the source to stop.
    /// The chat shows `Stopping` until `TurnSettled` arrives. Works for
    /// every source, including app-server threads.
    StopRequested,
    /// The stop request failed; the turn keeps running.
    StopFailed,
    TurnSettled { outcome: TurnOutcome },
    Connection { phase: ConnectionPhase },
    /// Replace the transcript with messages the platform restored.
    /// Learner messages still waiting for `TurnAccepted` are kept.
    /// Rust drops a source-owned transcript once its last chat subscription
    /// closes while no turn is running, so re-send this when a chat reopens.
    ReplaceTranscript {
        messages: Vec<ExternalTranscriptMessage>,
    },
    /// The conversation an app-server thread replaced. A Codex course thread
    /// whose rollout was lost is rebuilt as a new thread seeded with this
    /// history; the chat shows it above the new thread's own items. Accepted
    /// for app-server threads only. Chat state is dropped when its last
    /// subscription closes, so re-send this when the chat reopens.
    CarriedOverTranscript {
        messages: Vec<ExternalTranscriptMessage>,
    },
}
