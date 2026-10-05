//! Recorded-stream fixtures for the chat projection, driven through the
//! real intake paths: `AppStoreReducer::apply_ui_event` for app-server
//! (Codex, Hermes), `chat_ingest_external` for Apple, plus reconnect,
//! outbox and lifecycle cases. Hosted fixtures live in `source/hosted.rs`.

use codex_app_server_protocol as upstream;
use serde_json::{Value, json};

use crate::session::events::{EventProcessor, UiEvent};
use crate::source::{ExternalSourceEvent, SourceKind, TextChannel, TurnOutcome};
use crate::store::AppStoreReducer;
use crate::store::chat::{ChatView, ChatViewOptions};
use crate::store::snapshot::ThreadSnapshot;
use crate::store::timeline::{MessageDelivery, NoticeTone, TimelineRowKind};
use crate::store::turn::TurnPhase;
use crate::types::{ThreadInfo, ThreadKey, ThreadSummaryStatus};

fn key() -> ThreadKey {
    ThreadKey {
        server_id: "srv".into(),
        thread_id: "thread".into(),
    }
}

fn thread(runtime: &str) -> ThreadSnapshot {
    let mut thread = ThreadSnapshot::from_info(
        "srv",
        ThreadInfo {
            id: "thread".into(),
            title: None,
            model: None,
            status: ThreadSummaryStatus::Idle,
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
    thread.agent_runtime_kind = runtime.into();
    thread.initial_turns_loaded = true;
    thread
}

fn item(value: Value) -> upstream::ThreadItem {
    serde_json::from_value(value).expect("thread item")
}

fn user_message(id: &str, text: &str) -> upstream::ThreadItem {
    item(json!({"type": "userMessage", "id": id, "clientId": null,
        "content": [{"type": "text", "text": text}]}))
}

fn agent_message(id: &str, text: &str) -> upstream::ThreadItem {
    item(json!({"type": "agentMessage", "id": id, "text": text}))
}

fn tool(id: &str, name: &str, status: &str) -> upstream::ThreadItem {
    item(json!({"type": "dynamicToolCall", "id": id, "namespace": null, "tool": name,
        "arguments": {}, "status": status, "contentItems": null, "success": null,
        "durationMs": null}))
}

fn started(turn: &str, item: upstream::ThreadItem) -> UiEvent {
    UiEvent::ItemStarted {
        key: key(),
        notification: upstream::ItemStartedNotification {
            item,
            thread_id: "thread".into(),
            turn_id: turn.into(),
            started_at_ms: 0,
        },
    }
}

fn completed(turn: &str, item: upstream::ThreadItem) -> UiEvent {
    UiEvent::ItemCompleted {
        key: key(),
        notification: upstream::ItemCompletedNotification {
            item,
            thread_id: "thread".into(),
            turn_id: turn.into(),
            completed_at_ms: 0,
        },
    }
}

fn turn_started(turn: &str) -> UiEvent {
    UiEvent::TurnStarted {
        key: key(),
        turn_id: turn.into(),
    }
}

fn turn_completed(turn: &str) -> UiEvent {
    UiEvent::TurnCompleted {
        key: key(),
        turn_id: turn.into(),
        error: None,
        interrupted: false,
    }
}

fn error_notification(turn: &str, message: &str, will_retry: bool) -> UiEvent {
    let processor = EventProcessor::new();
    let mut events = processor.subscribe();
    processor.process_notification(
        "srv",
        "codex".into(),
        &upstream::ServerNotification::Error(upstream::ErrorNotification {
            error: upstream::TurnError {
                message: message.into(),
                codex_error_info: None,
                additional_details: None,
            },
            will_retry,
            thread_id: "thread".into(),
            turn_id: turn.into(),
        }),
    );
    events.try_recv().expect("error notification event")
}

fn text_input(text: &str) -> Vec<upstream::UserInput> {
    vec![upstream::UserInput::Text {
        text: text.into(),
        text_elements: Vec::new(),
    }]
}

fn view(reducer: &AppStoreReducer) -> ChatView {
    reducer.chat_view(&key(), &ChatViewOptions::default())
}

fn ids(view: &ChatView) -> Vec<&str> {
    view.rows.iter().map(|row| row.id.as_str()).collect()
}

#[test]
fn fixture_retry_notice_clears_when_output_resumes_and_turn_settles() {
    for runtime in ["codex", "hermes"] {
        let reducer = AppStoreReducer::new();
        reducer.upsert_thread_snapshot(thread(runtime));
        let _chat = reducer.chat_subscribe(&key());
        reducer.apply_ui_event(&turn_started("t1"));
        let retry = error_notification("t1", "Reconnecting... 1/5", true);

        reducer.apply_ui_event(&retry);
        assert_eq!(
            view(&reducer).progress_label.as_deref(),
            Some("Reconnecting... 1/5")
        );
        assert!(
            view(&reducer).rows.is_empty(),
            "retry is not a transcript row"
        );
        assert!(reducer.snapshot().threads[&key()].items.is_empty());

        reducer.apply_ui_event(&started("t1", agent_message("a1", "The connection")));
        assert_eq!(
            view(&reducer).progress_label,
            None,
            "new output clears retry"
        );

        reducer.apply_ui_event(&retry);
        reducer.apply_ui_event(&UiEvent::MessageDelta {
            key: key(),
            item_id: "a1".into(),
            delta: " recovered.".into(),
        });
        assert_eq!(
            view(&reducer).progress_label,
            None,
            "streaming clears retry"
        );

        reducer.apply_ui_event(&retry);
        reducer.apply_ui_event(&completed(
            "t1",
            agent_message("a1", "The connection recovered."),
        ));
        assert_eq!(
            view(&reducer).progress_label,
            None,
            "completed output clears retry"
        );

        reducer.apply_ui_event(&retry);
        reducer.apply_ui_event(&turn_completed("t1"));
        let settled = view(&reducer);
        assert_eq!(
            settled.progress_label, None,
            "successful completion clears retry"
        );
        assert!(
            !settled
                .rows
                .iter()
                .any(|row| matches!(row.kind, TimelineRowKind::Notice { .. }))
        );
        assert!(
            reducer.snapshot().threads[&key()]
                .items
                .iter()
                .all(|item| !matches!(
                    item.content,
                    crate::conversation_uniffi::HydratedConversationItemContent::Error(_)
                ))
        );
    }
}

#[test]
fn fixture_retry_notice_ignores_settled_and_replaced_turns() {
    let reducer = AppStoreReducer::new();
    reducer.upsert_thread_snapshot(thread("codex"));
    let _chat = reducer.chat_subscribe(&key());
    reducer.apply_ui_event(&turn_started("t1"));
    reducer.apply_ui_event(&turn_completed("t1"));
    reducer.apply_ui_event(&error_notification("t1", "Reconnecting... 1/5", true));
    assert_eq!(
        view(&reducer).progress_label,
        None,
        "settled retry is stale"
    );

    reducer.apply_ui_event(&turn_started("t2"));
    reducer.apply_ui_event(&error_notification("t1", "Reconnecting... 1/5", true));
    assert_eq!(
        view(&reducer).progress_label,
        None,
        "previous turn retry is stale"
    );

    reducer.apply_ui_event(&error_notification("t2", "Reconnecting... 2/5", true));
    assert_eq!(
        view(&reducer).progress_label.as_deref(),
        Some("Reconnecting... 2/5")
    );
    reducer.apply_ui_event(&completed("t1", agent_message("a1", "Older turn output.")));
    assert_eq!(
        view(&reducer).progress_label.as_deref(),
        Some("Reconnecting... 2/5"),
        "older turn completion must not clear the active turn retry"
    );
    reducer.apply_ui_event(&completed("t2", agent_message("a2", "Recovered output.")));
    assert_eq!(view(&reducer).progress_label, None);

    reducer.apply_ui_event(&error_notification("t2", "Reconnecting... 3/5", true));
    reducer.apply_ui_event(&turn_started("t3"));
    assert_eq!(
        view(&reducer).progress_label,
        None,
        "new turn clears old retry"
    );
    assert!(
        reducer.snapshot().threads[&key()]
            .items
            .iter()
            .all(|item| !matches!(
                item.content,
                crate::conversation_uniffi::HydratedConversationItemContent::Error(_)
            ))
    );
}

#[test]
fn fixture_retry_notice_preserves_final_errors() {
    let reducer = AppStoreReducer::new();
    reducer.upsert_thread_snapshot(thread("codex"));
    let _chat = reducer.chat_subscribe(&key());
    reducer.apply_ui_event(&turn_started("t1"));
    reducer.apply_ui_event(&error_notification("t1", "Reconnecting... 1/5", true));
    reducer.apply_ui_event(&error_notification(
        "t1",
        "Connection failed after retries",
        false,
    ));
    reducer.apply_ui_event(&UiEvent::TurnCompleted {
        key: key(),
        turn_id: "t1".into(),
        error: Some("Connection failed after retries".into()),
        interrupted: false,
    });

    let failed = view(&reducer);
    assert_eq!(failed.progress_label, None);
    assert!(failed.rows.iter().any(|row| matches!(
        &row.kind,
        TimelineRowKind::Notice { tone: NoticeTone::Error, message: Some(message), .. }
            if message == "Connection failed after retries"
    )));
    assert_eq!(reducer.snapshot().threads[&key()].items.len(), 1);
}

/// Codex turn: optimistic send, server echo, two parallel tools, a streamed
/// answer ending in a question fence, completion.
#[test]
fn fixture_codex_turn() {
    let reducer = AppStoreReducer::new();
    reducer.upsert_thread_snapshot(thread("codex"));
    let _chat = reducer.chat_subscribe(&key());

    let local = reducer
        .stage_local_user_message_overlay(&key(), &text_input("Explain OLED"))
        .expect("overlay");
    let queued = view(&reducer);
    assert_eq!(queued.phase, TurnPhase::Queued);
    let user_row = format!("user:{local}");
    assert_eq!(ids(&queued), vec![user_row.as_str()]);
    assert!(matches!(
        queued.rows[0].kind,
        TimelineRowKind::User {
            delivery: MessageDelivery::Pending,
            ..
        }
    ));

    let recorded = vec![
        turn_started("turn-1"),
        started("turn-1", user_message("srv-u1", "Explain OLED")),
        completed("turn-1", user_message("srv-u1", "Explain OLED")),
        started("turn-1", tool("tool-a", "search", "inProgress")),
        started("turn-1", tool("tool-b", "fetch", "inProgress")),
        completed("turn-1", tool("tool-a", "search", "completed")),
    ];
    for event in &recorded {
        reducer.apply_ui_event(event);
    }
    // turn/start's response arrives after the notifications.
    reducer.bind_local_user_message_overlay_to_turn(&key(), &local, "turn-1");
    let acting = view(&reducer);
    assert_eq!(acting.phase, TurnPhase::Acting, "tool-b still runs");
    assert_eq!(acting.rows[0].id, user_row, "row id survives the echo");
    assert!(matches!(
        acting.rows[0].kind,
        TimelineRowKind::User {
            delivery: MessageDelivery::Sent,
            ..
        }
    ));

    reducer.apply_ui_event(&completed("turn-1", tool("tool-b", "fetch", "completed")));
    assert_eq!(view(&reducer).phase, TurnPhase::Thinking);

    reducer.apply_ui_event(&started("turn-1", agent_message("a1", "")));
    for delta in ["OLED pixels ", "emit light.\n\n```learnfold-question\nPace?\n- Slow\n- Fast\n```"] {
        reducer.apply_ui_event(&UiEvent::MessageDelta {
            key: key(),
            item_id: "a1".into(),
            delta: delta.into(),
        });
    }
    let streaming = view(&reducer);
    assert_eq!(streaming.phase, TurnPhase::Streaming);
    assert!(
        !streaming
            .rows
            .iter()
            .any(|row| matches!(row.kind, TimelineRowKind::Question { .. })),
        "no options while the agent works"
    );

    let text = "OLED pixels emit light.\n\n```learnfold-question\nPace?\n- Slow\n- Fast\n```";
    reducer.apply_ui_event(&completed("turn-1", agent_message("a1", text)));
    reducer.apply_ui_event(&turn_completed("turn-1"));
    let settled = view(&reducer);
    assert_eq!(settled.phase, TurnPhase::AwaitingInput);
    assert_eq!(
        ids(&settled),
        vec![
            user_row.as_str(),
            "fold:turn-1",
            "work:tool-a",
            "answer:a1",
            "question:a1"
        ]
    );
    assert_eq!(settled.rows[3].kind, TimelineRowKind::Answer {
        text: "OLED pixels emit light.\n\nPace?".into(),
        is_streaming: false,
        agent_label: None,
    });
}

/// Hermes turn: the learner prompt is wrapped in the remote protocol, the
/// agent replies with a tool envelope, the device answers with a result
/// envelope, and the agent finishes in prose.
#[test]
fn fixture_hermes_turn() {
    let reducer = AppStoreReducer::new();
    reducer.upsert_thread_snapshot(thread("hermes"));
    let _chat = reducer.chat_subscribe(&key());
    let wrapped = "Learnfold remote native-tool protocol:\n- rules\n\nLearner message:\nBuild my course";
    let plan_call = r#"{"learnfold_tool_call":{"name":"present_course_plan","arguments":{"workspace_id":"w"}}}"#;
    let bash_call = r#"{"learnfold_tool_call":{"name":"course_bash","arguments":{"workspace_id":"w","script":"ls /workspace"}}}"#;
    let result = |name: &str| {
        format!(
            "{{\"learnfold_tool_result\":{{\"name\":\"{name}\",\"success\":true}}}}\n\nContinue the course task."
        )
    };
    let recorded = vec![
        turn_started("t1"),
        completed("t1", user_message("u1", wrapped)),
        // A half-streamed envelope must not flash.
        started("t1", agent_message("a1", "")),
        UiEvent::MessageDelta {
            key: key(),
            item_id: "a1".into(),
            delta: r#"{"learnfold_tool_call":{"name":"pres"#.into(),
        },
    ];
    for event in &recorded {
        reducer.apply_ui_event(event);
    }
    assert_eq!(ids(&view(&reducer)), vec!["user:turn:t1"]);
    reducer.ingest_hermes_progress("Running course tool…");
    assert_eq!(
        view(&reducer).progress_label.as_deref(),
        Some("Running course tool…")
    );

    let recorded = vec![
        completed("t1", agent_message("a1", plan_call)),
        turn_completed("t1"),
        turn_started("t2"),
        completed("t2", user_message("u2", &result("present_course_plan"))),
        completed("t2", agent_message("a2", bash_call)),
        turn_completed("t2"),
        turn_started("t3"),
        completed("t3", user_message("u3", &result("course_bash"))),
        completed("t3", agent_message("a3", "Your plan is ready for review.")),
        turn_completed("t3"),
    ];
    for event in &recorded {
        reducer.apply_ui_event(event);
    }
    let settled = view(&reducer);
    assert!(matches!(settled.phase, TurnPhase::Settled { .. }));
    let TimelineRowKind::User { text, .. } = &settled.rows[0].kind else {
        panic!("expected the learner row first: {:?}", settled.rows);
    };
    assert_eq!(text, "Build my course");
    // No envelope prose, no plan card; the course_bash call is a work entry.
    let kinds: Vec<_> = settled
        .rows
        .iter()
        .map(|row| match &row.kind {
            TimelineRowKind::User { .. } => "user",
            TimelineRowKind::Answer { .. } => "answer",
            TimelineRowKind::Work { .. } => "work",
            TimelineRowKind::Fold { .. } => "fold",
            TimelineRowKind::Notice { .. } => "notice",
            _ => "other",
        })
        .collect();
    assert_eq!(kinds, vec!["user", "fold", "work", "answer"]);
    assert!(matches!(
        &settled.rows[2].kind,
        TimelineRowKind::Work { entries, .. } if entries.len() == 1 && entries[0].title == "course_bash"
    ));
}

/// Apple Foundation Models partials: cumulative snapshots, a rewrite, a
/// stop, and a transcript restore that keeps an unsent message.
#[test]
fn fixture_apple_turn_with_stop_and_restore() {
    let reducer = AppStoreReducer::new();
    let key = crate::source::hosted::hosted_thread_key("unused");
    let key = ThreadKey {
        server_id: crate::store::chat::APPLE_SERVER_ID.into(),
        thread_id: key.thread_id,
    };
    let _chat = reducer.chat_subscribe(&key);
    let ingest = |events: Vec<ExternalSourceEvent>| {
        reducer.chat_ingest_external(&key, SourceKind::Apple, events)
    };
    let snapshot = |text: &str| ExternalSourceEvent::TextSnapshot {
        item_id: "a1".into(),
        channel: TextChannel::Answer,
        text: text.into(),
    };
    let apple_view = || reducer.chat_view(&key, &ChatViewOptions::default());

    ingest(vec![
        ExternalSourceEvent::UserMessage {
            client_msg_id: "c1".into(),
            text: "What is OLED?".into(),
        },
        ExternalSourceEvent::TurnAccepted {
            client_msg_id: Some("c1".into()),
            turn_id: "t1".into(),
        },
        ExternalSourceEvent::TurnStarted {
            turn_id: "t1".into(),
        },
        snapshot("OLED"),
        snapshot("OLED is"),
        snapshot("OLED stands for"),
    ]);
    let rewritten = apple_view();
    assert_eq!(rewritten.phase, TurnPhase::Streaming);
    assert_eq!(rewritten.rows[1].answer_text(), Some("OLED stands for"));

    ingest(vec![ExternalSourceEvent::StopRequested]);
    assert_eq!(apple_view().phase, TurnPhase::Stopping);
    ingest(vec![ExternalSourceEvent::StopFailed]);
    assert_eq!(apple_view().phase, TurnPhase::Streaming);
    ingest(vec![
        ExternalSourceEvent::StopRequested,
        ExternalSourceEvent::TurnSettled {
            outcome: TurnOutcome::Interrupted,
        },
        ExternalSourceEvent::UserMessage {
            client_msg_id: "c2".into(),
            text: "Go on".into(),
        },
    ]);
    // Swift restores the stored session while "Go on" is still unsent.
    ingest(vec![ExternalSourceEvent::ReplaceTranscript {
        messages: vec![
            crate::source::ExternalTranscriptMessage {
                id: "c1".into(),
                role: crate::source::ExternalMessageRole::User,
                text: "What is OLED?".into(),
                turn_id: Some("t1".into()),
            },
            crate::source::ExternalTranscriptMessage {
                id: "a1".into(),
                role: crate::source::ExternalMessageRole::Assistant,
                text: "OLED stands for".into(),
                turn_id: Some("t1".into()),
            },
        ],
    }]);
    let restored = apple_view();
    assert_eq!(ids(&restored), vec!["user:c1", "answer:a1", "user:c2"]);
    assert!(matches!(
        restored.rows[2].kind,
        TimelineRowKind::User {
            delivery: MessageDelivery::Pending,
            ..
        }
    ));
}

/// The connection drops mid-turn and the turn finishes while offline: the
/// thread read after reconnecting settles the chat without a TurnCompleted.
#[test]
fn reconnect_mid_turn_settles_from_the_snapshot() {
    let reducer = AppStoreReducer::new();
    reducer.upsert_thread_snapshot(thread("codex"));
    let _chat = reducer.chat_subscribe(&key());
    reducer.apply_ui_event(&turn_started("t1"));
    reducer.apply_ui_event(&started("t1", agent_message("a1", "")));
    reducer.apply_ui_event(&UiEvent::MessageDelta {
        key: key(),
        item_id: "a1".into(),
        delta: "Half".into(),
    });
    assert_eq!(view(&reducer).phase, TurnPhase::Streaming);

    // Thread read after reconnect: the turn is gone and the answer complete.
    let mut reloaded = reducer.thread_snapshot(&key()).expect("thread");
    reloaded.active_turn_id = None;
    reloaded.info.status = ThreadSummaryStatus::Idle;
    reducer.upsert_thread_snapshot(reloaded);
    let settled = view(&reducer);
    assert_eq!(
        settled.phase,
        TurnPhase::Settled {
            outcome: TurnOutcome::Completed
        }
    );
}

/// A chat opened mid-turn on a thread waiting for an approval shows the
/// agent waiting, though the hub never saw the turn's events.
#[test]
fn chat_opened_mid_turn_reconciles_running_turn() {
    let reducer = AppStoreReducer::new();
    let mut running = thread("codex");
    running.active_turn_id = Some("t1".into());
    running.info.status = ThreadSummaryStatus::Active;
    reducer.upsert_thread_snapshot(running);
    // Events before any chat is open are not tracked at all.
    reducer.apply_ui_event(&turn_started("t1"));
    assert!(!reducer.chat.is_tracked(&key()));

    let _chat = reducer.chat_subscribe(&key());
    assert_eq!(view(&reducer).phase, TurnPhase::Thinking);

    // An approval the server is waiting on puts the chat in AwaitingInput;
    // once the snapshot no longer lists it the turn is thinking again.
    reducer.mutate_snapshot_for_test(|snapshot| {
        snapshot.pending_approvals.push(crate::types::PendingApproval {
            id: "approval-1".into(),
            server_id: "srv".into(),
            kind: crate::types::ApprovalKind::Permissions,
            thread_id: Some("thread".into()),
            turn_id: Some("t1".into()),
            item_id: None,
            command: None,
            path: None,
            grant_root: None,
            cwd: None,
            reason: None,
        });
    });
    assert_eq!(view(&reducer).phase, TurnPhase::AwaitingInput);
    reducer.mutate_snapshot_for_test(|snapshot| snapshot.pending_approvals.clear());
    assert_eq!(view(&reducer).phase, TurnPhase::Thinking);
}

/// Outbox entries reconcile by turn binding, never by text: the learner
/// re-sends words already in the history while the thread was not loaded.
#[test]
fn outbox_echo_reconciles_by_turn_not_text() {
    let reducer = AppStoreReducer::new();
    let local = reducer
        .stage_local_user_message_overlay(&key(), &text_input("yes"))
        .expect("outbox id");
    reducer.bind_local_user_message_overlay_to_turn(&key(), &local, "t2");

    // The thread loads with an older "yes" from t1 but no echo for t2 yet.
    let mut loaded = thread("codex");
    loaded.items = vec![
        crate::store::chat::user_item("old", "yes", Some("t1")),
        crate::store::chat::assistant_item("a1", "Great.", Some("t1")),
    ];
    reducer.upsert_thread_snapshot(loaded);
    let _chat = reducer.chat_subscribe(&key());
    let before_echo = view(&reducer);
    let local_row = format!("user:{local}");
    assert_eq!(
        ids(&before_echo),
        vec!["user:turn:t1", "answer:a1", local_row.as_str()],
        "the pending message is not mistaken for the old one"
    );

    reducer.apply_ui_event(&completed("t2", user_message("srv-u2", "yes")));
    let echoed = view(&reducer);
    assert_eq!(
        ids(&echoed),
        vec!["user:turn:t1", "answer:a1", local_row.as_str()],
        "the echo replaces the outbox entry under the same row id"
    );
    let users = echoed
        .rows
        .iter()
        .filter(|row| matches!(row.kind, TimelineRowKind::User { .. }))
        .count();
    assert_eq!(users, 2);
}

/// Chat state lives only while a chat is open (or work is pending).
#[test]
fn chat_state_is_released_with_the_last_subscriber() {
    let reducer = AppStoreReducer::new();
    reducer.upsert_thread_snapshot(thread("codex"));
    let first = reducer.chat_subscribe(&key());
    let second = reducer.chat_subscribe(&key());
    reducer.apply_ui_event(&turn_started("t1"));
    drop(first);
    reducer.chat_unsubscribe(&key());
    assert!(reducer.chat.is_tracked(&key()));
    drop(second);
    reducer.chat_unsubscribe(&key());
    assert!(!reducer.chat.is_tracked(&key()));

    // A source-owned transcript with a running turn waits for the settle.
    let hosted = crate::source::hosted::hosted_thread_key("s1");
    let _rx = reducer.chat_subscribe(&hosted);
    reducer.apply_source_events(
        &hosted,
        SourceKind::Hosted,
        &[crate::source::SourceEvent::TurnStarted {
            turn_id: "m1".into(),
        }],
    );
    reducer.chat_unsubscribe(&hosted);
    assert!(reducer.chat.is_tracked(&hosted));
    reducer.apply_source_events(
        &hosted,
        SourceKind::Hosted,
        &[crate::source::SourceEvent::TurnSettled {
            turn_id: Some("m1".into()),
            outcome: TurnOutcome::Completed,
        }],
    );
    assert!(!reducer.chat.is_tracked(&hosted));

    // Removing a thread drops its chat state once no chat is open on it.
    let _rx = reducer.chat_subscribe(&key());
    reducer.remove_thread(&key());
    assert!(reducer.chat.is_tracked(&key()), "an open chat keeps its state");
    reducer.chat_unsubscribe(&key());
    assert!(!reducer.chat.is_tracked(&key()));
}

impl AppStoreReducer {
    fn ingest_hermes_progress(&self, label: &str) {
        self.chat_ingest_external(
            &key(),
            SourceKind::app_server("hermes"),
            vec![ExternalSourceEvent::Progress {
                label: Some(label.into()),
            }],
        );
    }
}

#[test]
fn fixture_discussion_options_drop_plan_rows_but_keep_the_prose() {
    let reducer = AppStoreReducer::new();
    reducer.upsert_thread_snapshot(thread("codex"));
    let _chat = reducer.chat_subscribe(&key());
    reducer.apply_ui_event(&turn_started("t1"));
    let text = "Here is a route.\n\n```learnfold-plan\n# Bonds\nSummary: x\n```";
    reducer.apply_ui_event(&completed("t1", agent_message("a1", text)));
    reducer.apply_ui_event(&turn_completed("t1"));

    let has_plan = |view: &ChatView| {
        view.rows
            .iter()
            .any(|row| matches!(row.kind, TimelineRowKind::Plan { .. }))
    };
    assert!(has_plan(&view(&reducer)), "course chat keeps plan rows");

    let discussion = reducer.chat_view(
        &key(),
        &ChatViewOptions {
            hides_plan_rows: true,
            ..ChatViewOptions::default()
        },
    );
    assert!(!has_plan(&discussion), "discussion drops plan rows");
    assert!(
        discussion
            .rows
            .iter()
            .any(|row| row.answer_text() == Some("Here is a route.")),
        "the prose around the fence stays visible"
    );
}

fn course_fetch(id: &str, page_id: &str, status: &str, result: Value) -> upstream::ThreadItem {
    item(json!({"type": "mcpToolCall", "id": id, "server": "learnfold_course",
        "tool": "native-editor-fetch", "status": status, "arguments": {"id": page_id},
        "appContext": null, "pluginId": null, "result": result, "error": null,
        "durationMs": null}))
}

fn session_summary(reducer: &AppStoreReducer) -> crate::store::AppSessionSummary {
    crate::store::AppSnapshotRecord::try_from(reducer.snapshot())
        .expect("snapshot record")
        .session_summaries
        .into_iter()
        .find(|summary| summary.key == key())
        .expect("session summary")
}

/// The background banner reads `current_activity` and `last_turn_outcome`
/// from the session summary while `last_tool_label` keeps its raw value.
#[test]
fn session_summary_tracks_course_fetch_lifecycle_and_failed_outcome() {
    use crate::store::AppTurnActivityKind;
    let reducer = AppStoreReducer::new();
    reducer.upsert_thread_snapshot(thread("codex"));
    let page = "4f6c2b1a-0d3e-4c7a-9b52-8e1f0a6d3c21";

    reducer.apply_ui_event(&turn_started("t1"));
    let queued = session_summary(&reducer);
    assert_eq!(
        queued.current_activity.map(|activity| activity.kind),
        Some(AppTurnActivityKind::Starting)
    );
    reducer.apply_ui_event(&completed("t1", user_message("u1", "Write the lesson")));
    reducer.apply_ui_event(&started(
        "t1",
        course_fetch(
            "f1",
            &format!("native-editor://page/{page}"),
            "inProgress",
            Value::Null,
        ),
    ));
    let reading = session_summary(&reducer);
    let activity = reading.current_activity.expect("activity");
    assert_eq!(activity.kind, AppTurnActivityKind::ReadingCourse);
    assert_eq!(activity.page_id.as_deref(), Some(page));
    assert!(activity.is_running);
    assert_eq!(
        reading.last_tool_label.as_deref(),
        Some("MCP native-editor-fetch")
    );

    let page_markdown = json!({"object": "page_markdown", "id": page,
        "title": "Light Reactions", "markdown": "# Light Reactions"});
    reducer.apply_ui_event(&completed(
        "t1",
        course_fetch(
            "f1",
            &format!("native-editor://page/{page}"),
            "completed",
            json!({"content": [{"type": "text", "text": page_markdown.to_string()}],
                "structuredContent": page_markdown, "_meta": null}),
        ),
    ));
    let thinking = session_summary(&reducer);
    let activity = thinking.current_activity.expect("activity");
    assert_eq!(activity.kind, AppTurnActivityKind::Thinking);
    assert_eq!(activity.subject, None);
    assert_eq!(activity.course_pages_read, 1);
    assert_eq!(
        thinking.last_tool_label.as_deref(),
        Some("MCP native-editor-fetch"),
        "the raw label stays for the dashboard"
    );
    assert_eq!(thinking.last_turn_outcome, None);

    reducer.apply_ui_event(&UiEvent::TurnCompleted {
        key: key(),
        turn_id: "t1".into(),
        error: Some("Model overloaded".into()),
        interrupted: false,
    });
    let failed = session_summary(&reducer);
    assert!(!failed.has_active_turn);
    assert_eq!(
        failed.last_turn_outcome,
        Some(TurnOutcome::Failed {
            message: "Model overloaded".into()
        })
    );

    reducer.apply_ui_event(&turn_started("t2"));
    let restarted = session_summary(&reducer);
    assert_eq!(restarted.last_turn_outcome, None);
    assert_eq!(
        restarted.current_activity.map(|activity| activity.kind),
        Some(AppTurnActivityKind::Starting)
    );
}

fn server_event(notification: upstream::ServerNotification) -> UiEvent {
    let processor = EventProcessor::new();
    let mut events = processor.subscribe();
    processor.process_notification("srv", "codex".into(), &notification);
    events.try_recv().expect("server notification event")
}

fn status_changed(status: upstream::ThreadStatus) -> UiEvent {
    server_event(upstream::ServerNotification::ThreadStatusChanged(
        upstream::ThreadStatusChangedNotification {
            thread_id: "thread".into(),
            status,
        },
    ))
}

fn turn_finished(turn: &str, status: &str, error: Option<&str>) -> UiEvent {
    let turn: upstream::Turn = serde_json::from_value(json!({"id": turn, "items": [],
        "status": status,
        "error": error.map(|message| json!({"message": message, "codexErrorInfo": null})),
        "startedAt": null, "completedAt": null, "durationMs": null}))
    .expect("turn");
    server_event(upstream::ServerNotification::TurnCompleted(
        upstream::TurnCompletedNotification {
            thread_id: "thread".into(),
            turn,
        },
    ))
}

/// Upstream publishes thread/status/changed before turn/completed. A failure
/// never reads as a clean finish in the gap, a stop's idle gap carries no
/// outcome yet, and turn/completed settles the exact outcome.
#[test]
fn session_summary_outcome_follows_upstream_status_then_turn_completed_order() {
    let reducer = AppStoreReducer::new();
    reducer.upsert_thread_snapshot(thread("codex"));

    reducer.apply_ui_event(&turn_started("t1"));
    reducer.apply_ui_event(&status_changed(upstream::ThreadStatus::SystemError));
    let errored = session_summary(&reducer);
    assert!(!errored.has_active_turn);
    assert!(matches!(
        errored.last_turn_outcome,
        Some(TurnOutcome::Failed { .. })
    ));
    reducer.apply_ui_event(&turn_finished("t1", "failed", Some("Model overloaded")));
    let failed = session_summary(&reducer);
    assert!(!failed.has_active_turn);
    assert_eq!(
        failed.last_turn_outcome,
        Some(TurnOutcome::Failed {
            message: "Model overloaded".into()
        })
    );

    reducer.apply_ui_event(&turn_started("t2"));
    reducer.apply_ui_event(&status_changed(upstream::ThreadStatus::Idle));
    let stopping = session_summary(&reducer);
    assert!(!stopping.has_active_turn);
    assert_eq!(stopping.last_turn_outcome, None);
    reducer.apply_ui_event(&turn_finished("t2", "interrupted", None));
    assert_eq!(
        session_summary(&reducer).last_turn_outcome,
        Some(TurnOutcome::Interrupted)
    );

    reducer.apply_ui_event(&turn_started("t3"));
    reducer.apply_ui_event(&status_changed(upstream::ThreadStatus::Idle));
    assert_eq!(session_summary(&reducer).last_turn_outcome, None);
    reducer.apply_ui_event(&turn_finished("t3", "completed", None));
    assert_eq!(
        session_summary(&reducer).last_turn_outcome,
        Some(TurnOutcome::Completed)
    );

    // A system error while nothing runs does not rewrite the last outcome.
    reducer.apply_ui_event(&status_changed(upstream::ThreadStatus::SystemError));
    assert_eq!(
        session_summary(&reducer).last_turn_outcome,
        Some(TurnOutcome::Completed)
    );
}
