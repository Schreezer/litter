use super::*;
use super::{WidgetFinalizedPayload, WidgetWaiter};

#[derive(Clone)]
pub(super) struct DynamicToolSessionTarget {
    server_id: String,
    session: Arc<ServerSession>,
    config: ServerConfig,
}

pub(super) async fn handle_dynamic_tool_call_request(
    session: Arc<ServerSession>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    app_store: Arc<AppStoreReducer>,
    widget_waiters: Arc<StdMutex<HashMap<String, WidgetWaiter>>>,
    saved_apps_directory: Arc<StdMutex<Option<String>>>,
    platform_dynamic_tool_handler: Arc<
        StdMutex<Option<Arc<dyn crate::types::models::PlatformDynamicToolHandler>>>,
    >,
    request_id: upstream::RequestId,
    params: upstream::DynamicToolCallParams,
    runtime_kind: AgentRuntimeKind,
) -> Result<(), RpcError> {
    // `show_widget` routing: if a `widget_waiter` is registered for the
    // thread (the Update-overlay path), fulfill it and skip auto-save —
    // the waiter owns this call. Otherwise, run the auto-save upsert so
    // every finalized generative widget persists as a saved app.
    if params.tool.eq_ignore_ascii_case("show_widget") {
        let fulfilled = try_fulfill_widget_waiter(&widget_waiters, &params);
        if !fulfilled {
            auto_upsert_saved_app(&saved_apps_directory, &params);
        }
    }
    let response = match execute_dynamic_tool_call(
        sessions,
        Arc::clone(&app_store),
        platform_dynamic_tool_handler,
        &params,
    )
    .await
    {
        Ok(text) => upstream::DynamicToolCallResponse {
            content_items: vec![upstream::DynamicToolCallOutputContentItem::InputText { text }],
            success: true,
        },
        Err(message) => upstream::DynamicToolCallResponse {
            content_items: vec![upstream::DynamicToolCallOutputContentItem::InputText {
                text: message,
            }],
            success: false,
        },
    };

    let request_id = match request_id {
        upstream::RequestId::Integer(value) => serde_json::Value::Number(value.into()),
        upstream::RequestId::String(value) => serde_json::Value::String(value),
    };
    let result = serde_json::to_value(response).map_err(|error| {
        RpcError::Deserialization(format!("serialize dynamic tool response: {error}"))
    })?;
    session
        .respond_for_runtime(runtime_kind, request_id, result)
        .await
}

pub(super) async fn execute_dynamic_tool_call(
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    app_store: Arc<AppStoreReducer>,
    platform_dynamic_tool_handler: Arc<
        StdMutex<Option<Arc<dyn crate::types::models::PlatformDynamicToolHandler>>>,
    >,
    params: &upstream::DynamicToolCallParams,
) -> Result<String, String> {
    let targets = snapshot_dynamic_tool_sessions(&sessions);

    match params.tool.as_str() {
        "list_servers" => Ok(list_servers_tool_output(&targets)),
        "list_sessions" => list_sessions_tool_output(&targets, app_store, &params.arguments).await,
        "visualize_read_me" => {
            crate::widget_guidelines::handle_visualize_read_me(&params.arguments)
        }
        "show_widget" => crate::widget_guidelines::handle_show_widget(&params.arguments),
        "present_course_plan" => execute_present_course_plan(
            &platform_dynamic_tool_handler,
            &params.thread_id,
            &params.arguments,
        ),
        tool => execute_platform_dynamic_tool(
            &platform_dynamic_tool_handler,
            &params.thread_id,
            tool,
            &params.arguments,
        ),
    }
}

fn execute_present_course_plan(
    platform_dynamic_tool_handler: &Arc<
        StdMutex<Option<Arc<dyn crate::types::models::PlatformDynamicToolHandler>>>,
    >,
    thread_id: &str,
    arguments: &serde_json::Value,
) -> Result<String, String> {
    // Validate the shared schema first, then synchronously cross the platform
    // boundary. iOS owns the protected presented/approved plan files;
    // returning success before that write would let course_bash reuse approval
    // for an older revision.
    handle_present_course_plan(arguments)?;
    execute_platform_dynamic_tool(
        platform_dynamic_tool_handler,
        thread_id,
        "present_course_plan",
        arguments,
    )
}

fn execute_platform_dynamic_tool(
    platform_dynamic_tool_handler: &Arc<
        StdMutex<Option<Arc<dyn crate::types::models::PlatformDynamicToolHandler>>>,
    >,
    thread_id: &str,
    tool: &str,
    arguments: &serde_json::Value,
) -> Result<String, String> {
    let handler = platform_dynamic_tool_handler
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
        .ok_or_else(|| format!("Unknown dynamic tool: {tool}"))?;
    let arguments_json = serde_json::to_string(arguments)
        .map_err(|error| format!("serialize dynamic tool arguments: {error}"))?;
    let invocation = crate::types::models::AppPlatformDynamicToolInvocation {
        thread_id: thread_id.to_string(),
        tool: tool.to_string(),
        arguments_json,
    };
    let result = handler
        .handle_dynamic_tool(invocation)
        .ok_or_else(|| format!("Unknown dynamic tool: {tool}"))?;
    if result.success {
        Ok(result.output)
    } else {
        Err(result.output)
    }
}

fn handle_present_course_plan(arguments: &serde_json::Value) -> Result<String, String> {
    let object = arguments
        .as_object()
        .ok_or_else(|| "Course plan arguments must be a JSON object.".to_string())?;
    for field in [
        "plan_id",
        "title",
        "summary",
        "outcome",
        "starting_point",
        "focus_gap",
        "estimated_duration",
    ] {
        let valid = object
            .get(field)
            .and_then(serde_json::Value::as_str)
            .is_some_and(|value| !value.trim().is_empty());
        if !valid {
            return Err(format!(
                "Course plan field '{field}' must be a non-empty string."
            ));
        }
    }

    let revision = object
        .get("revision")
        .and_then(serde_json::Value::as_u64)
        .filter(|value| *value > 0)
        .ok_or_else(|| "Course plan revision must be a positive integer.".to_string())?;
    let chapters = object
        .get("chapters")
        .and_then(serde_json::Value::as_array)
        .filter(|chapters| !chapters.is_empty())
        .ok_or_else(|| "Course plan must contain at least one chapter.".to_string())?;

    for (index, chapter) in chapters.iter().enumerate() {
        let chapter = chapter
            .as_object()
            .ok_or_else(|| format!("Chapter {} must be a JSON object.", index + 1))?;
        for field in ["id", "title", "objective"] {
            let valid = chapter
                .get(field)
                .and_then(serde_json::Value::as_str)
                .is_some_and(|value| !value.trim().is_empty());
            if !valid {
                return Err(format!(
                    "Chapter {} field '{field}' must be a non-empty string.",
                    index + 1
                ));
            }
        }
        let deliverables = chapter
            .get("deliverables")
            .and_then(serde_json::Value::as_array)
            .ok_or_else(|| format!("Chapter {} deliverables must be an array.", index + 1))?;
        if deliverables.iter().any(|deliverable| {
            deliverable
                .as_str()
                .map_or(true, |value| value.trim().is_empty())
        }) {
            return Err(format!(
                "Chapter {} deliverables must contain only non-empty strings.",
                index + 1
            ));
        }
    }

    Ok(serde_json::json!({
        "status": "presented",
        "plan_id": object.get("plan_id"),
        "revision": revision,
        "message": "Course plan rendered in the native conversation. Wait for the learner to approve it or request changes."
    })
    .to_string())
}

#[cfg(test)]
mod course_plan_tests {
    use super::{
        execute_platform_dynamic_tool, execute_present_course_plan, handle_present_course_plan,
    };
    use crate::types::models::{
        AppPlatformDynamicToolInvocation, AppPlatformDynamicToolResult, PlatformDynamicToolHandler,
    };
    use serde_json::json;
    use std::sync::{Arc, Mutex};

    struct NativePageTool;

    impl PlatformDynamicToolHandler for NativePageTool {
        fn handle_dynamic_tool(
            &self,
            invocation: AppPlatformDynamicToolInvocation,
        ) -> Option<AppPlatformDynamicToolResult> {
            (invocation.tool == "native-editor-fetch").then(|| AppPlatformDynamicToolResult {
                success: true,
                output: json!({
                    "thread_id": invocation.thread_id,
                    "arguments": invocation.arguments_json,
                })
                .to_string(),
            })
        }
    }

    struct CoursePlanTool;

    impl PlatformDynamicToolHandler for CoursePlanTool {
        fn handle_dynamic_tool(
            &self,
            invocation: AppPlatformDynamicToolInvocation,
        ) -> Option<AppPlatformDynamicToolResult> {
            (invocation.tool == "present_course_plan").then(|| AppPlatformDynamicToolResult {
                success: true,
                output: format!("persisted:{}", invocation.thread_id),
            })
        }
    }

    fn valid_plan() -> serde_json::Value {
        json!({
            "plan_id": "diffusion-models",
            "revision": 2,
            "title": "Diffusion Models",
            "summary": "Learn the complete denoising process.",
            "outcome": "Build a small image sampler.",
            "starting_point": "Python and neural network basics.",
            "focus_gap": "Connect the math to implementation.",
            "estimated_duration": "4h",
            "chapters": [{
                "id": "first-principles",
                "title": "First principles",
                "objective": "Understand forward and reverse diffusion.",
                "deliverables": ["lesson", "exercise"]
            }]
        })
    }

    #[test]
    fn accepts_a_complete_semantic_course_plan() {
        let output = handle_present_course_plan(&valid_plan()).expect("valid plan");
        let value: serde_json::Value = serde_json::from_str(&output).expect("JSON response");
        assert_eq!(value["status"], "presented");
        assert_eq!(value["plan_id"], "diffusion-models");
        assert_eq!(value["revision"], 2);
    }

    #[test]
    fn rejects_missing_or_invalid_plan_content() {
        let mut plan = valid_plan();
        plan["revision"] = json!(0);
        assert!(
            handle_present_course_plan(&plan)
                .expect_err("revision zero must fail")
                .contains("positive integer")
        );

        let mut plan = valid_plan();
        plan["chapters"][0]["deliverables"] = json!([""]);
        assert!(
            handle_present_course_plan(&plan)
                .expect_err("blank deliverable must fail")
                .contains("non-empty strings")
        );
    }

    #[test]
    fn valid_plan_must_persist_through_phone_handler_before_success() {
        let handler: Arc<dyn PlatformDynamicToolHandler> = Arc::new(CoursePlanTool);
        let slot = Arc::new(Mutex::new(Some(handler)));
        assert_eq!(
            execute_present_course_plan(&slot, "thread-course-7", &valid_plan())
                .expect("phone persisted plan"),
            "persisted:thread-course-7"
        );

        let missing = Arc::new(Mutex::new(None));
        assert!(
            execute_present_course_plan(&missing, "thread-course-7", &valid_plan())
                .expect_err("missing phone handler must fail")
                .contains("Unknown dynamic tool")
        );

        let declining: Arc<dyn PlatformDynamicToolHandler> = Arc::new(NativePageTool);
        let declining_slot = Arc::new(Mutex::new(Some(declining)));
        assert!(
            execute_present_course_plan(&declining_slot, "thread-course-7", &valid_plan())
                .expect_err("declined plan must fail")
                .contains("Unknown dynamic tool")
        );
    }

    #[test]
    fn routes_unknown_shared_tools_to_the_platform_handler_with_thread_scope() {
        let handler: Arc<dyn PlatformDynamicToolHandler> = Arc::new(NativePageTool);
        let slot = Arc::new(Mutex::new(Some(handler)));
        let output = execute_platform_dynamic_tool(
            &slot,
            "thread-course-7",
            "native-editor-fetch",
            &json!({"id": "page-1"}),
        )
        .expect("native tool result");
        let value: serde_json::Value = serde_json::from_str(&output).expect("JSON output");

        assert_eq!(value["thread_id"], "thread-course-7");
        assert!(
            value["arguments"]
                .as_str()
                .is_some_and(|json| json.contains("page-1"))
        );
        assert!(
            execute_platform_dynamic_tool(
                &slot,
                "thread-course-7",
                "unsupported-native-tool",
                &json!({}),
            )
            .expect_err("declined tool must remain unknown")
            .contains("Unknown dynamic tool")
        );
    }
}

pub(super) fn snapshot_dynamic_tool_sessions(
    sessions: &Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
) -> Vec<DynamicToolSessionTarget> {
    let guard = match sessions.read() {
        Ok(guard) => guard,
        Err(error) => {
            warn!("MobileClient: recovering poisoned sessions read lock");
            error.into_inner()
        }
    };

    let mut targets = guard
        .iter()
        .map(|(server_id, session)| DynamicToolSessionTarget {
            server_id: server_id.clone(),
            session: Arc::clone(session),
            config: session.config().clone(),
        })
        .collect::<Vec<_>>();
    targets.sort_by(|lhs, rhs| dynamic_tool_server_name(lhs).cmp(&dynamic_tool_server_name(rhs)));
    targets
}

pub(super) fn dynamic_tool_server_name(target: &DynamicToolSessionTarget) -> String {
    if target.config.is_local {
        "local".to_string()
    } else {
        target.config.display_name.clone()
    }
}

pub(super) fn dynamic_tool_matches_server(
    target: &DynamicToolSessionTarget,
    requested_server: &str,
) -> bool {
    let requested = requested_server.trim();
    if requested.is_empty() {
        return false;
    }
    target.server_id.eq_ignore_ascii_case(requested)
        || target.config.display_name.eq_ignore_ascii_case(requested)
        || target.config.host.eq_ignore_ascii_case(requested)
        || (target.config.is_local && requested.eq_ignore_ascii_case("local"))
}

pub(super) fn dynamic_tool_sessions_for_request(
    targets: &[DynamicToolSessionTarget],
    requested_server: Option<&str>,
    allow_all_if_missing: bool,
) -> Result<Vec<DynamicToolSessionTarget>, String> {
    match requested_server
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(requested_server) => {
            let matches = targets
                .iter()
                .filter(|target| dynamic_tool_matches_server(target, requested_server))
                .cloned()
                .collect::<Vec<_>>();
            if matches.is_empty() {
                Err(format!("Server '{requested_server}' is not connected."))
            } else {
                Ok(matches)
            }
        }
        None if allow_all_if_missing => Ok(targets.to_vec()),
        None => Err("A server name or ID is required.".to_string()),
    }
}

pub(super) fn dynamic_tool_string(arguments: &serde_json::Value, keys: &[&str]) -> Option<String> {
    let object = arguments.as_object()?;
    keys.iter().find_map(|key| {
        object
            .get(*key)
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
    })
}

pub(super) fn dynamic_tool_u32(arguments: &serde_json::Value, keys: &[&str]) -> Option<u32> {
    let object = arguments.as_object()?;
    keys.iter().find_map(|key| match object.get(*key) {
        Some(serde_json::Value::Number(value)) => {
            value.as_u64().and_then(|n| u32::try_from(n).ok())
        }
        Some(serde_json::Value::String(value)) => value.trim().parse::<u32>().ok(),
        _ => None,
    })
}

pub(super) fn truncate_dynamic_tool_text(text: &str, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text.to_string();
    }
    let mut end = max_bytes;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    let mut truncated = text[..end].trim_end().to_string();
    truncated.push_str("...");
    truncated
}

pub(super) fn serialize_dynamic_tool_payload(
    payload: serde_json::Value,
    max_bytes: usize,
) -> String {
    let text = serde_json::to_string(&payload).unwrap_or_else(|_| "{}".to_string());
    truncate_dynamic_tool_text(&text, max_bytes)
}

pub(super) fn list_servers_tool_output(targets: &[DynamicToolSessionTarget]) -> String {
    let items = targets
        .iter()
        .map(|target| {
            serde_json::json!({
                "id": target.server_id,
                "name": dynamic_tool_server_name(target),
                "hostname": truncate_dynamic_tool_text(&target.config.host, 200),
                "isConnected": true,
                "isLocal": target.config.is_local,
            })
        })
        .collect::<Vec<_>>();

    let summary = match items.len() {
        0 => "No connected servers found.".to_string(),
        1 => {
            let name = items[0]
                .get("name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("the server");
            format!("Found 1 connected server: {name}.")
        }
        count => {
            let names = items
                .iter()
                .take(3)
                .filter_map(|item| item.get("name").and_then(serde_json::Value::as_str))
                .collect::<Vec<_>>();
            let listed = names.join(", ");
            let extra = count.saturating_sub(names.len());
            if extra > 0 {
                format!("Found {count} connected servers: {listed}, and {extra} more.")
            } else {
                format!("Found {count} connected servers: {listed}.")
            }
        }
    };

    serialize_dynamic_tool_payload(
        serde_json::json!({
            "type": "servers",
            "summary": summary,
            "items": items,
        }),
        24_000,
    )
}

pub(super) async fn list_sessions_tool_output(
    targets: &[DynamicToolSessionTarget],
    app_store: Arc<AppStoreReducer>,
    arguments: &serde_json::Value,
) -> Result<String, String> {
    let limit = dynamic_tool_u32(arguments, &["limit"])
        .unwrap_or(20)
        .clamp(1, 40);
    let requested_server = dynamic_tool_string(arguments, &["server_id", "server"]);
    let targets = dynamic_tool_sessions_for_request(targets, requested_server.as_deref(), true)?;

    let mut items = Vec::new();
    let mut errors = Vec::new();

    for target in targets {
        let response = dynamic_tool_request_typed::<upstream::ThreadListResponse, _>(
            &target.session,
            "thread/list",
            &upstream::ThreadListParams {
                cursor: None,
                limit: Some(limit),
                sort_key: None,
                sort_direction: None,
                model_providers: None,
                source_kinds: None,
                originators: None,
                archived: None,
                section_id: None,
                project_id: None,
                cwd: None,
                search_term: None,
                use_state_db_only: false,
                parent_thread_id: None,
                ancestor_thread_id: None,
            },
        )
        .await;

        match response {
            Ok(response) => {
                let threads = response
                    .data
                    .into_iter()
                    .filter_map(thread_info_from_upstream_thread)
                    .collect::<Vec<_>>();
                app_store.sync_thread_list(&target.server_id, &threads);
                items.extend(threads.into_iter().map(|thread| {
                    serde_json::json!({
                        "id": thread.id,
                        "preview": thread.preview.map(|value| truncate_dynamic_tool_text(&value, 280)),
                        "modelProvider": thread.model_provider,
                        "updatedAt": thread.updated_at,
                        "cwd": thread.cwd.map(|value| truncate_dynamic_tool_text(&value, 240)),
                        "serverId": target.server_id,
                        "serverName": truncate_dynamic_tool_text(&dynamic_tool_server_name(&target), 160),
                    })
                }));
            }
            Err(error) => {
                errors.push(serde_json::json!({
                    "serverId": target.server_id,
                    "serverName": truncate_dynamic_tool_text(&dynamic_tool_server_name(&target), 160),
                    "message": truncate_dynamic_tool_text(&error, 240),
                }));
            }
        }
    }

    items.sort_by(|lhs, rhs| {
        let lhs_updated = lhs
            .get("updatedAt")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or_default();
        let rhs_updated = rhs
            .get("updatedAt")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or_default();
        rhs_updated.cmp(&lhs_updated)
    });
    if items.len() > limit as usize {
        items.truncate(limit as usize);
    }

    let summary = if items.is_empty() {
        if errors.is_empty() {
            "No sessions found.".to_string()
        } else {
            format!(
                "No sessions found. {} server lookup{} failed.",
                errors.len(),
                if errors.len() == 1 { "" } else { "s" }
            )
        }
    } else {
        let server_count = items
            .iter()
            .filter_map(|item| item.get("serverId").and_then(serde_json::Value::as_str))
            .collect::<std::collections::HashSet<_>>()
            .len();
        let preview = items[0]
            .get("preview")
            .and_then(serde_json::Value::as_str)
            .map(|value| truncate_dynamic_tool_text(value, 80))
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "an untitled session".to_string());
        let server_name = items[0]
            .get("serverName")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("unknown server");
        let mut summary = format!(
            "Found {} session{} across {} server{}. The most recent is {} on {}.",
            items.len(),
            if items.len() == 1 { "" } else { "s" },
            server_count,
            if server_count == 1 { "" } else { "s" },
            preview,
            server_name,
        );
        if !errors.is_empty() {
            summary.push_str(" Some servers could not be queried.");
        }
        summary
    };

    let mut payload = serde_json::json!({
        "type": "sessions",
        "summary": summary,
        "items": items,
    });
    if let serde_json::Value::Object(object) = &mut payload
        && !errors.is_empty()
    {
        object.insert("errors".to_string(), serde_json::Value::Array(errors));
    }
    Ok(serialize_dynamic_tool_payload(payload, 64_000))
}

pub(super) async fn dynamic_tool_request_typed<R, P>(
    session: &Arc<ServerSession>,
    method: &str,
    params: &P,
) -> Result<R, String>
where
    R: serde::de::DeserializeOwned,
    P: serde::Serialize,
{
    let params_json = serde_json::to_value(params)
        .map_err(|error| format!("serialize {method} params: {error}"))?;
    let response = session
        .request(method, params_json)
        .await
        .map_err(|error| format!("{method} request failed: {error}"))?;
    serde_json::from_value(response)
        .map_err(|error| format!("deserialize {method} response: {error}"))
}

/// If a waiter is registered for the thread that emitted this
/// `show_widget` call, extract its HTML/title/dimensions and send them
/// over the oneshot. Used by `AppClient::update_saved_app` to block until
/// the model emits a new widget. Returns `true` when a waiter was
/// actually fulfilled — callers use this to skip the auto-save upsert
/// on the overlay update path.
fn try_fulfill_widget_waiter(
    widget_waiters: &Arc<StdMutex<HashMap<String, WidgetWaiter>>>,
    params: &upstream::DynamicToolCallParams,
) -> bool {
    let thread_id = params.thread_id.clone();
    let arguments = &params.arguments;
    let Some(object) = arguments.as_object() else {
        return false;
    };
    let widget_html = object
        .get("widget_code")
        .or_else(|| object.get("widgetCode"))
        .and_then(|v| v.as_str())
        .map(ToString::to_string);
    let Some(widget_html) = widget_html else {
        return false;
    };
    if widget_html.is_empty() {
        return false;
    }
    let title = object
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("Saved App")
        .to_string();
    let width = object
        .get("width")
        .and_then(|v| v.as_f64())
        .unwrap_or(800.0);
    let height = object
        .get("height")
        .and_then(|v| v.as_f64())
        .unwrap_or(600.0);

    let waiter = {
        let mut guard = widget_waiters
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.remove(&thread_id)
    };
    if let Some(waiter) = waiter {
        let _ = waiter.sender.send(WidgetFinalizedPayload {
            widget_html,
            width,
            height,
            title,
        });
        true
    } else {
        false
    }
}

/// Auto-save path: when a `show_widget` call lands on a thread with no
/// active update-overlay waiter, upsert the app under
/// `(thread_id, app_id)`. Requires the platform to have set the saved
/// apps directory via `AppClient::set_saved_apps_directory`; if unset,
/// this is a no-op (pre-R2 environments, tests).
fn auto_upsert_saved_app(
    saved_apps_directory: &Arc<StdMutex<Option<String>>>,
    params: &upstream::DynamicToolCallParams,
) {
    let directory = {
        let guard = saved_apps_directory
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match guard.clone() {
            Some(d) if !d.is_empty() => d,
            _ => return,
        }
    };
    let Some(object) = params.arguments.as_object() else {
        return;
    };
    // Require a non-empty `app_id` slug. Pre-R2 widgets without a slug
    // won't auto-save — they can still be promoted manually.
    let Some(app_id) = object
        .get("app_id")
        .or_else(|| object.get("appId"))
        .and_then(|v| v.as_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
    else {
        return;
    };
    let Some(widget_html) = object
        .get("widget_code")
        .or_else(|| object.get("widgetCode"))
        .and_then(|v| v.as_str())
    else {
        return;
    };
    if widget_html.is_empty() {
        return;
    }
    let title = object
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let width = object
        .get("width")
        .and_then(|v| v.as_f64())
        .unwrap_or(800.0);
    let height = object
        .get("height")
        .and_then(|v| v.as_f64())
        .unwrap_or(600.0);
    // The widget's JS owns `schema_version`; we default to 1 when
    // creating because the `show_widget` tool call doesn't carry it.
    // Subsequent `saveAppState` calls will bump it via the standard
    // persistence path.
    let schema_version: u32 = 1;

    match crate::saved_apps::saved_app_upsert(
        directory,
        params.thread_id.clone(),
        app_id.to_string(),
        title,
        widget_html.to_string(),
        width,
        height,
        schema_version,
    ) {
        Ok(app) => {
            debug!(
                "saved_app auto-upsert ok thread={} slug={} uuid={}",
                params.thread_id, app.app_id, app.id
            );
        }
        Err(error) => {
            warn!(
                "saved_app auto-upsert failed thread={} slug={}: {}",
                params.thread_id, app_id, error
            );
        }
    }
}
