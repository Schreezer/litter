//! AppServerAdapter: the reducer's `UiEvent`s as canonical source events.
//!
//! The reducer keeps applying `UiEvent`s to the snapshot exactly as before;
//! this adapter only derives the [`SourceEvent`]s that drive the per-thread
//! turn machine. Item content stays in the snapshot, so the adapter never
//! duplicates reducer logic.

use crate::conversation_uniffi::HydratedConversationItem;
use crate::session::events::UiEvent;
use crate::store::actions::conversation_item_from_upstream_with_turn;
use crate::types::ThreadKey;

use super::{InputRequest, SourceEvent, TextChannel, TurnOutcome};

/// Source events for one `UiEvent`, keyed by the thread they belong to.
/// Returns `None` for events that do not concern a thread's turn.
pub(crate) fn source_events(event: &UiEvent) -> Option<(ThreadKey, Vec<SourceEvent>)> {
    match event {
        UiEvent::TurnStarted { key, turn_id } => Some((
            key.clone(),
            vec![SourceEvent::TurnStarted {
                turn_id: turn_id.clone(),
            }],
        )),
        UiEvent::TurnCompleted {
            key,
            turn_id,
            error,
            interrupted,
        } => Some((
            key.clone(),
            vec![SourceEvent::TurnSettled {
                turn_id: Some(turn_id.clone()),
                outcome: turn_outcome(error.as_deref(), *interrupted),
            }],
        )),
        UiEvent::TurnRetrying { key, message, .. } => Some((
            key.clone(),
            vec![SourceEvent::Progress {
                label: Some(message.clone()),
            }],
        )),
        UiEvent::ItemStarted { key, notification } => {
            let item = hydrated(&notification.item, &notification.turn_id)?;
            Some((key.clone(), vec![SourceEvent::ItemStarted { item }]))
        }
        UiEvent::ItemCompleted { key, notification } => {
            let item = hydrated(&notification.item, &notification.turn_id)?;
            Some((key.clone(), vec![SourceEvent::ItemCompleted { item }]))
        }
        UiEvent::MessageDelta {
            key,
            item_id,
            delta,
        } => Some(text_delta(key, item_id, TextChannel::Answer, delta)),
        UiEvent::ReasoningDelta {
            key,
            item_id,
            delta,
        } => Some(text_delta(key, item_id, TextChannel::Reasoning, delta)),
        UiEvent::PlanDelta {
            key,
            item_id,
            delta,
        } => Some(text_delta(key, item_id, TextChannel::Plan, delta)),
        UiEvent::ApprovalRequested { key, approval } => {
            let approval = &approval.approval;
            let key = approval
                .thread_id
                .as_ref()
                .map(|thread_id| ThreadKey {
                    server_id: approval.server_id.clone(),
                    thread_id: thread_id.clone(),
                })
                .unwrap_or_else(|| key.clone());
            Some((
                key,
                vec![SourceEvent::InputRequested {
                    request: InputRequest::Approval {
                        id: approval.id.clone(),
                        title: format!("{:?} approval", approval.kind),
                        detail: approval.command.clone(),
                    },
                }],
            ))
        }
        UiEvent::UserInputRequested { request, .. } => {
            let question = request.questions.first();
            Some((
                ThreadKey {
                    server_id: request.server_id.clone(),
                    thread_id: request.thread_id.clone(),
                },
                vec![SourceEvent::InputRequested {
                    request: InputRequest::Question {
                        id: request.id.clone(),
                        text: question.map(|q| q.question.clone()).unwrap_or_default(),
                        options: question
                            .map(|q| q.options.iter().map(|o| o.label.clone()).collect())
                            .unwrap_or_default(),
                    },
                }],
            ))
        }
        UiEvent::ServerRequestResolved { key, notification } => {
            let id = match &notification.request_id {
                codex_app_server_protocol::RequestId::String(value) => value.clone(),
                codex_app_server_protocol::RequestId::Integer(value) => value.to_string(),
            };
            Some((key.clone(), vec![SourceEvent::InputResolved { id }]))
        }
        _ => None,
    }
}

/// The thread a turn-relevant `UiEvent` concerns, without converting it.
pub(crate) fn event_thread_key(event: &UiEvent) -> Option<ThreadKey> {
    match event {
        UiEvent::TurnStarted { key, .. }
        | UiEvent::TurnCompleted { key, .. }
        | UiEvent::TurnRetrying { key, .. }
        | UiEvent::ItemStarted { key, .. }
        | UiEvent::ItemCompleted { key, .. }
        | UiEvent::MessageDelta { key, .. }
        | UiEvent::ReasoningDelta { key, .. }
        | UiEvent::PlanDelta { key, .. }
        | UiEvent::ServerRequestResolved { key, .. } => Some(key.clone()),
        UiEvent::ApprovalRequested { key, approval } => Some(
            approval
                .approval
                .thread_id
                .as_ref()
                .map(|thread_id| ThreadKey {
                    server_id: approval.approval.server_id.clone(),
                    thread_id: thread_id.clone(),
                })
                .unwrap_or_else(|| key.clone()),
        ),
        UiEvent::UserInputRequested { request, .. } => Some(ThreadKey {
            server_id: request.server_id.clone(),
            thread_id: request.thread_id.clone(),
        }),
        _ => None,
    }
}

pub(crate) fn turn_outcome(error: Option<&str>, interrupted: bool) -> TurnOutcome {
    if interrupted {
        return TurnOutcome::Interrupted;
    }
    match error.map(str::trim).filter(|message| !message.is_empty()) {
        Some(message) => TurnOutcome::Failed {
            message: message.to_string(),
        },
        None => TurnOutcome::Completed,
    }
}

fn text_delta(
    key: &ThreadKey,
    item_id: &str,
    channel: TextChannel,
    delta: &str,
) -> (ThreadKey, Vec<SourceEvent>) {
    (
        key.clone(),
        vec![SourceEvent::TextDelta {
            item_id: item_id.to_string(),
            channel,
            text: delta.to_string(),
        }],
    )
}

fn hydrated(
    item: &codex_app_server_protocol::ThreadItem,
    turn_id: &str,
) -> Option<HydratedConversationItem> {
    conversation_item_from_upstream_with_turn(item.clone(), Some(turn_id))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turn_outcomes_map_interruptions_and_errors() {
        assert_eq!(turn_outcome(None, false), TurnOutcome::Completed);
        assert_eq!(turn_outcome(Some("  "), false), TurnOutcome::Completed);
        assert_eq!(turn_outcome(Some("boom"), true), TurnOutcome::Interrupted);
        assert_eq!(
            turn_outcome(Some("boom"), false),
            TurnOutcome::Failed {
                message: "boom".into()
            }
        );
    }

    #[test]
    fn deltas_map_to_channels() {
        let key = ThreadKey {
            server_id: "srv".into(),
            thread_id: "thr".into(),
        };
        let (mapped_key, events) = source_events(&UiEvent::ReasoningDelta {
            key: key.clone(),
            item_id: "r1".into(),
            delta: "hmm".into(),
        })
        .expect("mapped");
        assert_eq!(mapped_key, key);
        assert_eq!(
            events,
            vec![SourceEvent::TextDelta {
                item_id: "r1".into(),
                channel: TextChannel::Reasoning,
                text: "hmm".into(),
            }]
        );
        assert!(
            source_events(&UiEvent::ThreadNameUpdated {
                key,
                thread_name: None
            })
            .is_none()
        );
    }

    #[test]
    fn retryable_turn_errors_map_to_progress_only() {
        let key = ThreadKey {
            server_id: "srv".into(),
            thread_id: "thr".into(),
        };
        let event = UiEvent::TurnRetrying {
            key: key.clone(),
            turn_id: "turn-1".into(),
            message: "Reconnecting... 1/5".into(),
        };
        assert_eq!(event_thread_key(&event), Some(key.clone()));
        assert_eq!(
            source_events(&event),
            Some((
                key,
                vec![SourceEvent::Progress {
                    label: Some("Reconnecting... 1/5".into()),
                }],
            )),
        );
    }
}
