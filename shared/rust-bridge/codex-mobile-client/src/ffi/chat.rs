//! Per-thread chat subscription and source intake over UniFFI.
//!
//! `AppStore.subscribe_chat(key)` returns a [`ChatSubscription`] whose
//! `next_update()` yields a `Snapshot` first, then diffs. The subscription
//! derives the timeline at most once per frame, so a burst of deltas costs
//! one derivation and arrives as one `TextAppended` per growing row.
//!
//! `AppStore.ingest_source_events` is the intake for sources that run on the
//! platform (Apple Foundation Models). It is store-local, not a server
//! operation, so it lives on `AppStore` rather than `AppClient`.

use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::sync::watch;
use tokio::time::Instant;

use crate::ffi::ClientError;
use crate::ffi::app_store::AppStore;
use crate::source::{ExternalSourceEvent, SourceKind};
use crate::store::AppStoreReducer;
use crate::store::chat::{APPLE_SERVER_ID, ChatUpdate, ChatView, ChatViewOptions, diff_views};
use crate::types::ThreadKey;

/// Minimum spacing between deliveries: about one per 60 Hz frame.
const CHAT_FRAME: Duration = Duration::from_millis(16);

#[derive(uniffi::Object)]
pub struct ChatSubscription {
    reducer: Arc<AppStoreReducer>,
    key: ThreadKey,
    options: ChatViewOptions,
    force_snapshot: AtomicBool,
    state: tokio::sync::Mutex<ChatSubscriberState>,
}

struct ChatSubscriberState {
    rx: watch::Receiver<u64>,
    pending: VecDeque<ChatUpdate>,
    last: Option<ChatView>,
    last_delivery: Option<Instant>,
}

impl ChatSubscription {
    pub(crate) fn new(
        reducer: Arc<AppStoreReducer>,
        key: ThreadKey,
        options: ChatViewOptions,
    ) -> Self {
        let rx = reducer.chat_subscribe(&key);
        Self {
            reducer,
            key,
            options,
            force_snapshot: AtomicBool::new(false),
            state: tokio::sync::Mutex::new(ChatSubscriberState {
                rx,
                pending: VecDeque::new(),
                last: None,
                last_delivery: None,
            }),
        }
    }
}

impl Drop for ChatSubscription {
    /// The last subscription of a thread releases its chat state (see
    /// `ChatHub::unsubscribe`).
    fn drop(&mut self) {
        self.reducer.chat_unsubscribe(&self.key);
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl ChatSubscription {
    /// The next change for this thread. The first call returns a
    /// `Snapshot`. Updates with `seq` at or below an applied snapshot's
    /// `seq` never arrive.
    pub async fn next_update(&self) -> Result<ChatUpdate, ClientError> {
        let mut state = self.state.lock().await;
        loop {
            // A requested resync wins over diffs queued before it: those
            // describe rows the platform has dropped.
            if state.last.is_none() || self.force_snapshot.swap(false, Ordering::AcqRel) {
                state.rx.borrow_and_update();
                let view = self.reducer.chat_view(&self.key, &self.options);
                state.last = Some(view.clone());
                state.last_delivery = Some(Instant::now());
                state.pending.clear();
                return Ok(view.into_snapshot());
            }
            if let Some(update) = state.pending.pop_front() {
                return Ok(update);
            }
            state
                .rx
                .changed()
                .await
                .map_err(|_| ClientError::EventClosed("chat subscription closed".to_string()))?;
            // Let further changes accumulate until the next frame.
            if let Some(last) = state.last_delivery {
                let due = last + CHAT_FRAME;
                if Instant::now() < due {
                    tokio::time::sleep_until(due).await;
                }
            }
            if self.force_snapshot.load(Ordering::Acquire) {
                continue;
            }
            state.rx.borrow_and_update();
            let view = self.reducer.chat_view(&self.key, &self.options);
            let updates = match state.last.as_ref() {
                Some(last) => diff_views(last, &view),
                None => vec![view.clone().into_snapshot()],
            };
            state.last = Some(view);
            if updates.is_empty() {
                continue;
            }
            state.last_delivery = Some(Instant::now());
            state.pending.extend(updates);
        }
    }

    /// Makes the next `next_update()` a full `Snapshot` (for example after
    /// the platform dropped its row cache).
    pub fn resync(&self) {
        self.force_snapshot.store(true, Ordering::Release);
        self.reducer.chat_touch(&self.key);
    }
}

#[uniffi::export]
impl AppStore {
    /// Chat timeline, turn phase and connection for one thread, as a
    /// snapshot followed by diffs.
    pub fn subscribe_chat(&self, key: ThreadKey) -> ChatSubscription {
        ChatSubscription::new(
            Arc::clone(&self.inner.app_store),
            key,
            ChatViewOptions::default(),
        )
    }

    pub fn subscribe_chat_with_options(
        &self,
        key: ThreadKey,
        options: ChatViewOptions,
    ) -> ChatSubscription {
        ChatSubscription::new(Arc::clone(&self.inner.app_store), key, options)
    }

    /// Intake for platform-run sources. Swift hands raw events (optimistic
    /// messages, cumulative partials, tool starts/ends, stop requests,
    /// settles) across; Rust owns the items, normalization and turn phase.
    /// For app-server threads only `Progress`, `StopRequested` and
    /// `StopFailed` are accepted. A source-owned transcript is dropped when
    /// its last chat subscription closes with no turn running, so a platform
    /// re-sends `ReplaceTranscript` when it reopens that chat.
    pub fn ingest_source_events(
        &self,
        key: ThreadKey,
        source: SourceKind,
        events: Vec<ExternalSourceEvent>,
    ) {
        self.inner
            .app_store
            .chat_ingest_external(&key, source, events);
    }
}

/// Store thread key of a hosted Think session. Hosted turns are written to
/// the store under this key by `HostedAgentClient.send`.
#[uniffi::export]
pub fn hosted_chat_thread_key(session_id: String) -> ThreadKey {
    crate::source::hosted::hosted_thread_key(&session_id)
}

/// Store thread key for an Apple Foundation Models session. Use it with
/// `AppStore.ingest_source_events` and `AppStore.subscribe_chat`.
#[uniffi::export]
pub fn apple_chat_thread_key(session_id: String) -> ThreadKey {
    ThreadKey {
        server_id: APPLE_SERVER_ID.to_string(),
        thread_id: session_id,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source::{ExternalSourceEvent, TextChannel};

    #[test]
    fn subscription_sends_snapshot_then_coalesced_text() {
        let reducer = Arc::new(AppStoreReducer::new());
        let key = apple_chat_thread_key("s1".into());
        let subscription =
            ChatSubscription::new(Arc::clone(&reducer), key.clone(), ChatViewOptions::default());
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        runtime.block_on(async {
            let first = subscription.next_update().await.expect("snapshot");
            assert!(matches!(first, ChatUpdate::Snapshot { ref rows, .. } if rows.is_empty()));

            reducer.chat_ingest_external(
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
                        text: "Hel".into(),
                    },
                ],
            );
            let rows = subscription.next_update().await.expect("rows");
            let ChatUpdate::RowsChanged { upserts, order, .. } = rows else {
                panic!("expected rows, got {rows:?}");
            };
            // The optimistic row keeps its `user:<client id>` after binding.
            assert_eq!(order, vec!["user:c1", "answer:a1"]);
            assert_eq!(upserts.len(), 2);
            let phase = subscription.next_update().await.expect("phase");
            assert!(matches!(phase, ChatUpdate::PhaseChanged { .. }));

            // Many deltas inside one frame arrive as one append.
            for piece in ["l", "o", " ", "there"] {
                reducer.chat_ingest_external(
                    &key,
                    SourceKind::Apple,
                    vec![ExternalSourceEvent::TextDelta {
                        item_id: "a1".into(),
                        channel: TextChannel::Answer,
                        text: piece.into(),
                    }],
                );
            }
            let appended = subscription.next_update().await.expect("append");
            assert!(
                matches!(appended, ChatUpdate::TextAppended { ref row_id, ref text, .. }
                    if row_id == "answer:a1" && text == "lo there"),
                "{appended:?}"
            );

            subscription.resync();
            let resynced = subscription.next_update().await.expect("snapshot");
            assert!(matches!(resynced, ChatUpdate::Snapshot { ref rows, .. } if rows.len() == 2));
        });
    }

    #[test]
    fn resync_drops_diffs_queued_before_it() {
        let reducer = Arc::new(AppStoreReducer::new());
        let key = apple_chat_thread_key("s2".into());
        let subscription =
            ChatSubscription::new(Arc::clone(&reducer), key.clone(), ChatViewOptions::default());
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        runtime.block_on(async {
            subscription.next_update().await.expect("snapshot");
            reducer.chat_ingest_external(
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
                ],
            );
            // RowsChanged is returned; PhaseChanged stays queued.
            let rows = subscription.next_update().await.expect("rows");
            assert!(matches!(rows, ChatUpdate::RowsChanged { .. }), "{rows:?}");
            subscription.resync();
            let next = subscription.next_update().await.expect("snapshot");
            assert!(matches!(next, ChatUpdate::Snapshot { .. }), "{next:?}");
        });
    }
}
