use std::any::Any;
use std::collections::HashSet;
use std::sync::Arc;

use crate::MobileClient;
use crate::conversation_uniffi::{HydratedConversationItem, HydratedConversationItemContent};
use crate::session::connection::ServerSession;
use crate::store::ThreadSnapshot;
use crate::transport::RpcError;
use crate::types::server_requests::{
    AppListThreadTurnsResponse, AppTurnState, AppTurnStatus, AppTurnsSortDirection,
};
use crate::types::{AgentRuntimeKind, ThreadInfo, ThreadKey};
use codex_app_server_protocol as upstream;

impl MobileClient {
    /// Repair terminal turns from a bounded newest-first query without
    /// fetching the full archive or moving the older-history cursor.
    pub(crate) fn reconcile_latest_terminal_turns(
        &self,
        server_id: &str,
        thread_id: &str,
        page: &AppListThreadTurnsResponse,
        session: &Arc<ServerSession>,
    ) {
        // Hold the session fence through reduction: a completed query from
        // an old connection must not overwrite its replacement's state.
        let Ok(sessions) = self.sessions.read() else {
            return;
        };
        if !sessions
            .get(server_id)
            .is_some_and(|current| Arc::ptr_eq(current, session))
        {
            return;
        }
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let changed = self.app_store.mutate_thread_with_result(&key, |thread| {
            let changed = merge_latest_terminal_turns(thread, page);
            (
                changed,
                crate::store::chat::pending_fence_question(&thread.items),
            )
        });
        let Some((changed, question)) = changed else {
            return;
        };
        // turn/start can be acknowledged while all notifications are missed.
        // Its chat machine then has an accepted turn even if the canonical
        // snapshot never received TurnStarted. Settle only that exact id.
        for turn in &page.turn_states {
            if let Some(outcome) = terminal_turn_outcome(turn) {
                self.app_store.chat.settle_matching_turn_if_tracked(
                    &key,
                    &turn.turn_id,
                    outcome,
                    question.clone(),
                    crate::store::chat::now_ms(),
                );
            }
        }
        if changed {
            self.app_store.emit_thread_upsert(&key);
        }
    }

    /// Reconcile direct public RPC calls into the canonical app store.
    ///
    /// The public client RPC surface calls this hook after the upstream RPC
    /// returns. The reconciliation policy lives here:
    /// - snapshot/query RPCs reduce authoritative responses directly
    /// - mutations without authoritative payloads trigger targeted refreshes
    /// - event-complete RPCs are no-ops because upstream notifications drive
    ///   the reducer already
    pub async fn reconcile_public_rpc<P: Any, R: Any>(
        &self,
        wire_method: &str,
        server_id: &str,
        params: Option<&P>,
        response: &R,
    ) -> Result<(), RpcError> {
        if wire_method == "turn/start" {
            tracing::info!(
                "reconcile_public_rpc wire_method={} server_id={}",
                wire_method,
                server_id
            );
        }
        match wire_method {
            "thread/start" => {
                let response = downcast_public_rpc_response::<upstream::ThreadStartResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_start_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/list" => {
                let response = downcast_public_rpc_response::<upstream::ThreadListResponse>(
                    wire_method,
                    response,
                )?;
                self.sync_thread_list(server_id, &response.data)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/read" => {
                let response = downcast_public_rpc_response::<upstream::ThreadReadResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_read_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/resume" => {
                let response = downcast_public_rpc_response::<upstream::ThreadResumeResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_resume_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/fork" => {
                let response = downcast_public_rpc_response::<upstream::ThreadForkResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_thread_fork_response(server_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "thread/rollback" => {
                let response = downcast_public_rpc_response::<upstream::ThreadRollbackResponse>(
                    wire_method,
                    response,
                )?;
                let params = downcast_public_rpc_params::<upstream::ThreadRollbackParams>(
                    wire_method,
                    params.map(|value| value as &dyn Any),
                )?;
                self.apply_thread_rollback_response(server_id, &params.thread_id, response)
                    .map(|_| ())
                    .map_err(RpcError::Deserialization)
            }
            "account/read" => {
                let response = downcast_public_rpc_response::<upstream::GetAccountResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_account_response(server_id, response);
                Ok(())
            }
            "account/rateLimits/read" => {
                let response = downcast_public_rpc_response::<
                    upstream::GetAccountRateLimitsResponse,
                >(wire_method, response)?;
                // `account/rateLimits/read` is Codex-runtime specific upstream.
                self.apply_account_rate_limits_response(server_id, "codex".to_string(), response);
                Ok(())
            }
            "model/list" => {
                let response = downcast_public_rpc_response::<upstream::ModelListResponse>(
                    wire_method,
                    response,
                )?;
                self.apply_model_list_response(server_id, response);
                Ok(())
            }
            "account/login/start" => self.sync_server_account(server_id).await,
            "account/logout" => self.sync_server_account_after_logout(server_id).await,
            _ => Ok(()),
        }
    }

    pub(crate) fn clear_server_account(&self, server_id: &str) {
        self.app_store.update_server_account(server_id, None, false);
    }

    pub fn apply_account_response(&self, server_id: &str, response: &upstream::GetAccountResponse) {
        self.app_store.update_server_account(
            server_id,
            response.account.clone().map(Into::into),
            response.requires_openai_auth,
        );
    }

    pub fn apply_account_rate_limits_response(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        response: &upstream::GetAccountRateLimitsResponse,
    ) {
        self.app_store.update_server_rate_limits(
            server_id,
            runtime_kind,
            Some(response.rate_limits.clone().into()),
        );
    }

    pub fn apply_model_list_response(
        &self,
        server_id: &str,
        response: &upstream::ModelListResponse,
    ) {
        self.app_store.update_server_models(
            server_id,
            Some(response.data.iter().cloned().map(Into::into).collect()),
        );
    }

    pub fn sync_thread_list(
        &self,
        server_id: &str,
        threads: &[upstream::Thread],
    ) -> Result<Vec<ThreadInfo>, String> {
        let threads = threads
            .iter()
            .cloned()
            .filter_map(crate::thread_info_from_upstream_thread)
            .collect::<Vec<_>>();
        self.app_store.sync_thread_list(server_id, &threads);
        Ok(threads)
    }

    pub fn upsert_thread_list_page(
        &self,
        server_id: &str,
        threads: &[upstream::Thread],
    ) -> Vec<ThreadInfo> {
        self.upsert_thread_list_page_for_runtime(server_id, "codex".to_string(), threads)
    }

    pub fn upsert_thread_list_page_for_runtime(
        &self,
        server_id: &str,
        runtime_kind: AgentRuntimeKind,
        threads: &[upstream::Thread],
    ) -> Vec<ThreadInfo> {
        let threads = threads
            .iter()
            .cloned()
            .filter_map(crate::thread_info_from_upstream_thread)
            .collect::<Vec<_>>();
        self.app_store
            .upsert_thread_list_page_for_runtime(server_id, runtime_kind, &threads);
        threads
    }

    pub fn finalize_thread_list_sync(
        &self,
        server_id: &str,
        thread_ids: impl IntoIterator<Item = String>,
    ) {
        let incoming_ids = thread_ids.into_iter().collect();
        self.app_store
            .finalize_thread_list_sync(server_id, &incoming_ids);
    }

    pub(crate) async fn sync_server_account_after_logout(
        &self,
        server_id: &str,
    ) -> Result<(), RpcError> {
        match self.sync_server_account(server_id).await {
            Ok(()) => Ok(()),
            Err(error) => {
                self.clear_server_account(server_id);
                Err(error)
            }
        }
    }

    pub fn apply_thread_start_response(
        &self,
        server_id: &str,
        response: &upstream::ThreadStartResponse,
    ) -> Result<ThreadKey, String> {
        let mut snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            Some(response.model.clone()),
            response
                .reasoning_effort
                .clone()
                .map(Into::into)
                .map(crate::reasoning_effort_string),
            Some(response.approval_policy.clone().into()),
            Some(response.sandbox.clone().into()),
        )
        .map_err(|e| e.to_string())?;
        // A freshly-started thread has no turns to page; mark the initial
        // page as loaded so UI does not auto-fire `thread/turns/list`
        // (which the server rejects until the first user message lands).
        snapshot.initial_turns_loaded = true;
        snapshot.older_turns_cursor = None;
        let key = snapshot.key.clone();
        let existing = self.app_store.thread_snapshot(&key);
        crate::reconcile_active_turn(existing.as_ref(), &mut snapshot, &response.thread.turns);
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub fn apply_thread_read_response(
        &self,
        server_id: &str,
        response: &upstream::ThreadReadResponse,
    ) -> Result<ThreadKey, String> {
        let mut snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            None,
            None,
            response.approval_policy.clone().map(Into::into),
            response.sandbox.clone().map(Into::into),
        )
        .map_err(|e| e.to_string())?;
        let key = snapshot.key.clone();
        let existing = self.app_store.thread_snapshot(&key);
        // Share the preserve-on-empty merge with resume/fork. A paginated
        // v0.125+ server returns `thread.turns: []` on thread/read — we
        // must keep any items + `older_turns_cursor` the prior
        // `load_thread_turns_page` stored. A legacy (or authoritative)
        // response with embedded turns clears the cursor because the
        // embedded list is the full history.
        apply_pagination_merge(existing.as_ref(), &mut snapshot, &response.thread.turns);
        // thread/read is authoritative for `initial_turns_loaded`: if the
        // server returned no turns AND no prior state exists, treat the
        // thread as having no history rather than a pending page load, so
        // the iOS spinner doesn't stick (task #10 invariant).
        if existing.is_none() && response.thread.turns.is_empty() {
            snapshot.initial_turns_loaded = true;
        }
        crate::reconcile_active_turn(existing.as_ref(), &mut snapshot, &response.thread.turns);
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub fn apply_thread_resume_response(
        &self,
        server_id: &str,
        response: &upstream::ThreadResumeResponse,
    ) -> Result<ThreadKey, String> {
        let mut snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            Some(response.model.clone()),
            response
                .reasoning_effort
                .clone()
                .map(Into::into)
                .map(crate::reasoning_effort_string),
            Some(response.approval_policy.clone().into()),
            Some(response.sandbox.clone().into()),
        )
        .map_err(|e| e.to_string())?;
        let key = snapshot.key.clone();
        let existing = self.app_store.thread_snapshot(&key);
        apply_pagination_merge(existing.as_ref(), &mut snapshot, &response.thread.turns);
        crate::reconcile_active_turn(existing.as_ref(), &mut snapshot, &response.thread.turns);
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    pub fn apply_thread_fork_response(
        &self,
        server_id: &str,
        response: &upstream::ThreadForkResponse,
    ) -> Result<ThreadKey, String> {
        let mut snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            Some(response.model.clone()),
            response
                .reasoning_effort
                .clone()
                .map(Into::into)
                .map(crate::reasoning_effort_string),
            Some(response.approval_policy.clone().into()),
            Some(response.sandbox.clone().into()),
        )
        .map_err(|e| e.to_string())?;
        let key = snapshot.key.clone();
        let existing = self.app_store.thread_snapshot(&key);
        apply_pagination_merge(existing.as_ref(), &mut snapshot, &response.thread.turns);
        crate::reconcile_active_turn(existing.as_ref(), &mut snapshot, &response.thread.turns);
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(key)
    }

    /// Merge a paged `thread/turns/list` response into the canonical thread
    /// snapshot.
    ///
    /// `direction` matches the `sortDirection` the client sent with the
    /// request. For `Descending` (newest-first) pages the hydrated turns
    /// are in newest-first order; the store keeps items in chronological
    /// (ascending) order, so this reverses per-page before merging. Turns
    /// already in the store (by `source_turn_id`) are deduped.
    pub fn apply_thread_turns_page(
        &self,
        server_id: &str,
        thread_id: &str,
        page: &AppListThreadTurnsResponse,
        direction: AppTurnsSortDirection,
    ) -> Result<(), String> {
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let mut thread = match self.app_store.thread_snapshot(&key) {
            Some(thread) => thread,
            None => return Err(format!("thread {thread_id} not in store")),
        };
        merge_paged_turns(&mut thread, page, direction);
        // Diagnostic for the pagination-cursor-lost bug (task #13): log
        // the post-merge state so platform teams can correlate a logcat
        // entry here with the `AppLoadThreadTurnsOutcome` they received.
        tracing::info!(
            target: "store",
            server_id,
            thread_id,
            item_count = thread.items.len(),
            older_turns_cursor = thread.older_turns_cursor.as_deref().unwrap_or(""),
            initial_turns_loaded = thread.initial_turns_loaded,
            "apply_thread_turns_page merged"
        );
        self.app_store.upsert_thread_snapshot(thread);
        Ok(())
    }

    pub fn apply_thread_rollback_response(
        &self,
        server_id: &str,
        thread_id: &str,
        response: &upstream::ThreadRollbackResponse,
    ) -> Result<ThreadKey, String> {
        let key = ThreadKey {
            server_id: server_id.to_string(),
            thread_id: thread_id.to_string(),
        };
        let current = self.app_store.thread_snapshot(&key);
        let mut snapshot = crate::thread_snapshot_from_upstream_thread_with_overrides(
            server_id,
            response.thread.clone(),
            current.as_ref().and_then(|thread| thread.model.clone()),
            current.as_ref().and_then(|thread| {
                thread
                    .reasoning_effort
                    .as_deref()
                    .and_then(crate::reasoning_effort_from_string)
                    .map(crate::reasoning_effort_string)
            }),
            current
                .as_ref()
                .and_then(|thread| thread.effective_approval_policy.clone()),
            current
                .as_ref()
                .and_then(|thread| thread.effective_sandbox_policy.clone()),
        )
        .map_err(|e| e.to_string())?;
        if let Some(current) = current.as_ref() {
            crate::copy_thread_runtime_fields(current, &mut snapshot);
            crate::reconcile_active_turn(Some(current), &mut snapshot, &response.thread.turns);
        }
        let next_key = snapshot.key.clone();
        self.app_store.upsert_thread_snapshot(snapshot);
        Ok(next_key)
    }
}

/// Decide how a resume/fork response's embedded `thread.turns` field maps
/// into the store's existing items list.
///
/// v0.125+ servers honor `exclude_turns: true` by returning an empty turns
/// array; we must preserve the store's existing hydrated items so the UI
/// does not flicker to empty while pagination loads the first page. Legacy
/// servers ignore `exclude_turns` and return the embedded turns — we treat
/// those as an authoritative hydration.
fn apply_pagination_merge(
    existing: Option<&ThreadSnapshot>,
    target: &mut ThreadSnapshot,
    upstream_turns: &[upstream::Turn],
) {
    if upstream_turns.is_empty() {
        if let Some(current) = existing {
            target.items = current.items.clone();
            target.older_turns_cursor = current.older_turns_cursor.clone();
            target.initial_turns_loaded = current.initial_turns_loaded;
        } else {
            target.initial_turns_loaded = false;
            target.older_turns_cursor = None;
        }
    } else {
        // Legacy remote (or explicit hydration): the response carries the
        // full turn history. Authoritative — paged cursor no longer applies.
        target.initial_turns_loaded = true;
        target.older_turns_cursor = None;
    }
}

fn user_replay_item_key(item: &HydratedConversationItem) -> Option<String> {
    match &item.content {
        HydratedConversationItemContent::User(data) => Some(format!(
            "user:{}:{}",
            data.text,
            serde_json::to_string(&data.image_data_uris).unwrap_or_default()
        )),
        _ => None,
    }
}

fn logical_replay_item_key(item: &HydratedConversationItem) -> Option<String> {
    match &item.content {
        HydratedConversationItemContent::User(_) => user_replay_item_key(item),
        HydratedConversationItemContent::Assistant(data) => {
            Some(format!("assistant:{}:{:?}", data.text, data.phase))
        }
        HydratedConversationItemContent::Reasoning(data) => Some(format!(
            "reasoning:{}:{}",
            serde_json::to_string(&data.summary).unwrap_or_default(),
            serde_json::to_string(&data.content).unwrap_or_default()
        )),
        _ => None,
    }
}

fn is_stream_text_item(item: &HydratedConversationItem) -> bool {
    matches!(
        item.content,
        HydratedConversationItemContent::Assistant(_)
            | HydratedConversationItemContent::Reasoning(_)
    )
}

fn prune_replayed_live_span(
    thread: &mut ThreadSnapshot,
    group_user_keys: &[String],
    incoming_item_ids: &HashSet<String>,
) {
    if group_user_keys.is_empty() {
        return;
    }

    let mut in_replayed_live_span = false;
    thread.items.retain(|item| {
        if let Some(key) = user_replay_item_key(item) {
            if group_user_keys.contains(&key) {
                if item.source_turn_id.is_none() {
                    in_replayed_live_span = true;
                    return false;
                }
                in_replayed_live_span = incoming_item_ids.contains(&item.id);
            } else {
                in_replayed_live_span = false;
            }
            return true;
        }

        if in_replayed_live_span && item.source_turn_id.is_none() && is_stream_text_item(item) {
            return false;
        }

        true
    });
}

fn replace_existing_items_by_id(
    thread: &mut ThreadSnapshot,
    incoming: impl IntoIterator<Item = HydratedConversationItem>,
) -> HashSet<String> {
    let mut replaced = HashSet::new();
    for item in incoming {
        if let Some(existing) = thread
            .items
            .iter_mut()
            .find(|existing| existing.id == item.id)
        {
            replaced.insert(item.id.clone());
            *existing = item;
        }
    }
    replaced
}

fn merge_paged_turns(
    thread: &mut ThreadSnapshot,
    page: &AppListThreadTurnsResponse,
    direction: AppTurnsSortDirection,
) {
    // Items within a single paged turn come in hydrated order (ascending).
    // When the server returns a Desc page (newest-first) we receive turns in
    // reverse chronological order, so we need to group by source_turn_id,
    // reverse the turn-order, then flatten.
    let mut turns_in_page: Vec<Vec<HydratedConversationItem>> = Vec::new();
    let mut current_turn_id: Option<String> = None;
    for item in &page.turns {
        let item_turn = item.source_turn_id.clone();
        if item_turn != current_turn_id {
            turns_in_page.push(Vec::new());
            current_turn_id = item_turn;
        }
        if let Some(group) = turns_in_page.last_mut() {
            group.push(item.clone());
        }
    }

    if matches!(direction, AppTurnsSortDirection::Descending) {
        // Desc page: newest turn first — reverse to get chronological order.
        turns_in_page.reverse();
    }

    // Build sets of existing turn ids and item ids already in the store for
    // dedupe. Item-id dedupe is essential because live ItemStarted/Completed
    // events hydrate with `source_turn_id: None` (see
    // `conversation_item_from_upstream` in store/actions.rs), so a paged turn
    // carrying the same upstream item id won't share a turn id with the
    // already-stored copy and would otherwise be added twice.
    let existing_turn_ids: HashSet<String> = thread
        .items
        .iter()
        .filter_map(|item| item.source_turn_id.clone())
        .collect();
    let existing_item_ids: HashSet<String> =
        thread.items.iter().map(|item| item.id.clone()).collect();

    let mut new_items: Vec<HydratedConversationItem> = Vec::new();
    for group in turns_in_page {
        let group_turn_id = group.first().and_then(|item| item.source_turn_id.clone());
        let incoming_item_ids: HashSet<String> = group.iter().map(|item| item.id.clone()).collect();

        // Preferred path for new Alleycat/Pi bridges: live stream items and
        // later replay items carry the same upstream item id. Replace the
        // sourceless live copy with the authoritative paged copy so metadata
        // such as `source_turn_id` is repaired without any content guessing.
        let replaced_item_ids = replace_existing_items_by_id(thread, group.iter().cloned());

        let group_user_keys = group
            .iter()
            .filter_map(user_replay_item_key)
            .collect::<Vec<_>>();
        let group_replays_existing_user = group_user_keys.iter().any(|key| {
            thread
                .items
                .iter()
                .filter_map(user_replay_item_key)
                .any(|existing_key| existing_key == *key)
        });
        let group_has_persisted_text = group.iter().any(|item| {
            item.source_turn_id.is_some()
                && matches!(
                    item.content,
                    HydratedConversationItemContent::Assistant(_)
                        | HydratedConversationItemContent::Reasoning(_)
                )
        });
        if let Some(id) = group_turn_id.as_deref() {
            if existing_turn_ids.contains(id) {
                // A reconnect repair page is authoritative for completed turn
                // text. Drop stale streaming assistant/reasoning placeholders
                // absent from the replay, while preserving the historical
                // turn-id dedupe for non-stream/user items.
                if thread.active_turn_id.is_none()
                    && group_replays_existing_user
                    && group_has_persisted_text
                {
                    prune_replayed_live_span(thread, &group_user_keys, &incoming_item_ids);
                    thread.items.retain(|item| {
                        incoming_item_ids.contains(&item.id)
                            || !is_stream_text_item(item)
                            || item.source_turn_id.as_deref() != Some(id)
                    });
                }
                continue;
            }
        }
        if thread.active_turn_id.is_none()
            && group_replays_existing_user
            && group_has_persisted_text
        {
            prune_replayed_live_span(thread, &group_user_keys, &incoming_item_ids);
        }
        for item in group {
            if existing_item_ids.contains(&item.id) || replaced_item_ids.contains(&item.id) {
                continue;
            }
            // Compatibility path for older/non-Codex bridges that synthesized
            // optimistic/live item ids before the underlying agent persisted
            // history. A later `thread/turns/list` can return the same logical
            // content with a different persisted id. Prefer the replay copy
            // when it carries a turn id, and avoid duplicate user / assistant /
            // reasoning bubbles after reconnect repair pages.
            if let Some(key) = logical_replay_item_key(&item)
                && let Some(existing) = thread.items.iter_mut().find(|existing| {
                    existing.source_turn_id.is_none()
                        && logical_replay_item_key(existing).as_deref() == Some(&key)
                })
            {
                if item.source_turn_id.is_some() && existing.source_turn_id.is_none() {
                    *existing = item;
                }
                continue;
            }
            new_items.push(item);
        }
    }

    // For Desc direction the `next_cursor` points at older turns; prepend new
    // items before existing ones since our store is chronological ascending.
    // For Asc direction (future use) append.
    if matches!(direction, AppTurnsSortDirection::Descending) {
        let mut merged = new_items;
        merged.extend(thread.items.iter().cloned());
        thread.items = merged;
        thread.older_turns_cursor = page.next_cursor.clone();
    } else {
        thread.items.extend(new_items);
    }
    thread.initial_turns_loaded = true;
}

fn terminal_turn_outcome(turn: &AppTurnState) -> Option<crate::source::TurnOutcome> {
    use crate::source::TurnOutcome;
    match turn.status {
        AppTurnStatus::Completed => Some(TurnOutcome::Completed),
        AppTurnStatus::Interrupted => Some(TurnOutcome::Interrupted),
        AppTurnStatus::Failed => Some(TurnOutcome::Failed {
            message: turn
                .error_message
                .clone()
                .unwrap_or_else(|| "The agent stopped with an error.".to_string()),
        }),
        AppTurnStatus::InProgress => None,
    }
}

fn merge_latest_terminal_turns(
    thread: &mut ThreadSnapshot,
    page: &AppListThreadTurnsResponse,
) -> bool {
    let terminal_ids: HashSet<&str> = page
        .turn_states
        .iter()
        .filter(|turn| turn.status != AppTurnStatus::InProgress)
        .map(|turn| turn.turn_id.as_str())
        .collect();
    if terminal_ids.is_empty() {
        return false;
    }
    let before = (
        thread.active_turn_id.clone(),
        thread.info.status.clone(),
        thread.initial_turns_loaded,
        thread.older_turns_cursor.clone(),
        thread.local_overlay_items.len(),
    );
    // The latest page is newest-first, while every individual turn's items
    // are already in transcript order. Reverse groups, never their items.
    let mut groups: Vec<Vec<HydratedConversationItem>> = Vec::new();
    for item in &page.turns {
        if !item
            .source_turn_id
            .as_deref()
            .is_some_and(|id| terminal_ids.contains(id))
        {
            continue;
        }
        if groups
            .last()
            .and_then(|group| group.first())
            .is_none_or(|last| last.source_turn_id != item.source_turn_id)
        {
            groups.push(Vec::new());
        }
        groups.last_mut().expect("turn group").push(item.clone());
    }
    groups.reverse();
    let incoming: Vec<_> = groups.into_iter().flatten().collect();
    let incoming_ids: HashSet<&str> = incoming.iter().map(|item| item.id.as_str()).collect();
    // TurnStarted/user echo may be missed after turn/start is acknowledged.
    // Its staged learner overlay still identifies a newer send whose
    // sourceless deltas must survive an older completion query. Imported
    // transcript overlays are deliberately excluded from this guard.
    let has_unreplayed_local_send = thread.local_overlay_items.iter().any(|item| {
        item.id.starts_with("local-user-message:")
            && matches!(item.content, HydratedConversationItemContent::User(_))
            && item
                .source_turn_id
                .as_deref()
                .is_none_or(|id| !terminal_ids.contains(id))
    });
    let can_prune_stream = !has_unreplayed_local_send
        && thread
            .active_turn_id
            .as_deref()
            .is_none_or(|id| terminal_ids.contains(id));
    let mut insertion_index = None;
    let mut retained = Vec::with_capacity(thread.items.len() + incoming.len());
    let mut in_replayed_span = false;
    for item in &thread.items {
        let replayed = incoming_ids.contains(item.id.as_str())
            || item
                .source_turn_id
                .as_deref()
                .is_some_and(|id| terminal_ids.contains(id));
        if matches!(item.content, HydratedConversationItemContent::User(_)) {
            in_replayed_span = replayed;
        }
        let stale_stream = can_prune_stream
            && in_replayed_span
            && item.source_turn_id.is_none()
            && is_stream_text_item(item);
        if replayed || stale_stream {
            insertion_index.get_or_insert(retained.len());
        } else {
            retained.push(item.clone());
        }
    }
    // No overlap means the completed rows were entirely missed. Insert them
    // after older history, before a newer live turn if one is already known.
    let insertion_index = insertion_index.unwrap_or_else(|| {
        retained
            .iter()
            .position(|item| {
                thread.active_turn_id.is_some() && item.source_turn_id == thread.active_turn_id
            })
            .unwrap_or(retained.len())
    });
    retained.splice(insertion_index..insertion_index, incoming);
    let items_changed = thread.items != retained;
    thread.items = retained;
    if let Some(active) = thread.active_turn_id.as_deref()
        && let Some(turn) = page
            .turn_states
            .iter()
            .find(|turn| turn.turn_id == active && terminal_ids.contains(active))
    {
        thread.info.status = if turn.status == AppTurnStatus::Failed {
            crate::types::ThreadSummaryStatus::SystemError
        } else {
            crate::types::ThreadSummaryStatus::Idle
        };
        thread.active_turn_id = None;
    }
    if !thread.initial_turns_loaded {
        thread.initial_turns_loaded = true;
        thread.older_turns_cursor = page.next_cursor.clone();
    }
    crate::store::reducer::remove_duplicate_local_overlay_items(thread);
    items_changed
        || before
            != (
                thread.active_turn_id.clone(),
                thread.info.status.clone(),
                thread.initial_turns_loaded,
                thread.older_turns_cursor.clone(),
                thread.local_overlay_items.len(),
            )
}

fn downcast_public_rpc_response<'a, T: Any>(
    wire_method: &str,
    response: &'a dyn Any,
) -> Result<&'a T, RpcError> {
    response.downcast_ref::<T>().ok_or_else(|| {
        RpcError::Deserialization(format!(
            "unexpected response type while reconciling {wire_method}"
        ))
    })
}

fn downcast_public_rpc_params<'a, T: Any>(
    wire_method: &str,
    params: Option<&'a dyn Any>,
) -> Result<&'a T, RpcError> {
    params
        .and_then(|value| value.downcast_ref::<T>())
        .ok_or_else(|| {
            RpcError::Deserialization(format!(
                "unexpected params type while reconciling {wire_method}"
            ))
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::connection::ServerConfig;
    use crate::store::ServerHealthSnapshot;
    use codex_app_server_protocol as upstream;
    use std::path::PathBuf;

    fn test_abs_path(path: &str) -> codex_utils_absolute_path::AbsolutePathBuf {
        codex_utils_absolute_path::AbsolutePathBuf::from_absolute_path_checked(path)
            .expect("test path must be absolute")
    }

    fn test_upstream_thread(id: &str) -> upstream::Thread {
        upstream::Thread {
            id: id.to_string(),
            environments: None,
            extra: None,
            session_id: format!("session-{id}"),
            forked_from_id: None,
            parent_thread_id: None,
            preview: "hello".to_string(),
            ephemeral: false,
            section: None,
            section_entered_at: None,
            project_id: None,
            history_mode: Default::default(),
            model_provider: "openai".to_string(),
            model: None,
            reasoning_effort: None,
            created_at: 1,
            updated_at: 2,
            recency_at: None,
            status: upstream::ThreadStatus::Idle,
            path: Some(PathBuf::from("/tmp/thread.jsonl")),
            cwd: test_abs_path("/tmp"),
            cli_version: "1.0.0".to_string(),
            originator: None,
            source: upstream::SessionSource::default(),
            can_accept_direct_input: None,
            thread_source: None,
            agent_nickname: None,
            agent_role: None,
            git_info: None,
            name: Some("Thread".to_string()),
            daybreak_enabled: None,
            turns: Vec::new(),
        }
    }

    #[tokio::test]
    async fn account_read_reconciliation_updates_store() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".into(),
                display_name: "Server".into(),
                host: "127.0.0.1".into(),
                port: 9234,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );

        let response = upstream::GetAccountResponse {
            account: Some(upstream::Account::Chatgpt {
                email: Some("user@example.com".into()),
                plan_type: codex_protocol::account::PlanType::Pro,
            }),
            requires_openai_auth: true,
        };

        client
            .reconcile_public_rpc("account/read", "srv", Option::<&()>::None, &response)
            .await
            .expect("account/read reconciliation should succeed");

        let snapshot = client.app_snapshot();
        let server = snapshot
            .servers
            .get("srv")
            .expect("server should still exist");
        assert_eq!(server.account, response.account.clone().map(Into::into));
        assert!(server.requires_openai_auth);
    }

    #[tokio::test]
    async fn account_rate_limits_reconciliation_updates_store() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );

        let response = upstream::GetAccountRateLimitsResponse {
            ordinary_usage_allowed: None,
            rate_limits: upstream::RateLimitSnapshot {
                limit_id: Some("primary".to_string()),
                limit_name: Some("Primary".to_string()),
                normal_model_slug: None,
                primary: Some(upstream::RateLimitWindow {
                    used_percent: 42,
                    window_duration_mins: Some(60),
                    resets_at: Some(123456789),
                }),
                secondary: None,
                credits: Some(upstream::CreditsSnapshot {
                    has_credits: true,
                    unlimited: false,
                    balance: Some("5.00".to_string()),
                }),
                individual_limit: None,
                spend_control_reached: None,
                plan_type: Some(codex_protocol::account::PlanType::Plus),
                rate_limit_reached_type: None,
            },
            rate_limits_by_limit_id: None,
            rate_limit_reset_credits: None,
            account_id: None,
            rate_limit_upsell: None,
        };

        client
            .reconcile_public_rpc(
                "account/rateLimits/read",
                "srv",
                Option::<&()>::None,
                &response,
            )
            .await
            .expect("account/rateLimits/read reconciliation should succeed");

        let snapshot = client.app_snapshot();
        let server = snapshot
            .servers
            .get("srv")
            .expect("server snapshot should exist");
        assert_eq!(
            server.rate_limits,
            Some(response.rate_limits.clone().into())
        );
    }

    #[tokio::test]
    async fn model_list_reconciliation_updates_store() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );

        let response = upstream::ModelListResponse {
            data: vec![upstream::Model {
                id: "gpt-5.4".to_string(),
                model: "gpt-5.4".to_string(),
                upgrade: None,
                display_name: "gpt-5.4".to_string(),
                description: "Balanced flagship".to_string(),
                model_specialty: None,
                hidden: false,
                supported_reasoning_efforts: vec![upstream::ReasoningEffortOption {
                    reasoning_effort: codex_protocol::openai_models::ReasoningEffort::Medium,
                    description: "Balanced".to_string(),
                }],
                default_reasoning_effort: codex_protocol::openai_models::ReasoningEffort::Medium,
                input_modalities: vec![codex_protocol::openai_models::InputModality::Text],
                supports_personality: true,
                multi_agent_version: None,
                additional_speed_tiers: Vec::new(),
                service_tiers: Vec::new(),
                default_service_tier: None,
                is_default: true,
                availability_nux: None,
                upgrade_info: None,
            }],
            next_cursor: None,
        };

        client
            .reconcile_public_rpc("model/list", "srv", Option::<&()>::None, &response)
            .await
            .expect("model/list reconciliation should succeed");

        let snapshot = client.app_snapshot();
        let server = snapshot
            .servers
            .get("srv")
            .expect("server snapshot should exist");
        assert_eq!(
            server.available_models,
            Some(response.data.into_iter().map(Into::into).collect())
        );
    }

    #[tokio::test]
    async fn thread_reconciliation_param_handling_matches_wire_method() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );

        let list_response = upstream::ThreadListResponse {
            data: vec![test_upstream_thread("thread-1")],
            next_cursor: None,
            backwards_cursor: None,
        };

        client
            .reconcile_public_rpc("thread/list", "srv", Option::<&()>::None, &list_response)
            .await
            .expect("thread/list reconciliation should succeed without params");

        let rollback_response = upstream::ThreadRollbackResponse {
            thread: test_upstream_thread("thread-1"),
        };

        let missing_params_error = client
            .reconcile_public_rpc(
                "thread/rollback",
                "srv",
                Option::<&()>::None,
                &rollback_response,
            )
            .await
            .expect_err("thread/rollback should reject missing params");
        assert!(
            missing_params_error
                .to_string()
                .contains("unexpected params type while reconciling thread/rollback")
        );

        let params = upstream::ThreadRollbackParams {
            thread_id: "thread-1".to_string(),
            num_turns: 1,
        };
        client
            .reconcile_public_rpc("thread/rollback", "srv", Some(&params), &rollback_response)
            .await
            .expect("thread/rollback reconciliation should succeed with params");

        let snapshot = client.app_snapshot();
        assert!(snapshot.threads.contains_key(&ThreadKey {
            server_id: "srv".to_string(),
            thread_id: "thread-1".to_string(),
        }));
    }

    fn item_with_turn(turn_id: &str, item_id: &str) -> HydratedConversationItem {
        use crate::conversation_uniffi::{
            HydratedConversationItemContent, HydratedUserMessageData,
        };
        HydratedConversationItem {
            id: item_id.to_string(),
            content: HydratedConversationItemContent::User(HydratedUserMessageData {
                text: "hi".to_string(),
                image_data_uris: Vec::new(),
            }),
            source_turn_id: Some(turn_id.to_string()),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    fn assistant_item(
        turn_id: Option<&str>,
        item_id: &str,
        text: &str,
    ) -> HydratedConversationItem {
        use crate::conversation_uniffi::{
            HydratedAssistantMessageData, HydratedConversationItemContent,
        };
        HydratedConversationItem {
            id: item_id.to_string(),
            content: HydratedConversationItemContent::Assistant(HydratedAssistantMessageData {
                text: text.to_string(),
                agent_nickname: None,
                agent_role: None,
                phase: None,
            }),
            source_turn_id: turn_id.map(ToOwned::to_owned),
            source_turn_index: None,
            timestamp: None,
            is_from_user_turn_boundary: false,
        }
    }

    fn test_thread_snapshot() -> ThreadSnapshot {
        let info = ThreadInfo {
            id: "thread-1".to_string(),
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
        };
        ThreadSnapshot::from_info("srv", info)
    }

    fn latest_terminal_page() -> AppListThreadTurnsResponse {
        // Installed Codex 0.160 adds optional delivery/questions fields to
        // agent messages; completion queries must hydrate these plain rows.
        let response: upstream::ThreadTurnsListResponse = serde_json::from_value(serde_json::json!({
            "data": [{
                "id": "turn-2",
                "status": "completed",
                "error": null,
                "items": [{
                    "type": "userMessage", "id": "user-2",
                    "content": [{"type": "text", "text": "Starting from scratch", "textElements": []}]
                }, {
                    "type": "agentMessage", "id": "answer-2",
                    "text": "What happens to sunlight in a raindrop?",
                    "phase": "final_answer", "delivery": null, "questions": []
                }],
                "startedAt": null, "completedAt": 1, "durationMs": 1
            }, {
                "id": "turn-1", "status": "completed", "error": null,
                "items": [{"type": "userMessage", "id": "user-1", "content": [
                    {"type": "text", "text": "Teach me rainbows", "textElements": []}
                ]}, {"type": "agentMessage", "id": "answer-1", "text": "What do you already know?", "phase": "final_answer"}],
                "startedAt": null, "completedAt": 1, "durationMs": 1
            }],
            "nextCursor": "page-older", "backwardsCursor": null
        })).expect("installed plain-turn fixture");
        response.into()
    }

    fn terminal_repair_session(client: &MobileClient) -> Arc<ServerSession> {
        let config = ServerConfig {
            server_id: "srv".to_string(),
            display_name: "This Mac".to_string(),
            host: "127.0.0.1".to_string(),
            port: 8390,
            websocket_url: None,
            is_local: true,
            tls: false,
        };
        let session = Arc::new(ServerSession::test_stub(config.clone()));
        client
            .sessions
            .write()
            .unwrap()
            .insert("srv".to_string(), session.clone());
        client
            .app_store
            .upsert_server(&config, ServerHealthSnapshot::Connected);
        session
    }

    #[tokio::test]
    async fn latest_terminal_poll_repairs_missing_reply_and_accepted_chat_before_next_send() {
        use crate::source::{SourceEvent, SourceKind, TurnOutcome};
        use crate::store::chat::ChatViewOptions;
        use crate::store::timeline::TimelineRowKind;
        use crate::store::turn::{LocalAction, TurnPhase};

        let client = MobileClient::new();
        let session = terminal_repair_session(&client);
        let mut thread = test_thread_snapshot();
        thread.items = vec![
            item_with_turn("turn-older", "user-older"),
            item_with_turn("turn-1", "user-1"),
            assistant_item(Some("turn-1"), "answer-1", "What do you already know?"),
            // The user echo arrived, while TurnStarted and the reply did not.
            item_with_turn("turn-2", "user-2"),
        ];
        thread.initial_turns_loaded = true;
        thread.older_turns_cursor = Some("saved-older-cursor".to_string());
        let key = thread.key.clone();
        client.app_store.upsert_thread_snapshot(thread);
        let mut chat_updates = client.app_store.chat_subscribe(&key);
        client.app_store.chat_local_action(&key, LocalAction::Send);
        client.app_store.apply_source_events(
            &key,
            SourceKind::app_server("codex"),
            &[SourceEvent::TurnAccepted {
                turn_id: "turn-2".to_string(),
                client_msg_id: None,
            }],
        );
        assert_eq!(
            client
                .app_store
                .chat_view(&key, &ChatViewOptions::default())
                .phase,
            TurnPhase::Accepted
        );
        chat_updates.borrow_and_update();

        client.reconcile_latest_terminal_turns(
            "srv",
            "thread-1",
            &latest_terminal_page(),
            &session,
        );

        let thread = client.app_store.thread_snapshot(&key).unwrap();
        assert_eq!(
            thread
                .items
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            ["user-older", "user-1", "answer-1", "user-2", "answer-2"]
        );
        assert_eq!(
            thread.older_turns_cursor.as_deref(),
            Some("saved-older-cursor")
        );
        let view = client
            .app_store
            .chat_view(&key, &ChatViewOptions::default());
        assert_eq!(
            view.phase,
            TurnPhase::Settled {
                outcome: TurnOutcome::Completed
            }
        );
        assert!(view.rows.iter().any(|row| matches!(&row.kind,
            TimelineRowKind::Answer { text, .. } if text == "What happens to sunlight in a raindrop?")));
        assert!(
            chat_updates.has_changed().unwrap(),
            "completion wakes the existing chat subscription"
        );
        assert!(
            !merge_latest_terminal_turns(&mut thread.clone(), &latest_terminal_page()),
            "repeated polls are idempotent"
        );
    }

    #[test]
    fn latest_terminal_poll_appends_entirely_missing_turns_in_order_and_clears_matching_active() {
        let mut thread = test_thread_snapshot();
        thread.items = vec![item_with_turn("turn-older", "older")];
        thread.active_turn_id = Some("turn-2".to_string());
        thread.info.status = crate::types::ThreadSummaryStatus::Active;
        assert!(merge_latest_terminal_turns(
            &mut thread,
            &latest_terminal_page()
        ));
        assert_eq!(
            thread
                .items
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            ["older", "user-1", "answer-1", "user-2", "answer-2"]
        );
        assert!(thread.active_turn_id.is_none());
        assert_eq!(thread.info.status, crate::types::ThreadSummaryStatus::Idle);
        assert!(thread.initial_turns_loaded);
        assert_eq!(thread.older_turns_cursor.as_deref(), Some("page-older"));
    }

    #[tokio::test]
    async fn latest_terminal_poll_preserves_newer_live_turn_and_its_chat_phase() {
        use crate::source::{SourceEvent, SourceKind};
        use crate::store::chat::ChatViewOptions;
        use crate::store::turn::TurnPhase;

        let client = MobileClient::new();
        let session = terminal_repair_session(&client);
        let mut thread = test_thread_snapshot();
        thread.items = vec![
            item_with_turn("turn-3", "user-3"),
            assistant_item(Some("turn-3"), "answer-3", "Still streaming"),
        ];
        thread.active_turn_id = Some("turn-3".to_string());
        thread.info.status = crate::types::ThreadSummaryStatus::Active;
        let key = thread.key.clone();
        client.app_store.upsert_thread_snapshot(thread);
        let _subscription = client.app_store.chat_subscribe(&key);
        client.app_store.apply_source_events(
            &key,
            SourceKind::app_server("codex"),
            &[SourceEvent::TurnStarted {
                turn_id: "turn-3".to_string(),
            }],
        );
        client.reconcile_latest_terminal_turns(
            "srv",
            "thread-1",
            &latest_terminal_page(),
            &session,
        );
        let thread = client.app_store.thread_snapshot(&key).unwrap();
        assert_eq!(thread.active_turn_id.as_deref(), Some("turn-3"));
        assert_eq!(
            thread.info.status,
            crate::types::ThreadSummaryStatus::Active
        );
        assert_eq!(thread.items.last().unwrap().id, "answer-3");
        assert_eq!(
            client
                .app_store
                .chat_view(&key, &ChatViewOptions::default())
                .phase,
            TurnPhase::Thinking
        );
    }

    #[tokio::test]
    async fn latest_terminal_poll_from_replaced_session_is_ignored() {
        let client = MobileClient::new();
        let old_session = terminal_repair_session(&client);
        let mut thread = test_thread_snapshot();
        thread.items = vec![item_with_turn("turn-2", "user-2")];
        thread.active_turn_id = Some("turn-2".to_string());
        thread.info.status = crate::types::ThreadSummaryStatus::Active;
        let key = thread.key.clone();
        client.app_store.upsert_thread_snapshot(thread);
        let _replacement = terminal_repair_session(&client);
        client.reconcile_latest_terminal_turns(
            "srv",
            "thread-1",
            &latest_terminal_page(),
            &old_session,
        );
        let thread = client.app_store.thread_snapshot(&key).unwrap();
        assert_eq!(thread.items.len(), 1);
        assert_eq!(thread.active_turn_id.as_deref(), Some("turn-2"));
        assert_eq!(
            thread.info.status,
            crate::types::ThreadSummaryStatus::Active
        );
    }

    #[tokio::test]
    async fn latest_terminal_poll_restores_completed_fence_question_without_another_send() {
        use crate::source::{SourceEvent, SourceKind};
        use crate::store::chat::ChatViewOptions;
        use crate::store::timeline::TimelineRowKind;
        use crate::store::turn::TurnPhase;

        let client = MobileClient::new();
        let session = terminal_repair_session(&client);
        let thread = test_thread_snapshot();
        let key = thread.key.clone();
        client.app_store.upsert_thread_snapshot(thread);
        let _subscription = client.app_store.chat_subscribe(&key);
        client.app_store.apply_source_events(
            &key,
            SourceKind::app_server("codex"),
            &[SourceEvent::TurnAccepted {
                turn_id: "turn-2".to_string(),
                client_msg_id: None,
            }],
        );
        let mut page = latest_terminal_page();
        let answer = page
            .turns
            .iter_mut()
            .find(|item| item.id == "answer-2")
            .unwrap();
        let HydratedConversationItemContent::Assistant(data) = &mut answer.content else {
            panic!("answer fixture")
        };
        data.text =
            "```learnfold-question\nWhat should we cover next?\n- Light\n- Water\n```".to_string();
        client.reconcile_latest_terminal_turns("srv", "thread-1", &page, &session);
        let view = client
            .app_store
            .chat_view(&key, &ChatViewOptions::default());
        assert_eq!(view.phase, TurnPhase::AwaitingInput);
        assert!(view.rows.iter().any(|row| matches!(&row.kind,
            TimelineRowKind::Question { prompt, is_pending: true, .. } if prompt == "What should we cover next?")));
    }

    #[tokio::test]
    async fn latest_terminal_poll_preserves_newer_send_before_started_notification() {
        use crate::store::chat::ChatViewOptions;
        use crate::store::turn::TurnPhase;

        for accepted in [false, true] {
            let client = MobileClient::new();
            let session = terminal_repair_session(&client);
            let mut thread = test_thread_snapshot();
            thread.items = vec![item_with_turn("turn-2", "user-2")];
            let key = thread.key.clone();
            client.app_store.upsert_thread_snapshot(thread);
            let _subscription = client.app_store.chat_subscribe(&key);
            let overlay_id = client
                .app_store
                .stage_local_user_message_overlay(
                    &key,
                    &[upstream::UserInput::Text {
                        text: "My next answer".to_string(),
                        text_elements: vec![],
                    }],
                )
                .unwrap();
            if accepted {
                client.app_store.bind_local_user_message_overlay_to_turn(
                    &key,
                    &overlay_id,
                    "turn-3",
                );
            }
            // Streaming deltas create sourceless items if TurnStarted and
            // the user echo did not arrive. The staged overlay still owns it.
            client.app_store.mutate_thread_with_result(&key, |thread| {
                thread.items.push(assistant_item(
                    None,
                    "answer-3-partial",
                    "Newer answer still growing",
                ));
            });
            let phase = if accepted {
                TurnPhase::Accepted
            } else {
                TurnPhase::Queued
            };
            assert!(
                client
                    .app_store
                    .thread_snapshot(&key)
                    .unwrap()
                    .active_turn_id
                    .is_none()
            );
            assert_eq!(
                client
                    .app_store
                    .chat_view(&key, &ChatViewOptions::default())
                    .phase,
                phase
            );

            client.reconcile_latest_terminal_turns(
                "srv",
                "thread-1",
                &latest_terminal_page(),
                &session,
            );

            let thread = client.app_store.thread_snapshot(&key).unwrap();
            assert_eq!(thread.items.last().unwrap().id, "answer-3-partial");
            assert!(
                thread
                    .local_overlay_items
                    .iter()
                    .any(|item| item.id == overlay_id)
            );
            assert_eq!(
                client
                    .app_store
                    .chat_view(&key, &ChatViewOptions::default())
                    .phase,
                phase
            );
        }
    }

    #[test]
    fn latest_terminal_poll_imported_overlay_does_not_block_stale_stream_repair() {
        let mut thread = test_thread_snapshot();
        thread.items = vec![
            item_with_turn("turn-2", "user-2"),
            assistant_item(None, "stale-answer", "Old partial"),
        ];
        thread.local_overlay_items =
            vec![item_with_turn("imported-turn", "portable-transcript:user")];
        merge_latest_terminal_turns(&mut thread, &latest_terminal_page());
        assert!(!thread.items.iter().any(|item| item.id == "stale-answer"));
        assert_eq!(thread.local_overlay_items.len(), 1);
    }

    #[tokio::test]
    async fn latest_terminal_public_query_requests_full_items_and_preserves_work_and_commentary() {
        use crate::ffi::AppClient;
        use crate::session::connection::TestRequestHandler;
        use crate::types::AppListThreadTurnsRequest;

        let full = serde_json::json!({
            "data": [{"id": "turn-2", "status": "completed", "error": null,
                "items": [{"type": "userMessage", "id": "user-2", "content": [
                    {"type": "text", "text": "Show me", "textElements": []}
                ]}, {"type": "reasoning", "id": "reasoning-2", "summary": ["Checking the result"], "content": []},
                {"type": "commandExecution", "id": "command-2", "command": "pwd", "cwd": "/tmp",
                    "processId": null, "source": "agent", "status": "completed", "commandActions": [],
                    "aggregatedOutput": "/tmp", "exitCode": 0, "durationMs": 1},
                {"type": "agentMessage", "id": "commentary-2", "text": "I checked the local result.", "phase": "commentary"},
                {"type": "agentMessage", "id": "answer-2", "text": "Here is the result.", "phase": "final_answer"}],
                "startedAt": null, "completedAt": 1, "durationMs": 1}],
            "nextCursor": null, "backwardsCursor": null
        });
        let hydrated: AppListThreadTurnsResponse =
            serde_json::from_value::<upstream::ThreadTurnsListResponse>(full.clone())
                .unwrap()
                .into();
        let inner = Arc::new(MobileClient::new());
        let old_session = terminal_repair_session(&inner);
        let handler: TestRequestHandler = Arc::new(move |request| {
            let upstream::ClientRequest::ThreadTurnsList { params, .. } = request else {
                panic!("completion query")
            };
            assert_eq!(
                params.items_view,
                Some(upstream::TurnItemsView::Full),
                "a Summary page cannot authorize replacing a terminal turn"
            );
            assert_eq!(
                params.limit,
                Some(20),
                "full hydration remains a bounded page"
            );
            Ok(full.clone())
        });
        let session = Arc::new(ServerSession::test_stub_with_handlers(
            old_session.config().clone(),
            Some(handler),
            None,
            None,
        ));
        inner
            .sessions
            .write()
            .unwrap()
            .insert("srv".to_string(), session);
        let mut thread = test_thread_snapshot();
        thread.items = hydrated
            .turns
            .into_iter()
            .filter(|item| item.id != "answer-2")
            .collect();
        let key = thread.key.clone();
        inner.app_store.upsert_thread_snapshot(thread);
        let client = AppClient {
            inner: inner.clone(),
            rt: crate::ffi::shared::shared_runtime(),
        };

        client
            .list_thread_turns(
                "srv".to_string(),
                AppListThreadTurnsRequest {
                    thread_id: "thread-1".to_string(),
                    cursor: None,
                    limit: Some(20),
                    sort_direction: Some(AppTurnsSortDirection::Descending),
                },
            )
            .await
            .expect("full completion query");

        let thread = inner.app_store.thread_snapshot(&key).unwrap();
        assert_eq!(
            thread
                .items
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            [
                "user-2",
                "reasoning-2",
                "command-2",
                "commentary-2",
                "answer-2"
            ]
        );
    }

    #[test]
    fn merge_paged_turns_empty_store_first_desc_page() {
        let mut thread = test_thread_snapshot();
        let page = AppListThreadTurnsResponse {
            turn_states: vec![],
            // Desc page: turn-3 newest, then turn-2, then turn-1.
            turns: vec![
                item_with_turn("turn-3", "i3"),
                item_with_turn("turn-2", "i2"),
                item_with_turn("turn-1", "i1"),
            ],
            next_cursor: Some("cursor-older".to_string()),
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        // Store should be chronological ascending.
        let ids: Vec<Option<String>> = thread
            .items
            .iter()
            .map(|item| item.source_turn_id.clone())
            .collect();
        assert_eq!(
            ids,
            vec![
                Some("turn-1".to_string()),
                Some("turn-2".to_string()),
                Some("turn-3".to_string()),
            ]
        );
        assert_eq!(thread.older_turns_cursor.as_deref(), Some("cursor-older"));
        assert!(thread.initial_turns_loaded);
    }

    #[test]
    fn merge_paged_turns_prepends_older_page() {
        let mut thread = test_thread_snapshot();
        thread.items = vec![item_with_turn("turn-3", "i3")];
        thread.initial_turns_loaded = true;
        thread.older_turns_cursor = Some("cursor-first".to_string());
        let page = AppListThreadTurnsResponse {
            turn_states: vec![],
            turns: vec![
                item_with_turn("turn-2", "i2"),
                item_with_turn("turn-1", "i1"),
            ],
            next_cursor: None, // no more older
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        let ids: Vec<Option<String>> = thread
            .items
            .iter()
            .map(|item| item.source_turn_id.clone())
            .collect();
        assert_eq!(
            ids,
            vec![
                Some("turn-1".to_string()),
                Some("turn-2".to_string()),
                Some("turn-3".to_string()),
            ]
        );
        assert!(thread.older_turns_cursor.is_none());
        assert!(thread.initial_turns_loaded);
    }

    #[test]
    fn merge_paged_turns_dedupes_existing_turn_id() {
        let mut thread = test_thread_snapshot();
        thread.items = vec![item_with_turn("turn-3", "i3")];
        thread.initial_turns_loaded = true;
        let page = AppListThreadTurnsResponse {
            turn_states: vec![],
            turns: vec![
                item_with_turn("turn-3", "i3-dup"),
                item_with_turn("turn-2", "i2"),
            ],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        // Dupe of turn-3 should not reappear; turn-2 prepended.
        let ids: Vec<Option<String>> = thread
            .items
            .iter()
            .map(|item| item.source_turn_id.clone())
            .collect();
        assert_eq!(
            ids,
            vec![Some("turn-2".to_string()), Some("turn-3".to_string())]
        );
    }

    #[test]
    fn merge_paged_turns_replaces_same_item_id_with_authoritative_replay_item() {
        let mut thread = test_thread_snapshot();
        let mut live_item = item_with_turn("turn-live", "stable-user-id");
        live_item.source_turn_id = None;
        thread.items = vec![live_item];
        let page = AppListThreadTurnsResponse {
            turn_states: vec![],
            turns: vec![item_with_turn("turn-1", "stable-user-id")],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        assert_eq!(thread.items.len(), 1);
        assert_eq!(thread.items[0].id, "stable-user-id");
        assert_eq!(thread.items[0].source_turn_id.as_deref(), Some("turn-1"));
    }

    #[test]
    fn merge_paged_turns_replaces_same_logical_live_item_with_replay_item() {
        let mut thread = test_thread_snapshot();
        let mut live_item = item_with_turn("turn-live", "live-user-id");
        live_item.source_turn_id = None;
        let replay_item = item_with_turn("turn-1", "persisted-user-id");
        thread.items = vec![live_item];
        let page = AppListThreadTurnsResponse {
            turn_states: vec![],
            turns: vec![replay_item],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        assert_eq!(thread.items.len(), 1);
        assert_eq!(thread.items[0].id, "persisted-user-id");
        assert_eq!(thread.items[0].source_turn_id.as_deref(), Some("turn-1"));
    }

    #[test]
    fn merge_paged_turns_removes_sourceless_stream_text_when_replay_repairs_turn() {
        let mut thread = test_thread_snapshot();
        let mut live_user = item_with_turn("turn-live", "live-user-id");
        live_user.source_turn_id = None;
        thread.items = vec![
            live_user,
            assistant_item(None, "live-assistant-id", "partial"),
        ];
        let page = AppListThreadTurnsResponse {
            turn_states: vec![],
            turns: vec![
                item_with_turn("turn-1", "persisted-user-id"),
                assistant_item(Some("turn-1"), "persisted-assistant-id", "final"),
            ],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        let ids: Vec<String> = thread.items.iter().map(|item| item.id.clone()).collect();
        assert_eq!(ids, vec!["persisted-user-id", "persisted-assistant-id"]);
    }

    #[test]
    fn merge_paged_turns_repair_preserves_text_from_other_turns() {
        let mut thread = test_thread_snapshot();
        let mut live_user = item_with_turn("turn-live", "live-user-id");
        live_user.source_turn_id = None;
        thread.items = vec![
            item_with_turn("turn-0", "older-user-id"),
            assistant_item(Some("turn-0"), "older-assistant-id", "older final"),
            live_user,
            assistant_item(None, "live-assistant-id", "partial"),
        ];
        let page = AppListThreadTurnsResponse {
            turn_states: vec![],
            turns: vec![
                item_with_turn("turn-1", "persisted-user-id"),
                assistant_item(Some("turn-1"), "persisted-assistant-id", "final"),
            ],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        let ids: Vec<String> = thread.items.iter().map(|item| item.id.clone()).collect();
        assert!(
            ids.contains(&"older-assistant-id".to_string()),
            "repair for turn-1 must preserve assistant text from turn-0; ids={ids:?}"
        );
        assert!(
            !ids.contains(&"live-assistant-id".to_string()),
            "repair for turn-1 should prune the stale live assistant placeholder; ids={ids:?}"
        );
    }

    #[test]
    fn merge_paged_turns_keeps_active_stream_text_while_loading_pages() {
        let mut thread = test_thread_snapshot();
        thread.active_turn_id = Some("active-turn".to_string());
        let mut live_user = item_with_turn("turn-live", "live-user-id");
        live_user.source_turn_id = None;
        thread.items = vec![
            live_user,
            assistant_item(Some("active-turn"), "active-assistant-id", "partial"),
        ];
        let page = AppListThreadTurnsResponse {
            turn_states: vec![],
            turns: vec![
                item_with_turn("turn-1", "persisted-user-id"),
                assistant_item(Some("turn-1"), "persisted-assistant-id", "final"),
            ],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        assert!(
            thread
                .items
                .iter()
                .any(|item| item.id == "active-assistant-id")
        );
    }

    #[test]
    fn merge_paged_turns_prunes_stale_stream_text_for_existing_turn_replay() {
        let mut thread = test_thread_snapshot();
        thread.items = vec![
            item_with_turn("turn-1", "persisted-user-id"),
            assistant_item(Some("turn-1"), "persisted-assistant-id", "final"),
            assistant_item(Some("turn-1"), "late-stream-assistant-id", "late duplicate"),
        ];
        let page = AppListThreadTurnsResponse {
            turn_states: vec![],
            turns: vec![
                item_with_turn("turn-1", "persisted-user-id"),
                assistant_item(Some("turn-1"), "persisted-assistant-id", "final"),
            ],
            next_cursor: None,
            backwards_cursor: None,
        };
        merge_paged_turns(&mut thread, &page, AppTurnsSortDirection::Descending);
        let ids: Vec<String> = thread.items.iter().map(|item| item.id.clone()).collect();
        assert_eq!(ids, vec!["persisted-user-id", "persisted-assistant-id"]);
    }

    #[test]
    fn apply_pagination_merge_preserves_existing_on_empty_turns() {
        let mut existing = test_thread_snapshot();
        existing.items = vec![item_with_turn("turn-1", "i1")];
        existing.initial_turns_loaded = true;
        existing.older_turns_cursor = Some("cursor-1".to_string());
        let mut target = test_thread_snapshot();
        target.items = Vec::new();
        apply_pagination_merge(Some(&existing), &mut target, &[]);
        assert_eq!(target.items.len(), 1);
        assert!(target.initial_turns_loaded);
        assert_eq!(target.older_turns_cursor.as_deref(), Some("cursor-1"));
    }

    #[test]
    fn apply_pagination_merge_legacy_nonempty_is_authoritative() {
        let mut existing = test_thread_snapshot();
        existing.items = vec![item_with_turn("stale", "s1")];
        existing.initial_turns_loaded = true;
        existing.older_turns_cursor = Some("cursor-1".to_string());
        let mut target = test_thread_snapshot();
        // target already populated from upstream thread with hydrated items.
        target.items = vec![item_with_turn("turn-1", "i1")];
        let upstream_turn = upstream::Turn {
            id: "turn-1".to_string(),
            status: upstream::TurnStatus::Completed,
            items: Vec::new(),
            items_view: upstream::TurnItemsView::Full,
            error: None,
            started_at: None,
            completed_at: None,
            duration_ms: None,
        };
        apply_pagination_merge(Some(&existing), &mut target, &[upstream_turn]);
        // Legacy path: keep target's upstream-hydrated items, clear older
        // cursor, mark loaded.
        assert_eq!(target.items.len(), 1);
        assert!(target.initial_turns_loaded);
        assert!(target.older_turns_cursor.is_none());
    }

    #[test]
    fn apply_pagination_merge_no_existing_marks_initial_false() {
        let mut target = test_thread_snapshot();
        apply_pagination_merge(None, &mut target, &[]);
        assert!(!target.initial_turns_loaded);
        assert!(target.older_turns_cursor.is_none());
    }

    /// A freshly-started thread has no turns to page. The reducer must mark
    /// `initial_turns_loaded = true` immediately so the iOS conversation
    /// view does not auto-fire `thread/turns/list` (which the server
    /// rejects with "thread not materialized" until the first user turn
    /// lands).
    #[tokio::test]
    async fn apply_thread_start_response_marks_initial_turns_loaded() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );
        let response = upstream::ThreadStartResponse {
            thread: test_upstream_thread("thread-1"),
            model: "gpt-5".to_string(),
            model_provider: "openai".to_string(),
            service_tier: None,
            cwd: test_abs_path("/tmp"),
            runtime_workspace_roots: Vec::new(),
            instruction_sources: Vec::new(),
            approval_policy: upstream::AskForApproval::Never,
            approvals_reviewer: upstream::ApprovalsReviewer::User,
            sandbox: upstream::SandboxPolicy::DangerFullAccess,
            active_permission_profile: None,
            reasoning_effort: None,
            multi_agent_mode: Default::default(),
        };
        let key = client
            .apply_thread_start_response("srv", &response)
            .expect("thread/start reconciliation");
        let snapshot = client.app_store.thread_snapshot(&key).expect("snapshot");
        assert!(
            snapshot.initial_turns_loaded,
            "new thread must be marked initial_turns_loaded"
        );
        assert!(snapshot.older_turns_cursor.is_none());
    }

    /// `thread/read` carries embedded turns and is authoritative — the
    /// reducer must mark `initial_turns_loaded = true` so the spinner
    /// clears and `older_turns_cursor` gets cleared.
    #[tokio::test]
    async fn apply_thread_read_response_marks_initial_turns_loaded() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );
        let response = upstream::ThreadReadResponse {
            thread: test_upstream_thread("thread-1"),
            approval_policy: None,
            sandbox: None,
        };
        let key = client
            .apply_thread_read_response("srv", &response)
            .expect("thread/read reconciliation");
        let snapshot = client.app_store.thread_snapshot(&key).expect("snapshot");
        assert!(
            snapshot.initial_turns_loaded,
            "thread/read response must mark initial_turns_loaded"
        );
        assert!(snapshot.older_turns_cursor.is_none());
    }

    /// Regression for task #12. A `thread/read` response with embedded
    /// turns is authoritative: it should clear `older_turns_cursor` and
    /// mark `initial_turns_loaded`.
    #[tokio::test]
    async fn apply_thread_read_with_embedded_turns_clears_cursor() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );
        // Prime the snapshot with a stale cursor to confirm the embedded
        // path clears it.
        let info = crate::types::ThreadInfo {
            id: "thread-1".to_string(),
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
        };
        let mut primed = ThreadSnapshot::from_info("srv", info);
        primed.older_turns_cursor = Some("stale-cursor".to_string());
        primed.initial_turns_loaded = false;
        client.app_store.upsert_thread_snapshot(primed);

        let mut embedded_thread = test_upstream_thread("thread-1");
        embedded_thread.turns = vec![upstream::Turn {
            id: "turn-1".to_string(),
            status: upstream::TurnStatus::Completed,
            items: vec![upstream::ThreadItem::UserMessage {
                id: "server-user-item".to_string(),
                client_id: None,
                content: vec![upstream::UserInput::Text {
                    text: "hi".to_string(),
                    text_elements: Vec::new(),
                }],
            }],
            items_view: upstream::TurnItemsView::Full,
            error: None,
            started_at: None,
            completed_at: None,
            duration_ms: None,
        }];
        let response = upstream::ThreadReadResponse {
            thread: embedded_thread,
            approval_policy: None,
            sandbox: None,
        };
        let key = client
            .apply_thread_read_response("srv", &response)
            .expect("thread/read");
        let snapshot = client.app_store.thread_snapshot(&key).expect("snapshot");
        assert!(snapshot.initial_turns_loaded);
        assert!(
            snapshot.older_turns_cursor.is_none(),
            "embedded-turns path must clear cursor"
        );
    }

    /// Regression for task #12. A `thread/read` response with NO embedded
    /// turns (paginated server reply) must preserve the existing
    /// `older_turns_cursor` so the cursor stored by
    /// `apply_thread_turns_page` survives subsequent refreshes. Without
    /// this preservation, "Load earlier messages" never shows up on
    /// Android after `load_thread_turns_page` returned `has_more=true`.
    #[tokio::test]
    async fn apply_thread_read_with_empty_turns_preserves_pagination_state() {
        let client = MobileClient::new();
        client.app_store.upsert_server(
            &ServerConfig {
                server_id: "srv".to_string(),
                display_name: "Server".to_string(),
                host: "localhost".to_string(),
                port: 8390,
                websocket_url: None,
                is_local: true,
                tls: false,
            },
            ServerHealthSnapshot::Connected,
        );
        // Prime the snapshot as if load_thread_turns_page had just
        // applied a page: items populated, cursor stored, flag set.
        let info = crate::types::ThreadInfo {
            id: "thread-1".to_string(),
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
        };
        let mut primed = ThreadSnapshot::from_info("srv", info);
        primed.items = vec![item_with_turn("turn-5", "i5")];
        primed.older_turns_cursor = Some("older-cursor".to_string());
        primed.initial_turns_loaded = true;
        client.app_store.upsert_thread_snapshot(primed);

        // thread/read arrives with no embedded turns (paginated server).
        let mut empty_thread = test_upstream_thread("thread-1");
        empty_thread.turns = Vec::new();
        let response = upstream::ThreadReadResponse {
            thread: empty_thread,
            approval_policy: None,
            sandbox: None,
        };
        let key = client
            .apply_thread_read_response("srv", &response)
            .expect("thread/read");
        let snapshot = client.app_store.thread_snapshot(&key).expect("snapshot");
        assert!(
            snapshot.initial_turns_loaded,
            "initial_turns_loaded must remain true"
        );
        assert_eq!(
            snapshot.older_turns_cursor.as_deref(),
            Some("older-cursor"),
            "empty-turns thread/read must preserve existing pagination cursor"
        );
        assert_eq!(
            snapshot.items.len(),
            1,
            "existing paged items must be preserved when embedded turns are empty"
        );
    }
}
