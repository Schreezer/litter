//! Two-stage chat timeline, after t3code's `buildThreadFeed` /
//! `deriveThreadFeedPresentation`:
//!
//! 1. [`build_feed`]: canonical items (already course-projected) become feed
//!    entries: one per learner message, answer, plan, question, notice and
//!    work step. Agent prose is normalized here, once, in Rust.
//! 2. [`present_rows`]: feed + turn state become [`TimelineRow`]s: adjacent
//!    work steps of a turn group into one collapsible `Work` row, settled
//!    turns get a "Worked for Ns" `Fold`, and the live row is flagged.
//!
//! Row ids are stable across updates, and each row carries a digest of its
//! content. Nothing here reads the clock: durations come from timings that
//! were recorded once, so a row's digest only changes when its content does.

use std::collections::{HashMap, HashSet};
use std::hash::{DefaultHasher, Hasher};

use crate::conversation_uniffi::{
    HydratedConversationItem, HydratedConversationItemContent, HydratedDividerData,
};
use crate::source::TurnOutcome;
use crate::source::normalize::{
    ChatPlanNodeRole, PlanBlock, PlanMarkdown, PlanNode, extract_question,
    normalize_streaming_assistant_text,
};
use crate::types::AppOperationStatus;

use super::turn::{TurnPhase, TurnTiming};

// ── UniFFI surface ────────────────────────────────────────────────────────

/// One rendered row of the chat. `id` is stable for the life of the row;
/// `digest` changes exactly when the row's content changes.
#[derive(Debug, Clone, PartialEq, serde::Serialize, uniffi::Record)]
pub struct TimelineRow {
    pub id: String,
    pub turn_id: Option<String>,
    pub digest: u64,
    pub kind: TimelineRowKind,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, uniffi::Enum)]
pub enum TimelineRowKind {
    User {
        text: String,
        image_data_uris: Vec<String>,
        delivery: MessageDelivery,
    },
    Answer {
        text: String,
        is_streaming: bool,
        agent_label: Option<String>,
    },
    /// Grouped tool calls and reasoning of one turn. Collapsible.
    Work {
        summary: String,
        entries: Vec<WorkEntry>,
        is_live: bool,
        has_failure: bool,
    },
    /// A question the learner owes an answer to. Fence questions get a row
    /// only on the newest agent message, and only while the agent is not
    /// working and the turn did not fail (Swift's `pendingQuestion` gate).
    Question {
        prompt: String,
        options: Vec<String>,
        /// Always true: answered questions have no row. Kept for the
        /// generated bindings.
        is_pending: bool,
        allows_free_text: bool,
        /// Set for app-server `request_user_input` questions; answer through
        /// `respond_to_user_input`. `None` for fence questions, which are
        /// answered by sending the option as the next message.
        request_id: Option<String>,
        question_id: Option<String>,
        source_item_id: Option<String>,
    },
    Plan {
        source_item_id: String,
        block_index: u32,
        plan: Option<ChatPlan>,
        /// Why a closed `learnfold-plan` fence could not be parsed.
        invalid_reason: Option<String>,
        /// Free-form plan text (Codex plan mode `ProposedPlan` items).
        markdown: Option<String>,
        /// A plan fence is still being written.
        is_streaming: bool,
    },
    Notice {
        tone: NoticeTone,
        title: String,
        message: Option<String>,
    },
    /// "Worked for 9s" header of a settled turn. The platform hides
    /// `folded_row_ids` while the fold is collapsed.
    Fold {
        label: String,
        duration_ms: Option<u64>,
        folded_row_ids: Vec<String>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
pub enum MessageDelivery {
    Sent,
    /// Optimistic: the source has not accepted it yet.
    Pending,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
pub enum NoticeTone {
    Error,
    Divider,
    Info,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, uniffi::Enum)]
pub enum WorkEntryKind {
    Reasoning,
    Command,
    Tool,
    Search,
    FileChange,
    Agent,
    Widget,
    Image,
    Todo,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, uniffi::Record)]
pub struct WorkEntry {
    /// The canonical item id, for looking up the full hydrated item.
    pub item_id: String,
    pub kind: WorkEntryKind,
    pub title: String,
    pub detail: Option<String>,
    pub status: AppOperationStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, uniffi::Record)]
pub struct ChatPlan {
    pub title: String,
    pub summary: String,
    pub outcome: String,
    pub starting_point: String,
    pub focus_gap: String,
    pub estimated_duration: String,
    pub chapters: Vec<ChatPlanChapter>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, uniffi::Record)]
pub struct ChatPlanChapter {
    pub title: String,
    pub objective: String,
    /// Chapter contents in pre-order; `depth` 0 is a direct child.
    pub nodes: Vec<ChatPlanNode>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, uniffi::Record)]
pub struct ChatPlanNode {
    pub title: String,
    pub role: Option<ChatPlanNodeRole>,
    pub depth: u32,
}

impl From<&PlanMarkdown> for ChatPlan {
    fn from(plan: &PlanMarkdown) -> Self {
        fn flatten(nodes: &[PlanNode], depth: u32, out: &mut Vec<ChatPlanNode>) {
            for node in nodes {
                out.push(ChatPlanNode {
                    title: node.title.clone(),
                    role: node.role,
                    depth,
                });
                flatten(&node.children, depth + 1, out);
            }
        }
        Self {
            title: plan.title.clone(),
            summary: plan.summary.clone(),
            outcome: plan.outcome.clone(),
            starting_point: plan.starting_point.clone(),
            focus_gap: plan.focus_gap.clone(),
            estimated_duration: plan.estimated_duration.clone(),
            chapters: plan
                .chapters
                .iter()
                .map(|chapter| {
                    let mut nodes = Vec::new();
                    flatten(&chapter.children, 0, &mut nodes);
                    ChatPlanChapter {
                        title: chapter.title.clone(),
                        objective: chapter.objective.clone(),
                        nodes,
                    }
                })
                .collect(),
        }
    }
}

// ── Inputs ────────────────────────────────────────────────────────────────

/// A pending app-server `request_user_input` question for this thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingQuestionInput {
    pub request_id: String,
    pub question_id: String,
    pub turn_id: Option<String>,
    pub prompt: String,
    pub options: Vec<String>,
    pub allows_free_text: bool,
}

pub struct TimelineInput<'a> {
    /// Canonical items after course projection, in display order.
    pub items: &'a [HydratedConversationItem],
    /// Item ids of optimistic learner messages the source has not accepted.
    pub pending_item_ids: &'a HashSet<String>,
    pub pending_questions: &'a [PendingQuestionInput],
    pub active_turn_id: Option<&'a str>,
    pub phase: &'a TurnPhase,
    pub timings: &'a HashMap<String, TurnTiming>,
    /// Turn id → row id of the learner message that opened the turn, when it
    /// was first shown as an optimistic `user:<local id>` row.
    pub user_row_aliases: &'a HashMap<String, String>,
}

// ── Stage 1: feed ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum FeedEntry {
    /// A single row that never groups.
    Row {
        id: String,
        turn_id: Option<String>,
        kind: TimelineRowKind,
    },
    /// One work step; adjacent steps of a turn group in stage 2.
    Work {
        turn_id: Option<String>,
        entry: WorkEntry,
    },
}

pub fn build_feed(input: &TimelineInput<'_>) -> Vec<FeedEntry> {
    let mut feed = Vec::with_capacity(input.items.len() + 4);
    // Swift's `pendingQuestion` gate: no options while the agent works or
    // after a failed turn.
    let shows_fence_question = !input.phase.is_working()
        && !matches!(
            input.phase,
            TurnPhase::Settled {
                outcome: TurnOutcome::Failed { .. }
            }
        );
    let mut user_turns_seen: HashSet<&str> = HashSet::new();
    // The question the learner still owes an answer to lives in the newest
    // learner-or-agent message, when that message is the agent's.
    let newest_message_id = input
        .items
        .iter()
        .rev()
        .find(|item| {
            matches!(
                item.content,
                HydratedConversationItemContent::User(_)
                    | HydratedConversationItemContent::Assistant(_)
            )
        })
        .map(|item| item.id.as_str());
    let last_active_assistant_id = input.active_turn_id.and_then(|turn_id| {
        input
            .items
            .iter()
            .rev()
            .find(|item| {
                item.source_turn_id.as_deref() == Some(turn_id)
                    && matches!(item.content, HydratedConversationItemContent::Assistant(_))
            })
            .map(|item| item.id.as_str())
    });

    for item in input.items {
        let turn_id = item.source_turn_id.clone();
        match &item.content {
            HydratedConversationItemContent::User(data) => {
                let id = match item.source_turn_id.as_deref() {
                    Some(turn) if item.is_from_user_turn_boundary && user_turns_seen.insert(turn) => {
                        input
                            .user_row_aliases
                            .get(turn)
                            .cloned()
                            .unwrap_or_else(|| format!("user:turn:{turn}"))
                    }
                    _ => format!("user:{}", item.id),
                };
                feed.push(FeedEntry::Row {
                    id,
                    turn_id,
                    kind: TimelineRowKind::User {
                        text: data.text.clone(),
                        image_data_uris: data.image_data_uris.clone(),
                        delivery: if input.pending_item_ids.contains(&item.id) {
                            MessageDelivery::Pending
                        } else {
                            MessageDelivery::Sent
                        },
                    },
                });
            }
            HydratedConversationItemContent::UserInputResponse(data) => {
                let text = data
                    .questions
                    .iter()
                    .map(|question| question.answer.trim())
                    .filter(|answer| !answer.is_empty())
                    .collect::<Vec<_>>()
                    .join("\n");
                if !text.is_empty() {
                    feed.push(FeedEntry::Row {
                        id: format!("user:{}", item.id),
                        turn_id,
                        kind: TimelineRowKind::User {
                            text,
                            image_data_uris: Vec::new(),
                            delivery: MessageDelivery::Sent,
                        },
                    });
                }
            }
            HydratedConversationItemContent::Assistant(data) => {
                let is_streaming = last_active_assistant_id == Some(item.id.as_str())
                    && input.phase.is_working();
                let normalized = normalize_streaming_assistant_text(&data.text, is_streaming);
                if !normalized.display_text.trim().is_empty() {
                    feed.push(FeedEntry::Row {
                        id: format!("answer:{}", item.id),
                        turn_id: turn_id.clone(),
                        kind: TimelineRowKind::Answer {
                            text: normalized.display_text.clone(),
                            is_streaming,
                            agent_label: agent_label(
                                data.agent_nickname.as_deref(),
                                data.agent_role.as_deref(),
                            ),
                        },
                    });
                }
                for (index, block) in normalized.plans.iter().enumerate() {
                    let (plan, invalid_reason) = match block {
                        PlanBlock::Plan(plan) => (Some(ChatPlan::from(plan)), None),
                        PlanBlock::Invalid(reason) => (None, Some(reason.clone())),
                    };
                    feed.push(FeedEntry::Row {
                        id: format!("plan:{}:{index}", item.id),
                        turn_id: turn_id.clone(),
                        kind: TimelineRowKind::Plan {
                            source_item_id: item.id.clone(),
                            block_index: index as u32,
                            plan,
                            invalid_reason,
                            markdown: None,
                            is_streaming: false,
                        },
                    });
                }
                if normalized.plan_streaming {
                    let index = normalized.plans.len();
                    feed.push(FeedEntry::Row {
                        id: format!("plan:{}:{index}", item.id),
                        turn_id: turn_id.clone(),
                        kind: TimelineRowKind::Plan {
                            source_item_id: item.id.clone(),
                            block_index: index as u32,
                            plan: None,
                            invalid_reason: None,
                            markdown: None,
                            is_streaming: true,
                        },
                    });
                }
                // Only the question the learner owes an answer to gets a row
                // (Swift shows options for that one alone). Like Swift, it is
                // read from the raw text, so an unclosed plan fence before it
                // does not hide it.
                let question = (shows_fence_question
                    && newest_message_id == Some(item.id.as_str()))
                .then(|| extract_question(&data.text).question)
                .flatten();
                if let Some(question) = question {
                    feed.push(FeedEntry::Row {
                        id: format!("question:{}", item.id),
                        turn_id,
                        kind: TimelineRowKind::Question {
                            prompt: question.prompt,
                            options: question.options,
                            is_pending: true,
                            allows_free_text: true,
                            request_id: None,
                            question_id: None,
                            source_item_id: Some(item.id.clone()),
                        },
                    });
                }
            }
            HydratedConversationItemContent::ProposedPlan(data) => {
                feed.push(FeedEntry::Row {
                    id: format!("plan:{}:0", item.id),
                    turn_id,
                    kind: TimelineRowKind::Plan {
                        source_item_id: item.id.clone(),
                        block_index: 0,
                        plan: None,
                        invalid_reason: None,
                        markdown: Some(data.content.clone()),
                        is_streaming: false,
                    },
                });
            }
            HydratedConversationItemContent::Error(data) => feed.push(FeedEntry::Row {
                id: format!("notice:{}", item.id),
                turn_id,
                kind: TimelineRowKind::Notice {
                    tone: NoticeTone::Error,
                    title: data.title.clone(),
                    message: Some(data.message.clone()).filter(|message| !message.is_empty()),
                },
            }),
            HydratedConversationItemContent::Divider(data) => {
                let (title, message) = divider_text(data);
                feed.push(FeedEntry::Row {
                    id: format!("notice:{}", item.id),
                    turn_id,
                    kind: TimelineRowKind::Notice {
                        tone: NoticeTone::Divider,
                        title,
                        message,
                    },
                });
            }
            HydratedConversationItemContent::Note(data) => feed.push(FeedEntry::Row {
                id: format!("notice:{}", item.id),
                turn_id,
                kind: TimelineRowKind::Notice {
                    tone: NoticeTone::Info,
                    title: data.title.clone(),
                    message: Some(data.body.clone()).filter(|body| !body.is_empty()),
                },
            }),
            _ => {
                if let Some(entry) = work_entry(item) {
                    feed.push(FeedEntry::Work { turn_id, entry });
                }
            }
        }
    }

    for question in input.pending_questions {
        feed.push(FeedEntry::Row {
            id: format!("question:req:{}:{}", question.request_id, question.question_id),
            turn_id: question.turn_id.clone(),
            kind: TimelineRowKind::Question {
                prompt: question.prompt.clone(),
                options: question.options.clone(),
                is_pending: true,
                allows_free_text: question.allows_free_text,
                request_id: Some(question.request_id.clone()),
                question_id: Some(question.question_id.clone()),
                source_item_id: None,
            },
        });
    }
    feed
}

fn agent_label(nickname: Option<&str>, role: Option<&str>) -> Option<String> {
    let nickname = nickname.map(str::trim).filter(|value| !value.is_empty());
    let role = role.map(str::trim).filter(|value| !value.is_empty());
    match (nickname, role) {
        (Some(nickname), Some(role)) => Some(format!("{nickname} [{role}]")),
        (Some(nickname), None) => Some(nickname.to_string()),
        (None, Some(role)) => Some(format!("[{role}]")),
        (None, None) => None,
    }
}

fn divider_text(data: &HydratedDividerData) -> (String, Option<String>) {
    match data {
        HydratedDividerData::ContextCompaction { is_complete } => (
            if *is_complete {
                "Context compacted".to_string()
            } else {
                "Compacting context".to_string()
            },
            None,
        ),
        HydratedDividerData::ModelRerouted {
            from_model,
            to_model,
            reason,
        } => (
            match from_model {
                Some(from) => format!("Switched from {from} to {to_model}"),
                None => format!("Switched to {to_model}"),
            },
            reason.clone(),
        ),
        HydratedDividerData::ReviewEntered { review } => {
            ("Review started".to_string(), Some(review.clone()))
        }
        HydratedDividerData::ReviewExited { review } => {
            ("Review finished".to_string(), Some(review.clone()))
        }
    }
}

fn first_non_empty_line(text: &str) -> Option<String> {
    text.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(|line| truncate(line, 200))
}

fn last_non_empty_line(text: &str) -> Option<String> {
    text.lines()
        .rev()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(|line| truncate(line, 200))
}

fn truncate(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let mut out: String = text.chars().take(max_chars.saturating_sub(1)).collect();
    out.push('…');
    out
}

fn work_entry(item: &HydratedConversationItem) -> Option<WorkEntry> {
    use HydratedConversationItemContent as C;
    let (kind, title, detail, status) = match &item.content {
        C::Reasoning(data) => {
            let text = if data.summary.iter().any(|part| !part.trim().is_empty()) {
                data.summary.join("\n")
            } else {
                data.content.join("\n")
            };
            if text.trim().is_empty() {
                return None;
            }
            let title = first_non_empty_line(&text)
                .map(|line| line.replace("**", ""))
                .unwrap_or_else(|| "Thinking".to_string());
            (
                WorkEntryKind::Reasoning,
                title,
                Some(text),
                AppOperationStatus::Completed,
            )
        }
        C::CommandExecution(data) => (
            WorkEntryKind::Command,
            data.command.clone(),
            data.output.as_deref().and_then(last_non_empty_line),
            data.status,
        ),
        C::McpToolCall(data) => (
            WorkEntryKind::Tool,
            data.tool.clone(),
            data.error_message
                .clone()
                .or_else(|| data.content_summary.as_deref().and_then(first_non_empty_line)),
            data.status,
        ),
        C::DynamicToolCall(data) => (
            WorkEntryKind::Tool,
            data.display
                .as_ref()
                .map(|display| display.title.clone())
                .filter(|title| !title.is_empty())
                .unwrap_or_else(|| data.tool.clone()),
            data.display
                .as_ref()
                .map(|display| display.summary.clone())
                .filter(|summary| !summary.is_empty())
                .or_else(|| data.content_summary.as_deref().and_then(first_non_empty_line)),
            data.status,
        ),
        C::WebSearch(data) => (
            WorkEntryKind::Search,
            data.query.clone(),
            None,
            if data.is_in_progress {
                AppOperationStatus::InProgress
            } else {
                AppOperationStatus::Completed
            },
        ),
        C::FileChange(data) => (
            WorkEntryKind::FileChange,
            match data.changes.as_slice() {
                [only] => only.path.clone(),
                changes => format!("Edited {} files", changes.len()),
            },
            None,
            data.status,
        ),
        C::TurnDiff(_) => (
            WorkEntryKind::FileChange,
            "Changes".to_string(),
            None,
            AppOperationStatus::Completed,
        ),
        C::MultiAgentAction(data) => (
            WorkEntryKind::Agent,
            data.tool.clone(),
            data.prompt.as_deref().and_then(first_non_empty_line),
            data.status,
        ),
        C::Widget(data) => (
            WorkEntryKind::Widget,
            data.title.clone(),
            None,
            if data.is_finalized {
                AppOperationStatus::Completed
            } else {
                AppOperationStatus::InProgress
            },
        ),
        C::ImageGeneration(data) => (
            WorkEntryKind::Image,
            "Generated image".to_string(),
            data.revised_prompt.clone(),
            data.status,
        ),
        C::ImageView(data) => (
            WorkEntryKind::Other,
            "Viewed image".to_string(),
            Some(data.path.clone()),
            AppOperationStatus::Completed,
        ),
        C::TodoList(data) => (
            WorkEntryKind::Todo,
            "Updated plan".to_string(),
            Some(
                data.steps
                    .iter()
                    .map(|step| step.step.clone())
                    .collect::<Vec<_>>()
                    .join("\n"),
            )
            .filter(|steps| !steps.is_empty()),
            AppOperationStatus::Completed,
        ),
        C::CodeReview(data) => (
            WorkEntryKind::Other,
            "Code review".to_string(),
            data.overall_explanation.clone(),
            AppOperationStatus::Completed,
        ),
        C::User(_)
        | C::UserInputResponse(_)
        | C::Assistant(_)
        | C::ProposedPlan(_)
        | C::Divider(_)
        | C::Error(_)
        | C::Note(_) => return None,
    };
    Some(WorkEntry {
        item_id: item.id.clone(),
        kind,
        title,
        detail,
        status,
    })
}

// ── Stage 2: presentation ─────────────────────────────────────────────────

pub fn present_rows(feed: Vec<FeedEntry>, input: &TimelineInput<'_>) -> Vec<TimelineRow> {
    let live_turn = input
        .active_turn_id
        .filter(|_| input.phase.is_working() || matches!(input.phase, TurnPhase::AwaitingInput));
    let mut rows: Vec<(String, Option<String>, TimelineRowKind)> = Vec::with_capacity(feed.len());
    let mut iter = feed.into_iter().peekable();
    while let Some(entry) = iter.next() {
        match entry {
            FeedEntry::Row { id, turn_id, kind } => rows.push((id, turn_id, kind)),
            FeedEntry::Work { turn_id, entry } => {
                let mut entries = vec![entry];
                while let Some(FeedEntry::Work {
                    turn_id: next_turn, ..
                }) = iter.peek()
                {
                    if *next_turn != turn_id {
                        break;
                    }
                    let Some(FeedEntry::Work { entry, .. }) = iter.next() else {
                        unreachable!("peeked a work entry");
                    };
                    entries.push(entry);
                }
                let id = format!("work:{}", entries[0].item_id);
                let has_failure = entries
                    .iter()
                    .any(|entry| entry.status == AppOperationStatus::Failed);
                rows.push((
                    id,
                    turn_id,
                    TimelineRowKind::Work {
                        summary: String::new(),
                        entries,
                        is_live: false,
                        has_failure,
                    },
                ));
            }
        }
    }

    // The live work row: the last work row of the live turn while the agent
    // is thinking or acting, or any work row with an unfinished step.
    let last_work_index = rows
        .iter()
        .rposition(|(_, _, kind)| matches!(kind, TimelineRowKind::Work { .. }));
    let tail_is_work = last_work_index.is_some_and(|index| index + 1 == rows.len());
    for (index, (_, turn_id, kind)) in rows.iter_mut().enumerate() {
        if let TimelineRowKind::Work {
            summary,
            entries,
            is_live,
            ..
        } = kind
        {
            let in_live_turn = live_turn.is_some() && turn_id.as_deref() == live_turn;
            let unfinished = entries.iter().any(|entry| {
                matches!(
                    entry.status,
                    AppOperationStatus::InProgress | AppOperationStatus::Pending
                )
            });
            *is_live = in_live_turn
                && (unfinished
                    || (Some(index) == last_work_index
                        && tail_is_work
                        && matches!(input.phase, TurnPhase::Thinking | TurnPhase::Acting)));
            *summary = work_summary(entries, *is_live);
        }
    }

    // Folds for settled turns that did work.
    let mut folds: Vec<(usize, String, TimelineRowKind)> = Vec::new();
    let mut turn_order: Vec<String> = Vec::new();
    let mut turn_rows: HashMap<String, Vec<usize>> = HashMap::new();
    for (index, (_, turn_id, _)) in rows.iter().enumerate() {
        if let Some(turn_id) = turn_id {
            if !turn_rows.contains_key(turn_id) {
                turn_order.push(turn_id.clone());
            }
            turn_rows.entry(turn_id.clone()).or_default().push(index);
        }
    }
    for turn_id in turn_order {
        if Some(turn_id.as_str()) == live_turn {
            continue;
        }
        let indexes = &turn_rows[&turn_id];
        let work: Vec<usize> = indexes
            .iter()
            .copied()
            .filter(|index| matches!(rows[*index].2, TimelineRowKind::Work { .. }))
            .collect();
        if work.is_empty() {
            continue;
        }
        let answers: Vec<usize> = indexes
            .iter()
            .copied()
            .filter(|index| matches!(rows[*index].2, TimelineRowKind::Answer { .. }))
            .collect();
        // Everything the agent did except its final answer folds away.
        let mut folded: Vec<usize> = work;
        if answers.len() > 1 {
            folded.extend(answers[..answers.len() - 1].iter().copied());
        }
        folded.sort_unstable();
        let duration_ms = input.timings.get(&turn_id).and_then(TurnTiming::duration_ms);
        let label = match duration_ms {
            Some(duration) => format!("Worked for {}", format_duration(duration)),
            None => "Worked".to_string(),
        };
        folds.push((
            folded[0],
            turn_id,
            TimelineRowKind::Fold {
                label,
                duration_ms,
                folded_row_ids: folded.iter().map(|index| rows[*index].0.clone()).collect(),
            },
        ));
    }
    // Insert back to front so earlier indexes stay valid.
    folds.sort_by_key(|(index, _, _)| *index);
    for (index, turn_id, kind) in folds.into_iter().rev() {
        rows.insert(index, (format!("fold:{turn_id}"), Some(turn_id), kind));
    }

    rows.into_iter()
        .map(|(id, turn_id, kind)| {
            let digest = row_digest(&id, turn_id.as_deref(), &kind);
            TimelineRow {
                id,
                turn_id,
                digest,
                kind,
            }
        })
        .collect()
}

/// Items + turn state → presentation rows.
pub fn derive_rows(input: &TimelineInput<'_>) -> Vec<TimelineRow> {
    present_rows(build_feed(input), input)
}

fn work_summary(entries: &[WorkEntry], is_live: bool) -> String {
    if is_live
        && let Some(last) = entries.last()
    {
        return match last.kind {
            WorkEntryKind::Reasoning => "Thinking".to_string(),
            _ => last.title.clone(),
        };
    }
    let tools = entries
        .iter()
        .filter(|entry| entry.kind != WorkEntryKind::Reasoning)
        .count();
    match (tools, entries.len()) {
        (0, _) => "Thought".to_string(),
        (1, _) => "1 step".to_string(),
        (count, _) => format!("{count} steps"),
    }
}

/// t3code `formatDuration`.
pub fn format_duration(duration_ms: u64) -> String {
    if duration_ms < 1_000 {
        return format!("{}ms", duration_ms.max(1));
    }
    if duration_ms < 10_000 {
        let tenths = (duration_ms as f64 / 100.0).round() / 10.0;
        return if tenths >= 10.0 {
            "10s".to_string()
        } else {
            format!("{tenths:.1}s")
        };
    }
    if duration_ms < 60_000 {
        return format!("{}s", (duration_ms as f64 / 1_000.0).round() as u64);
    }
    let total_seconds = (duration_ms as f64 / 1_000.0).round() as u64;
    let hours = total_seconds / 3_600;
    let minutes = (total_seconds % 3_600) / 60;
    let seconds = total_seconds % 60;
    let mut parts = Vec::new();
    if hours > 0 {
        parts.push(format!("{hours}h"));
    }
    if minutes > 0 {
        parts.push(format!("{minutes}m"));
    }
    if seconds > 0 {
        parts.push(format!("{seconds}s"));
    }
    parts.join(" ")
}

fn row_digest(id: &str, turn_id: Option<&str>, kind: &TimelineRowKind) -> u64 {
    struct HashWriter<'a>(&'a mut DefaultHasher);
    impl std::io::Write for HashWriter<'_> {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.write(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut hasher = DefaultHasher::new();
    hasher.write(id.as_bytes());
    hasher.write_u8(0xff);
    hasher.write(turn_id.unwrap_or("").as_bytes());
    serde_json::to_writer(HashWriter(&mut hasher), kind)
        .expect("TimelineRowKind serialization is infallible");
    hasher.finish()
}

#[cfg(test)]
impl TimelineRow {
    /// Text an `Answer` row shows, if it is one.
    pub fn answer_text(&self) -> Option<&str> {
        match &self.kind {
            TimelineRowKind::Answer { text, .. } => Some(text),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::conversation_uniffi::{
        HydratedAssistantMessageData, HydratedCommandExecutionData, HydratedReasoningData,
        HydratedUserMessageData,
    };

    fn user(id: &str, turn: &str, text: &str) -> HydratedConversationItem {
        HydratedConversationItem {
            id: id.into(),
            content: HydratedConversationItemContent::User(HydratedUserMessageData {
                text: text.into(),
                image_data_uris: vec![],
            }),
            source_turn_id: Some(turn.into()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: true,
        }
    }

    fn answer(id: &str, turn: &str, text: &str) -> HydratedConversationItem {
        HydratedConversationItem {
            id: id.into(),
            content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: text.into(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            }),
            source_turn_id: Some(turn.into()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    fn command(id: &str, turn: &str, status: AppOperationStatus) -> HydratedConversationItem {
        HydratedConversationItem {
            id: id.into(),
            content: HydratedConversationItemContent::CommandExecution(
                HydratedCommandExecutionData {
                    command: format!("run {id}"),
                    cwd: "/".into(),
                    status,
                    output: Some("line one\nlast line\n".into()),
                    exit_code: None,
                    duration_ms: None,
                    process_id: None,
                    actions: vec![],
                },
            ),
            source_turn_id: Some(turn.into()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    fn reasoning(id: &str, turn: &str, text: &str) -> HydratedConversationItem {
        HydratedConversationItem {
            id: id.into(),
            content: HydratedConversationItemContent::Reasoning(HydratedReasoningData {
                summary: vec![text.into()],
                content: vec![],
            }),
            source_turn_id: Some(turn.into()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    fn derive(
        items: &[HydratedConversationItem],
        phase: TurnPhase,
        active: Option<&str>,
        timings: &HashMap<String, TurnTiming>,
    ) -> Vec<TimelineRow> {
        let pending = HashSet::new();
        derive_rows(&TimelineInput {
            items,
            pending_item_ids: &pending,
            pending_questions: &[],
            active_turn_id: active,
            phase: &phase,
            timings,
            user_row_aliases: &HashMap::new(),
        })
    }

    fn ids(rows: &[TimelineRow]) -> Vec<&str> {
        rows.iter().map(|row| row.id.as_str()).collect()
    }

    #[test]
    fn groups_work_and_folds_settled_turns() {
        let items = vec![
            user("u1", "t1", "Explain OLED"),
            reasoning("r1", "t1", "**Planning** the answer"),
            command("c1", "t1", AppOperationStatus::Completed),
            answer("a1", "t1", "Let me check one more thing."),
            command("c2", "t1", AppOperationStatus::Failed),
            answer("a2", "t1", "OLED pixels emit light."),
        ];
        let mut timings = HashMap::new();
        timings.insert(
            "t1".to_string(),
            TurnTiming {
                requested_at_ms: Some(0),
                started_at_ms: Some(1_000),
                settled_at_ms: Some(10_000),
            },
        );
        let rows = derive(
            &items,
            TurnPhase::Settled {
                outcome: TurnOutcome::Completed,
            },
            None,
            &timings,
        );
        assert_eq!(
            ids(&rows),
            vec![
                "user:turn:t1",
                "fold:t1",
                "work:r1",
                "answer:a1",
                "work:c2",
                "answer:a2"
            ]
        );
        let TimelineRowKind::Fold {
            label,
            folded_row_ids,
            duration_ms,
        } = &rows[1].kind
        else {
            panic!("expected fold");
        };
        assert_eq!(label, "Worked for 9.0s");
        assert_eq!(*duration_ms, Some(9_000));
        assert_eq!(folded_row_ids, &vec!["work:r1", "answer:a1", "work:c2"]);
        let TimelineRowKind::Work {
            entries,
            summary,
            has_failure,
            ..
        } = &rows[2].kind
        else {
            panic!("expected work");
        };
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].title, "Planning the answer");
        assert_eq!(entries[1].detail.as_deref(), Some("last line"));
        assert_eq!(summary, "1 step");
        assert!(!has_failure);
        assert!(matches!(rows[4].kind, TimelineRowKind::Work { has_failure: true, .. }));
    }

    #[test]
    fn live_turn_has_no_fold_and_flags_live_work() {
        let items = vec![
            user("u1", "t1", "Go"),
            command("c1", "t1", AppOperationStatus::InProgress),
        ];
        let rows = derive(&items, TurnPhase::Acting, Some("t1"), &HashMap::new());
        assert_eq!(ids(&rows), vec!["user:turn:t1", "work:c1"]);
        assert!(matches!(
            &rows[1].kind,
            TimelineRowKind::Work { is_live: true, summary, .. } if summary == "run c1"
        ));
    }

    #[test]
    fn digests_are_stable_and_track_content_only() {
        let items = vec![user("u1", "t1", "Hi"), answer("a1", "t1", "Hello")];
        let first = derive(&items, TurnPhase::Streaming, Some("t1"), &HashMap::new());
        std::thread::sleep(std::time::Duration::from_millis(5));
        let second = derive(&items, TurnPhase::Streaming, Some("t1"), &HashMap::new());
        assert_eq!(first, second);

        let grown = vec![user("u1", "t1", "Hi"), answer("a1", "t1", "Hello there")];
        let third = derive(&grown, TurnPhase::Streaming, Some("t1"), &HashMap::new());
        assert_eq!(first[0].digest, third[0].digest);
        assert_ne!(first[1].digest, third[1].digest);
        assert_eq!(first[1].id, third[1].id);
    }

    #[test]
    fn fences_become_typed_rows() {
        let text = "Lead-in.\n\n```learnfold-question\nPace?\n- Slow\n- Fast\n```";
        let items = vec![user("u1", "t1", "Hi"), answer("a1", "t1", text)];
        let rows = derive(
            &items,
            TurnPhase::Settled {
                outcome: TurnOutcome::Completed,
            },
            None,
            &HashMap::new(),
        );
        assert_eq!(ids(&rows), vec!["user:turn:t1", "answer:a1", "question:a1"]);
        assert_eq!(rows[1].answer_text(), Some("Lead-in.\n\nPace?"));
        assert!(matches!(
            &rows[2].kind,
            TimelineRowKind::Question { is_pending: true, options, .. } if options.len() == 2
        ));

        let streaming_plan = "Here is the plan.\n\n```learnfold-plan\n# Bonds\nSummary:";
        let items = vec![user("u1", "t1", "Hi"), answer("a1", "t1", streaming_plan)];
        let rows = derive(&items, TurnPhase::Streaming, Some("t1"), &HashMap::new());
        assert_eq!(ids(&rows), vec!["user:turn:t1", "answer:a1", "plan:a1:0"]);
        assert_eq!(rows[1].answer_text(), Some("Here is the plan."));
        assert!(matches!(
            rows[2].kind,
            TimelineRowKind::Plan {
                is_streaming: true,
                plan: None,
                ..
            }
        ));
    }

    #[test]
    fn user_row_id_survives_optimistic_to_echo_swap() {
        let mut overlay = user("local-user-message:7", "t1", "Hi");
        overlay.source_turn_id = Some("t1".into());
        let optimistic = derive(&[overlay], TurnPhase::Accepted, Some("t1"), &HashMap::new());
        let echoed = derive(
            &[user("server-item", "t1", "Hi")],
            TurnPhase::Thinking,
            Some("t1"),
            &HashMap::new(),
        );
        assert_eq!(optimistic[0].id, echoed[0].id);
        assert_eq!(optimistic[0].digest, echoed[0].digest);
    }

    #[test]
    fn formats_durations_like_t3code() {
        assert_eq!(format_duration(450), "450ms");
        assert_eq!(format_duration(9_000), "9.0s");
        assert_eq!(format_duration(9_990), "10s");
        assert_eq!(format_duration(42_400), "42s");
        assert_eq!(format_duration(3_723_000), "1h 2m 3s");
    }
}
