//! Cloudflare Think chat transport for Learnfold's hosted course provider.
//!
//! Think owns the durable transcript, compaction overlays, recovery fiber, and
//! session identity. This module deliberately owns only the typed mobile wire
//! boundary and delegates client tool execution back to the platform.

use futures::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::watch;
use tokio::time::Instant;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::http::header::AUTHORIZATION;
use tokio_tungstenite::tungstenite::protocol::Message as WsMessage;
use url::Url;
use uuid::Uuid;

const AGENT_ROUTE: &str = "agents/hosted-course-agent";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
const FRAME_TIMEOUT: Duration = Duration::from_secs(180);
const MAX_TOOL_SCHEMA_BYTES: usize = 256 * 1024;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HostedAgentError {
    #[error("Invalid hosted-agent configuration: {detail}")]
    InvalidConfiguration { detail: String },
    #[error("Hosted-agent connection failed: {detail}")]
    Connection { detail: String },
    #[error("Hosted-agent protocol failed: {detail}")]
    Protocol { detail: String },
    #[error("Hosted-agent request failed: {detail}")]
    Request { detail: String },
    #[error("The hosted-agent request was cancelled")]
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostedAgentToolDefinition {
    pub name: String,
    pub description: String,
    pub parameters_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostedAgentToolInvocation {
    pub session_id: String,
    pub tool_call_id: String,
    pub tool_name: String,
    pub arguments_json: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostedAgentToolResult {
    pub success: bool,
    /// JSON value when possible. Plain text is accepted and encoded as a JSON
    /// string before it crosses the Think protocol.
    pub output: String,
    pub error_message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostedAgentMessage {
    pub id: String,
    pub role: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostedAgentSessionSnapshot {
    pub messages: Vec<HostedAgentMessage>,
    pub active: bool,
    pub originating_device: bool,
    pub waiting_for_tools: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HostedAgentTurnResult {
    pub session_id: String,
    pub response_text: String,
}

#[uniffi::export(callback_interface)]
pub trait HostedAgentToolHandler: Send + Sync {
    fn execute_hosted_tool(&self, invocation: HostedAgentToolInvocation) -> HostedAgentToolResult;
}

#[uniffi::export(callback_interface)]
pub trait HostedAgentEventListener: Send + Sync {
    fn on_response_delta(&self, delta: String);
    fn on_recovering_changed(&self, recovering: bool);
}

#[derive(uniffi::Object)]
pub struct HostedAgentClient {
    base_url: Url,
    access_token: String,
    guest_secret: Option<String>,
    origin_id: Mutex<Option<String>>,
    active_cancellations: Arc<Mutex<HashMap<String, ActiveCancellation>>>,
}

struct ActiveCancellation {
    token: Uuid,
    sender: watch::Sender<bool>,
}

struct CancellationRegistration {
    session_id: String,
    token: Uuid,
    receiver: watch::Receiver<bool>,
    active_cancellations: Arc<Mutex<HashMap<String, ActiveCancellation>>>,
}

impl Drop for CancellationRegistration {
    fn drop(&mut self) {
        let mut active = self
            .active_cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if active.get(&self.session_id).map(|entry| entry.token) == Some(self.token) {
            active.remove(&self.session_id);
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl HostedAgentClient {
    #[uniffi::constructor]
    pub fn new(base_url: String, access_token: String) -> Result<Self, HostedAgentError> {
        let base_url = validated_base_url(&base_url)?;
        let access_token = access_token.trim().to_string();
        if access_token.is_empty() {
            return Err(HostedAgentError::InvalidConfiguration {
                detail: "the client access token is empty".into(),
            });
        }
        Ok(Self {
            base_url,
            access_token,
            guest_secret: None,
            origin_id: Mutex::new(None),
            active_cancellations: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    /// The platform persists this installation's random secret in its secure
    /// credential store. Rust owns the guest token exchange and wire protocol.
    #[uniffi::constructor]
    pub fn guest(base_url: String, guest_secret: String) -> Result<Self, HostedAgentError> {
        let base_url = validated_base_url(&base_url)?;
        if !matches!(base_url.scheme(), "https" | "wss")
            && !matches!(
                base_url.host_str(),
                Some("localhost" | "127.0.0.1" | "[::1]")
            )
        {
            return Err(HostedAgentError::InvalidConfiguration {
                detail: "guest access requires HTTPS except on localhost".into(),
            });
        }
        if guest_secret.len() != 64
            || !guest_secret
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(HostedAgentError::InvalidConfiguration {
                detail: "guest identity must be a 256-bit hexadecimal secret".into(),
            });
        }
        Ok(Self {
            base_url,
            access_token: String::new(),
            guest_secret: Some(guest_secret),
            origin_id: Mutex::new(None),
            active_cancellations: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    /// Nonsecret, device-local identity for native tool ownership. It must not
    /// be synchronized with the account credential or course session locator.
    pub fn set_origin_id(&self, origin_id: String) -> Result<(), HostedAgentError> {
        let id =
            Uuid::parse_str(&origin_id).map_err(|_| HostedAgentError::InvalidConfiguration {
                detail: "the hosted device origin must be a UUID".into(),
            })?;
        *self
            .origin_id
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(id.to_string());
        Ok(())
    }

    /// Cancels an in-flight turn for this client and session. The send loop
    /// emits Think's canonical cancel frame on its existing WebSocket before
    /// returning, so cancelling Swift's UniFFI task cannot strand a cloud turn.
    pub fn cancel(&self, session_id: String) -> Result<bool, HostedAgentError> {
        validate_session_id(&session_id)?;
        let active = self
            .active_cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let cancelled = active
            .get(&session_id)
            .map(|entry| entry.sender.send(true).is_ok())
            .unwrap_or(false);
        drop(active);
        if cancelled && let Some(client) = crate::ffi::shared::shared_mobile_client_if_initialized()
        {
            // The chat shows "Stopping…" until `send` settles the turn.
            client.app_store.chat_local_action(
                &crate::source::hosted::hosted_thread_key(&session_id),
                crate::store::turn::LocalAction::Stop,
            );
        }
        Ok(cancelled)
    }

    /// Reads the server-authoritative transcript. No local transcript is used
    /// as a fallback: a failure stays visible so callers never show stale
    /// history as if it were current.
    pub async fn load_messages(
        &self,
        session_id: String,
    ) -> Result<Vec<HostedAgentMessage>, HostedAgentError> {
        Ok(self.load_session(session_id).await?.messages)
    }

    /// Session activity is authoritative alongside its persisted transcript.
    pub async fn load_session(
        &self,
        session_id: String,
    ) -> Result<HostedAgentSessionSnapshot, HostedAgentError> {
        validate_session_id(&session_id)?;
        let (mut socket, messages, activity) = self.connect(&session_id).await?;
        let _ = socket.close(None).await;
        let adapter = crate::source::hosted::HostedAdapter::attach(&session_id);
        if !activity.active {
            adapter.hydrate_idle_activity(&messages, activity.terminal_status.as_deref());
        }
        adapter.hydrate(&messages);
        if activity.active {
            adapter.hydrate_activity(
                &messages,
                activity.originating_device,
                activity.waiting_for_tools,
            );
        }
        Ok(HostedAgentSessionSnapshot {
            messages: project_messages(&messages),
            active: activity.active,
            originating_device: activity.originating_device,
            waiting_for_tools: activity.waiting_for_tools,
        })
    }

    /// Only the originating device may recover an interrupted client-tool
    /// pause. The platform must first flush/re-read its authoritative pages.
    /// No tool execution or model turn is started by this operation.
    pub async fn recover_interrupted_session(
        &self,
        session_id: String,
        workspace_id: String,
        refreshed_pages_receipt: String,
    ) -> Result<bool, HostedAgentError> {
        validate_session_id(&session_id)?;
        validate_workspace_id(&workspace_id)?;
        if refreshed_pages_receipt.len() != 64
            || !refreshed_pages_receipt
                .bytes()
                .all(|b| b.is_ascii_hexdigit())
        {
            return Err(HostedAgentError::InvalidConfiguration {
                detail: "course pages must be refreshed before recovering a hosted tool pause"
                    .into(),
            });
        }
        let (mut socket, _, activity) = self.connect(&session_id).await?;
        if !activity.active {
            let _ = socket.close(None).await;
            return Ok(false);
        }
        if !activity.originating_device || !activity.waiting_for_tools {
            let _ = socket.close(None).await;
            return Err(HostedAgentError::Request { detail: "Only the original device can recover an interrupted Hosted tool pause. A running task must finish or be cancelled there first.".into() });
        }
        let request_id = Uuid::new_v4().to_string();
        send_json(
            &mut socket,
            &json!({
                "type":"learnfold_hosted_recover_interrupted", "id":request_id,
                "workspaceId":workspace_id, "refreshedPagesReceipt":refreshed_pages_receipt,
            }),
        )
        .await?;
        loop {
            let frame = next_json(&mut socket).await?;
            if frame.get("type").and_then(Value::as_str) != Some("learnfold_hosted_recovery_result")
                || frame.get("id").and_then(Value::as_str) != Some(request_id.as_str())
            {
                continue;
            }
            let _ = socket.close(None).await;
            if frame.get("success").and_then(Value::as_bool) == Some(true) {
                return Ok(true);
            }
            return Err(HostedAgentError::Request {
                detail: frame.get("error").and_then(Value::as_str).unwrap_or("The interrupted Hosted task could not be recovered. Its history remains saved.").to_string(),
            });
        }
    }

    /// Sends one user turn. Think remains authoritative for persistence,
    /// compaction, recovery and auto-continuation. Client tool calls are
    /// executed synchronously at the UniFFI boundary, then returned to Think
    /// with `autoContinue` so its agent loop resumes durably.
    ///
    /// `message_id` is the learner message's id. Pass the platform's
    /// optimistic message id so the chat row and a later
    /// `UserMessageFailed` refer to the same message; `None` mints one.
    #[allow(clippy::too_many_arguments)]
    pub async fn send(
        &self,
        session_id: String,
        workspace_id: String,
        prompt: String,
        message_id: Option<String>,
        tools: Vec<HostedAgentToolDefinition>,
        tool_handler: Box<dyn HostedAgentToolHandler>,
        listener: Box<dyn HostedAgentEventListener>,
    ) -> Result<HostedAgentTurnResult, HostedAgentError> {
        validate_session_id(&session_id)?;
        validate_workspace_id(&workspace_id)?;
        if prompt.trim().is_empty() {
            return Err(HostedAgentError::InvalidConfiguration {
                detail: "the prompt is empty".into(),
            });
        }
        let client_tools = tool_schemas(&tools)?;

        // HostedAdapter mirrors this turn into the shared store as canonical
        // source events; the listener keeps working unchanged.
        let mut adapter = crate::source::hosted::HostedAdapter::attach(&session_id);
        let message_id = message_id
            .map(|id| id.trim().to_string())
            .filter(|id| !id.is_empty())
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        let request_id = Uuid::new_v4().to_string();
        let result = self
            .send_turn(
                session_id,
                workspace_id,
                prompt,
                client_tools,
                message_id,
                request_id,
                tool_handler,
                listener,
                &mut adapter,
            )
            .await;
        if adapter.has_started() {
            adapter.finish(&result);
        }
        result
    }
}

impl HostedAgentClient {
    #[allow(clippy::too_many_arguments)]
    async fn send_turn(
        &self,
        session_id: String,
        workspace_id: String,
        prompt: String,
        client_tools: Value,
        message_id: String,
        request_id: String,
        tool_handler: Box<dyn HostedAgentToolHandler>,
        listener: Box<dyn HostedAgentEventListener>,
        adapter: &mut crate::source::hosted::HostedAdapter,
    ) -> Result<HostedAgentTurnResult, HostedAgentError> {
        let mut cancellation = self.register_cancellation(&session_id);
        let (mut socket, mut messages, activity) = self.connect(&session_id).await?;
        if activity.active {
            let _ = socket.close(None).await;
            return Err(HostedAgentError::Request {
                detail: "This Hosted conversation is still working on its original device. Wait for that task to finish, sync the course, then reopen the discussion to continue.".into(),
            });
        }
        if *cancellation.receiver.borrow() {
            return Err(HostedAgentError::Cancelled);
        }
        adapter.begin(&message_id, &prompt);
        messages.push(json!({
            "id": message_id,
            "role": "user",
            "parts": [{ "type": "text", "text": prompt }],
        }));

        let body = json!({
            "messages": messages,
            "clientTools": client_tools,
            "workspaceId": workspace_id,
        });
        send_json(
            &mut socket,
            &json!({
                "type": "cf_agent_use_chat_request",
                "id": request_id,
                "init": {
                    "method": "POST",
                    "body": serde_json::to_string(&body).map_err(protocol_error)?,
                },
            }),
        )
        .await?;

        let tool_handler: Arc<dyn HostedAgentToolHandler> = Arc::from(tool_handler);
        let listener: Arc<dyn HostedAgentEventListener> = Arc::from(listener);
        let mut response_text = String::new();
        let mut handled_tool_calls = HashSet::new();
        let mut stream = HostedStreamState::new(request_id);
        let mut progress_deadline = Instant::now() + FRAME_TIMEOUT;

        loop {
            let frame = next_json_or_cancel(
                &mut socket,
                &mut cancellation.receiver,
                &stream.request_id,
                progress_deadline,
            )
            .await?;
            match frame.get("type").and_then(Value::as_str) {
                Some("cf_agent_stream_resuming") => {
                    if let Some(id) = frame.get("id").and_then(Value::as_str) {
                        send_json(
                            &mut socket,
                            &json!({
                                "type": "cf_agent_stream_resume_ack",
                                "id": id,
                            }),
                        )
                        .await?;
                    }
                }
                Some("cf_agent_chat_recovering") => {
                    let recovering = frame
                        .get("recovering")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    listener.on_recovering_changed(recovering);
                    adapter.recovering(recovering);
                }
                Some("cf_agent_use_chat_response") => {
                    if !stream.accept_frame(&frame) {
                        continue;
                    }
                    if frame.get("error").and_then(Value::as_bool) == Some(true) {
                        let detail = frame
                            .get("body")
                            .and_then(Value::as_str)
                            .filter(|value| !value.is_empty())
                            .unwrap_or("the hosted model returned an error");
                        return Err(HostedAgentError::Request {
                            detail: detail.to_string(),
                        });
                    }

                    if frame.get("done").and_then(Value::as_bool) == Some(true) {
                        if !stream.awaiting_continuation {
                            break;
                        }
                        continue;
                    }

                    let Some(chunk) = frame
                        .get("body")
                        .and_then(Value::as_str)
                        .filter(|body| !body.is_empty())
                        .and_then(|body| serde_json::from_str::<Value>(body).ok())
                    else {
                        continue;
                    };

                    // Recovery notifications, history snapshots and stale responses
                    // must not keep an otherwise stalled request alive forever.
                    if chunk_makes_progress(&chunk) {
                        progress_deadline = Instant::now() + FRAME_TIMEOUT;
                    }
                    if let Some(error) = stream_chunk_error(&chunk) {
                        return Err(error);
                    }
                    adapter.chunk(&chunk);
                    if chunk.get("type").and_then(Value::as_str) == Some("text-delta") {
                        if let Some(delta) = chunk.get("delta").and_then(Value::as_str) {
                            response_text.push_str(delta);
                            listener.on_response_delta(delta.to_string());
                        }
                    }

                    if let Some((tool_call_id, tool_name, input)) = tool_call(&chunk) {
                        if !handled_tool_calls.insert(tool_call_id.to_string()) {
                            continue;
                        }
                        let arguments_json =
                            serde_json::to_string(input).map_err(protocol_error)?;
                        adapter.tool_started(tool_call_id, tool_name, &arguments_json);
                        let result = tool_handler.execute_hosted_tool(HostedAgentToolInvocation {
                            session_id: session_id.clone(),
                            tool_call_id: tool_call_id.to_string(),
                            tool_name: tool_name.to_string(),
                            arguments_json: arguments_json.clone(),
                        });
                        adapter.tool_finished(
                            tool_call_id,
                            tool_name,
                            &arguments_json,
                            result.success,
                            result.error_message.as_deref(),
                        );
                        let output = serde_json::from_str::<Value>(&result.output)
                            .unwrap_or_else(|_| Value::String(result.output));
                        let state = if result.success {
                            "output-available"
                        } else {
                            "output-error"
                        };
                        send_json(
                            &mut socket,
                            &json!({
                                "type": "cf_agent_tool_result",
                                "toolCallId": tool_call_id,
                                "toolName": tool_name,
                                "output": output,
                                "state": state,
                                "errorText": result.error_message,
                                "autoContinue": true,
                                "clientTools": client_tools,
                            }),
                        )
                        .await?;
                        stream.awaiting_continuation = true;
                        // Platform tool execution can take time. The continuation
                        // gets its own full inactivity window after the result.
                        progress_deadline = Instant::now() + FRAME_TIMEOUT;
                    }
                }
                _ => {}
            }
        }

        let _ = socket.close(None).await;
        Ok(HostedAgentTurnResult {
            session_id,
            response_text,
        })
    }
}

/// A tool result starts a new response with a new request ID. Trailing chunks
/// from the tool's own response must not satisfy that continuation wait.
struct HostedStreamState {
    request_id: String,
    awaiting_continuation: bool,
    seen_request_ids: HashSet<String>,
}

impl HostedStreamState {
    fn new(request_id: String) -> Self {
        Self {
            seen_request_ids: HashSet::from([request_id.clone()]),
            request_id,
            awaiting_continuation: false,
        }
    }

    fn accept_frame(&mut self, frame: &Value) -> bool {
        let Some(id) = frame.get("id").and_then(Value::as_str) else {
            return false;
        };
        if id == self.request_id {
            return true;
        }
        if self.awaiting_continuation
            && !self.seen_request_ids.contains(id)
            && frame.get("continuation").and_then(Value::as_bool) == Some(true)
        {
            self.request_id = id.to_string();
            self.seen_request_ids.insert(id.to_string());
            self.awaiting_continuation = false;
            return true;
        }
        false
    }
}

fn stream_chunk_error(chunk: &Value) -> Option<HostedAgentError> {
    (chunk.get("type").and_then(Value::as_str) == Some("error")).then(|| {
        HostedAgentError::Request {
            detail: chunk
                .get("errorText")
                .and_then(Value::as_str)
                .filter(|text| !text.trim().is_empty())
                .unwrap_or("the hosted model returned an error")
                .to_string(),
        }
    })
}

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

#[derive(Default)]
struct HostedSessionActivity {
    active: bool,
    originating_device: bool,
    waiting_for_tools: bool,
    terminal_status: Option<String>,
}

impl HostedAgentClient {
    fn register_cancellation(&self, session_id: &str) -> CancellationRegistration {
        let token = Uuid::new_v4();
        let (sender, receiver) = watch::channel(false);
        let mut active = self
            .active_cancellations
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(previous) =
            active.insert(session_id.to_string(), ActiveCancellation { token, sender })
        {
            let _ = previous.sender.send(true);
        }
        CancellationRegistration {
            session_id: session_id.to_string(),
            token,
            receiver,
            active_cancellations: Arc::clone(&self.active_cancellations),
        }
    }

    async fn connect(
        &self,
        session_id: &str,
    ) -> Result<(Socket, Vec<Value>, HostedSessionActivity), HostedAgentError> {
        let access_token = self.session_access_token(session_id).await?;
        let url = websocket_url(&self.base_url, session_id)?;
        let mut request = url
            .as_str()
            .into_client_request()
            .map_err(connection_error)?;
        request.headers_mut().insert(
            AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {access_token}")).map_err(|error| {
                HostedAgentError::InvalidConfiguration {
                    detail: format!("invalid access token: {error}"),
                }
            })?,
        );
        let origin_id = self
            .origin_id
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        if let Some(origin_id) = origin_id {
            request.headers_mut().insert(
                "x-learnfold-origin-id",
                HeaderValue::from_str(&origin_id).map_err(protocol_error)?,
            );
        }
        let (mut socket, _) = tokio::time::timeout(CONNECT_TIMEOUT, connect_async(request))
            .await
            .map_err(|_| HostedAgentError::Connection {
                detail: "connection timed out".into(),
            })?
            .map_err(connection_error)?;

        let mut activity = HostedSessionActivity::default();
        loop {
            let frame = next_json(&mut socket).await?;
            match frame.get("type").and_then(Value::as_str) {
                Some("cf_agent_chat_messages") => {
                    let messages = frame
                        .get("messages")
                        .and_then(Value::as_array)
                        .cloned()
                        .unwrap_or_default();
                    return Ok((socket, messages, activity));
                }
                Some("learnfold_hosted_session_status") => {
                    activity.active = frame
                        .get("active")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    activity.originating_device = frame
                        .get("originatingDevice")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    activity.waiting_for_tools = frame
                        .get("waitingForTools")
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    activity.terminal_status = frame
                        .get("terminalStatus")
                        .and_then(Value::as_str)
                        .map(str::to_string);
                }
                Some("cf_agent_stream_resuming") => {
                    if let Some(id) = frame.get("id").and_then(Value::as_str) {
                        send_json(
                            &mut socket,
                            &json!({
                                "type": "cf_agent_stream_resume_ack",
                                "id": id,
                            }),
                        )
                        .await?;
                    }
                }
                _ => {}
            }
        }
    }

    async fn session_access_token(&self, session_id: &str) -> Result<String, HostedAgentError> {
        let Some(secret) = &self.guest_secret else {
            return Ok(self.access_token.clone());
        };
        let mut url = self
            .base_url
            .join("/guest-session")
            .map_err(connection_error)?;
        let scheme = if matches!(url.scheme(), "https" | "wss") {
            "https"
        } else {
            "http"
        };
        url.set_scheme(scheme)
            .map_err(|_| HostedAgentError::InvalidConfiguration {
                detail: "invalid guest service URL".into(),
            })?;
        url.query_pairs_mut().append_pair("sessionId", session_id);
        let response = reqwest::Client::builder()
            .timeout(CONNECT_TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(connection_error)?
            .post(url)
            .header("authorization", format!("Guest {secret}"))
            .send()
            .await
            .map_err(connection_error)?;
        if !response.status().is_success() {
            return Err(HostedAgentError::Request {
                detail: match response.status().as_u16() {
                    429 => {
                        "Hosted beta connection limit reached. Please try again tomorrow.".into()
                    }
                    503 => {
                        "Hosted guest access is temporarily unavailable. Please try again later."
                            .into()
                    }
                    _ => format!(
                        "Hosted guest connection failed ({}). Please try again.",
                        response.status()
                    ),
                },
            });
        }
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct GuestSession {
            access_token: String,
        }
        let session: GuestSession = response.json().await.map_err(protocol_error)?;
        if session.access_token.is_empty() {
            return Err(HostedAgentError::Protocol {
                detail: "guest service returned an empty token".into(),
            });
        }
        Ok(session.access_token)
    }
}

fn validated_base_url(raw: &str) -> Result<Url, HostedAgentError> {
    let url = Url::parse(raw.trim()).map_err(|error| HostedAgentError::InvalidConfiguration {
        detail: format!("invalid base URL: {error}"),
    })?;
    if !matches!(url.scheme(), "https" | "http" | "wss" | "ws") || url.host_str().is_none() {
        return Err(HostedAgentError::InvalidConfiguration {
            detail: "base URL must be an absolute HTTP(S) or WebSocket URL".into(),
        });
    }
    Ok(url)
}

fn validate_session_id(value: &str) -> Result<(), HostedAgentError> {
    Uuid::parse_str(value).map_err(|_| HostedAgentError::InvalidConfiguration {
        detail: "session ID must be a UUID".into(),
    })?;
    Ok(())
}

fn validate_workspace_id(value: &str) -> Result<(), HostedAgentError> {
    let valid = !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'));
    if !valid {
        return Err(HostedAgentError::InvalidConfiguration {
            detail: "workspace ID contains unsupported characters".into(),
        });
    }
    Ok(())
}

fn websocket_url(base_url: &Url, session_id: &str) -> Result<Url, HostedAgentError> {
    let mut url = base_url.clone();
    let scheme = match base_url.scheme() {
        "https" => "wss",
        "http" => "ws",
        "wss" => "wss",
        "ws" => "ws",
        _ => unreachable!("validated_base_url restricts schemes"),
    };
    url.set_scheme(scheme)
        .map_err(|_| HostedAgentError::InvalidConfiguration {
            detail: "could not convert base URL to WebSocket URL".into(),
        })?;
    let prefix = base_url.path().trim_matches('/');
    let path = if prefix.is_empty() {
        format!("/{AGENT_ROUTE}/{session_id}")
    } else {
        format!("/{prefix}/{AGENT_ROUTE}/{session_id}")
    };
    url.set_path(&path);
    url.set_query(None);
    url.set_fragment(None);
    Ok(url)
}

fn tool_schemas(definitions: &[HostedAgentToolDefinition]) -> Result<Value, HostedAgentError> {
    let mut total_bytes = 0usize;
    let mut names = HashSet::new();
    let mut schemas = Vec::with_capacity(definitions.len());
    for definition in definitions {
        if definition.name.is_empty() || !names.insert(definition.name.as_str()) {
            return Err(HostedAgentError::InvalidConfiguration {
                detail: format!("invalid or duplicate tool name: {}", definition.name),
            });
        }
        total_bytes = total_bytes.saturating_add(definition.parameters_json.len());
        if total_bytes > MAX_TOOL_SCHEMA_BYTES {
            return Err(HostedAgentError::InvalidConfiguration {
                detail: "client tool schemas exceed the size limit".into(),
            });
        }
        let parameters =
            serde_json::from_str::<Value>(&definition.parameters_json).map_err(|error| {
                HostedAgentError::InvalidConfiguration {
                    detail: format!("invalid schema for {}: {error}", definition.name),
                }
            })?;
        schemas.push(json!({
            "name": definition.name,
            "description": definition.description,
            "parameters": parameters,
        }));
    }
    Ok(Value::Array(schemas))
}

fn tool_call(chunk: &Value) -> Option<(&str, &str, &Value)> {
    if !matches!(
        chunk.get("type").and_then(Value::as_str),
        Some("tool-input-available" | "tool-call")
    ) {
        return None;
    }
    Some((
        chunk.get("toolCallId")?.as_str()?,
        chunk.get("toolName")?.as_str()?,
        chunk.get("input").unwrap_or(&Value::Null),
    ))
}

fn project_messages(messages: &[Value]) -> Vec<HostedAgentMessage> {
    messages
        .iter()
        .filter_map(|message| {
            let id = message.get("id")?.as_str()?.to_string();
            let role = message.get("role")?.as_str()?.to_string();
            let text = message
                .get("parts")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter(|part| part.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("");
            (!text.is_empty()).then_some(HostedAgentMessage { id, role, text })
        })
        .collect()
}

async fn send_json(socket: &mut Socket, value: &Value) -> Result<(), HostedAgentError> {
    socket
        .send(WsMessage::Text(value.to_string().into()))
        .await
        .map_err(connection_error)
}

async fn next_json(socket: &mut Socket) -> Result<Value, HostedAgentError> {
    tokio::time::timeout(FRAME_TIMEOUT, next_json_without_timeout(socket))
        .await
        .map_err(|_| HostedAgentError::Connection {
            detail: "the hosted agent stopped responding".into(),
        })?
}

async fn next_json_without_timeout(socket: &mut Socket) -> Result<Value, HostedAgentError> {
    loop {
        let frame = socket
            .next()
            .await
            .ok_or_else(|| HostedAgentError::Connection {
                detail: "the hosted agent closed the connection".into(),
            })?
            .map_err(connection_error)?;
        match frame {
            WsMessage::Text(text) => return serde_json::from_str(&text).map_err(protocol_error),
            WsMessage::Binary(bytes) => {
                return serde_json::from_slice(&bytes).map_err(protocol_error);
            }
            WsMessage::Ping(payload) => {
                socket
                    .send(WsMessage::Pong(payload))
                    .await
                    .map_err(connection_error)?;
            }
            WsMessage::Close(frame) => {
                return Err(HostedAgentError::Connection {
                    detail: frame
                        .map(|frame| frame.reason.to_string())
                        .filter(|reason| !reason.is_empty())
                        .unwrap_or_else(|| "the hosted agent closed the connection".into()),
                });
            }
            _ => {}
        }
    }
}

async fn next_json_or_cancel(
    socket: &mut Socket,
    cancellation: &mut watch::Receiver<bool>,
    request_id: &str,
    progress_deadline: Instant,
) -> Result<Value, HostedAgentError> {
    tokio::select! {
        // Prefer expiry even when the peer continuously sends irrelevant frames.
        biased;
        changed = cancellation.changed() => {
            if changed.is_ok() && *cancellation.borrow() {
                let _ = tokio::time::timeout(CONNECT_TIMEOUT, send_json(socket, &json!({
                    "type": "cf_agent_chat_request_cancel",
                    "id": request_id,
                }))).await;
            }
            Err(HostedAgentError::Cancelled)
        },
        _ = tokio::time::sleep_until(progress_deadline) => {
            let _ = tokio::time::timeout(CONNECT_TIMEOUT, send_json(socket, &json!({
                "type": "cf_agent_chat_request_cancel",
                "id": request_id,
            }))).await;
            Err(HostedAgentError::Connection {
                detail: "the hosted agent stopped responding".into(),
            })
        },
        result = next_json_without_timeout(socket) => result,
    }
}

fn chunk_makes_progress(chunk: &Value) -> bool {
    match chunk.get("type").and_then(Value::as_str) {
        Some("text-delta" | "reasoning-delta" | "tool-input-delta") => chunk
            .get("delta")
            .or_else(|| chunk.get("inputTextDelta"))
            .and_then(Value::as_str)
            .is_some_and(|delta| !delta.is_empty()),
        Some("tool-input-available" | "tool-call") => tool_call(chunk).is_some(),
        Some("data-hosted-provider-progress") => {
            chunk.get("transient").and_then(Value::as_bool) == Some(true)
                && chunk.pointer("/data/phase").and_then(Value::as_str) == Some("reasoning")
        }
        _ => false,
    }
}

fn connection_error(error: impl std::fmt::Display) -> HostedAgentError {
    HostedAgentError::Connection {
        detail: error.to_string(),
    }
}

fn protocol_error(error: impl std::fmt::Display) -> HostedAgentError {
    HostedAgentError::Protocol {
        detail: error.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_actual_response_content_extends_the_inactivity_window() {
        assert!(chunk_makes_progress(
            &json!({"type":"text-delta", "delta":"Hi"})
        ));
        assert!(chunk_makes_progress(
            &json!({"type":"tool-input-delta", "inputTextDelta":"{}"})
        ));
        assert!(chunk_makes_progress(&json!({
            "type":"data-hosted-provider-progress", "transient":true,
            "data":{"phase":"reasoning"}
        })));
        for chunk in [
            json!({"type":"data-hosted-provider-progress", "data":{"phase":"reasoning"}}),
            json!({"type":"data-hosted-provider-progress", "transient":true, "data":{"phase":"unknown"}}),
            json!({"type":"data-unrelated", "transient":true, "data":{"phase":"reasoning"}}),
            json!({"type":"text-delta", "delta":""}),
            json!({"type":"start"}),
            json!({"type":"finish-step"}),
            json!({"type":"cf_agent_chat_recovering", "recovering":true}),
        ] {
            assert!(!chunk_makes_progress(&chunk));
        }
    }

    #[tokio::test]
    async fn irrelevant_frames_cannot_extend_a_stalled_request() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
            loop {
                // Send a recovery notification after every frame the client reads.
                ws.send(WsMessage::Text(
                    json!({
                        "type":"cf_agent_chat_recovering", "recovering":true
                    })
                    .to_string()
                    .into(),
                ))
                .await
                .unwrap();
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_millis(5)) => {},
                    frame = ws.next() => {
                        let frame = frame.unwrap().unwrap();
                        let value: Value = serde_json::from_str(frame.to_text().unwrap()).unwrap();
                        assert_eq!(value["type"], "cf_agent_chat_request_cancel");
                        assert_eq!(value["id"], "stalled-request");
                        break;
                    }
                }
            }
        });
        let (mut socket, _) = connect_async(format!("ws://{address}")).await.unwrap();
        let (_sender, mut cancellation) = watch::channel(false);
        let deadline = Instant::now() + Duration::from_millis(50);
        let result = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                match next_json_or_cancel(
                    &mut socket,
                    &mut cancellation,
                    "stalled-request",
                    deadline,
                )
                .await
                {
                    Ok(_) => {}
                    Err(error) => break error,
                }
            }
        })
        .await
        .expect("background traffic must not postpone timeout");
        assert!(matches!(result, HostedAgentError::Connection { .. }));
        server.await.unwrap();
    }

    #[test]
    fn guest_identity_requires_a_secure_endpoint_and_random_secret() {
        assert!(HostedAgentClient::guest("https://agent.test".into(), "a".repeat(64)).is_ok());
        assert!(HostedAgentClient::guest("https://agent.test".into(), "short".into()).is_err());
        assert!(HostedAgentClient::guest("http://agent.test".into(), "a".repeat(64)).is_err());
    }

    #[tokio::test]
    async fn guest_exchange_binds_the_token_to_the_requested_session() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let session_id = Uuid::new_v4().to_string();
        let expected_session = session_id.clone();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = vec![0; 4096];
            let count = stream.read(&mut request).await.unwrap();
            let request = String::from_utf8_lossy(&request[..count]);
            assert!(request.contains(&format!("POST /guest-session?sessionId={expected_session}")));
            assert!(request.contains(&format!("authorization: Guest {}", "a".repeat(64))));
            let body = r#"{"accessToken":"session-token"}"#;
            stream.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
        });
        let client = HostedAgentClient::guest(format!("http://{address}"), "a".repeat(64)).unwrap();
        assert_eq!(
            client.session_access_token(&session_id).await.unwrap(),
            "session-token"
        );
        server.await.unwrap();
    }

    #[test]
    fn builds_canonical_think_websocket_route() {
        let base = validated_base_url("https://agent.learnfold.example/runtime").unwrap();
        let session = "123e4567-e89b-12d3-a456-426614174000";
        assert_eq!(
            websocket_url(&base, session).unwrap().as_str(),
            "wss://agent.learnfold.example/runtime/agents/hosted-course-agent/123e4567-e89b-12d3-a456-426614174000"
        );
    }

    #[test]
    fn serializes_client_tool_schemas_and_rejects_duplicates() {
        let definition = HostedAgentToolDefinition {
            name: "native-editor-fetch".into(),
            description: "Fetch a page".into(),
            parameters_json: r#"{"type":"object"}"#.into(),
        };
        let schemas = tool_schemas(std::slice::from_ref(&definition)).unwrap();
        assert_eq!(schemas[0]["parameters"]["type"], "object");
        assert!(tool_schemas(&[definition.clone(), definition]).is_err());
    }

    #[test]
    fn projects_text_without_treating_tool_output_as_chat_text() {
        let messages = vec![json!({
            "id": "assistant-1",
            "role": "assistant",
            "parts": [
                { "type": "text", "text": "Ready" },
                { "type": "tool-native-editor-fetch", "output": { "secret": true } }
            ]
        })];
        assert_eq!(
            project_messages(&messages),
            vec![HostedAgentMessage {
                id: "assistant-1".into(),
                role: "assistant".into(),
                text: "Ready".into(),
            }]
        );
    }

    #[test]
    fn parses_available_client_tool_calls() {
        let chunk = json!({
            "type": "tool-input-available",
            "toolCallId": "call-1",
            "toolName": "present_course_plan",
            "input": { "plan_id": "rust" }
        });
        let (id, name, input) = tool_call(&chunk).unwrap();
        assert_eq!(id, "call-1");
        assert_eq!(name, "present_course_plan");
        assert_eq!(input["plan_id"], "rust");
    }

    #[test]
    fn chained_tools_wait_for_a_new_continuation_request() {
        let mut stream = HostedStreamState::new("initial".into());
        stream.awaiting_continuation = true;
        assert!(stream.accept_frame(&json!({"id":"initial", "done":true})));
        assert!(stream.awaiting_continuation);
        assert!(stream.accept_frame(&json!({"id":"continuation-1", "continuation":true})));
        assert!(!stream.awaiting_continuation);
        // A second tool ran in continuation-1. Its trailing chunks and done
        // marker still belong to that response, not to continuation-2.
        stream.awaiting_continuation = true;
        assert!(stream.accept_frame(&json!({"id":"continuation-1", "continuation":true})));
        assert!(
            stream.accept_frame(&json!({"id":"continuation-1", "continuation":true, "done":true}))
        );
        assert!(stream.awaiting_continuation);
        assert!(stream.accept_frame(&json!({"id":"continuation-2", "continuation":true})));
        assert!(!stream.awaiting_continuation);
        assert_eq!(stream.request_id, "continuation-2");
    }

    #[test]
    fn stale_stream_frames_cannot_finish_or_fail_the_current_response() {
        let mut stream = HostedStreamState::new("current".into());
        assert!(!stream.accept_frame(&json!({"id":"old", "done":true})));
        assert!(!stream.accept_frame(&json!({"id":"old", "error":true, "continuation":true})));
        assert!(!stream.accept_frame(&json!({"done":true})));
        assert!(stream.accept_frame(&json!({"id":"current", "done":true})));
    }

    #[test]
    fn model_error_chunks_are_failures_even_without_an_outer_error_flag() {
        let error =
            stream_chunk_error(&json!({"type":"error", "errorText":"Model unavailable"})).unwrap();
        assert!(error.to_string().contains("Model unavailable"));
        assert!(stream_chunk_error(&json!({"type":"error"})).is_some());
        assert!(stream_chunk_error(&json!({"type":"text-delta", "delta":"Hello"})).is_none());
    }

    struct TestToolHandler;
    impl HostedAgentToolHandler for TestToolHandler {
        fn execute_hosted_tool(&self, _: HostedAgentToolInvocation) -> HostedAgentToolResult {
            HostedAgentToolResult {
                success: true,
                output: "{}".into(),
                error_message: None,
            }
        }
    }
    struct TestListener;
    impl HostedAgentEventListener for TestListener {
        fn on_response_delta(&self, _: String) {}
        fn on_recovering_changed(&self, _: bool) {}
    }

    #[tokio::test]
    async fn observing_an_active_turn_never_submits_a_duplicate_or_executes_replayed_tools() {
        let server = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = server.local_addr().unwrap();
        let task = tokio::spawn(async move {
            let (tcp, _) = server.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
            for frame in [
                json!({"type":"learnfold_hosted_session_status", "active":true, "originatingDevice":false, "waitingForTools":true}),
                json!({"type":"cf_agent_chat_messages", "messages":[{"id":"original", "role":"user", "parts":[{"type":"text", "text":"Generate the lesson"}]}]}),
                json!({"type":"cf_agent_stream_resuming", "id":"origin-request"}),
            ] {
                let _ = ws.send(WsMessage::Text(frame.to_string().into())).await;
            }
            while let Some(frame) = ws.next().await {
                match frame.unwrap() {
                    WsMessage::Close(_) => break,
                    WsMessage::Text(text) => {
                        panic!("observer must neither submit nor execute replay: {text}")
                    }
                    _ => {}
                }
            }
        });
        let client =
            HostedAgentClient::new(format!("http://{address}"), "test-token".into()).unwrap();
        let result = client
            .send(
                Uuid::new_v4().to_string(),
                "course-a".into(),
                "Continue".into(),
                Some("duplicate".into()),
                vec![],
                Box::new(TestToolHandler),
                Box::new(TestListener),
            )
            .await;
        assert!(result.unwrap_err().to_string().contains("original device"));
        task.await.unwrap();
    }

    #[tokio::test]
    async fn active_history_load_is_read_only_and_retains_saved_assistant_text() {
        let server = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = server.local_addr().unwrap();
        let task = tokio::spawn(async move {
            let (tcp, _) = server.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
            ws.send(WsMessage::Text(json!({"type":"learnfold_hosted_session_status", "active":true, "waitingForTools":true}).to_string().into())).await.unwrap();
            ws.send(WsMessage::Text(json!({"type":"cf_agent_chat_messages", "messages":[
                {"id":"user-1", "role":"user", "parts":[{"type":"text", "text":"Explain the lesson"}]},
                {"id":"assistant-1", "role":"assistant", "parts":[{"type":"text", "text":"Your saved answer"}, {"type":"tool-native-editor-fetch", "state":"output-available", "output":{}}]},
            ]}).to_string().into())).await.unwrap();
            assert!(matches!(
                ws.next().await.unwrap().unwrap(),
                WsMessage::Close(_)
            ));
        });
        let client =
            HostedAgentClient::new(format!("http://{address}"), "test-token".into()).unwrap();
        let messages = client
            .load_messages(Uuid::new_v4().to_string())
            .await
            .unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[1].text, "Your saved answer");
        task.await.unwrap();
    }

    #[tokio::test]
    async fn interrupted_recovery_requires_original_device_and_a_page_refresh_receipt() {
        for originating_device in [false, true] {
            let server = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = server.local_addr().unwrap();
            let task = tokio::spawn(async move {
                let (tcp, _) = server.accept().await.unwrap();
                let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
                ws.send(WsMessage::Text(json!({"type":"learnfold_hosted_session_status", "active":true, "originatingDevice":originating_device, "waitingForTools":true}).to_string().into())).await.unwrap();
                ws.send(WsMessage::Text(
                    json!({"type":"cf_agent_chat_messages", "messages":[]})
                        .to_string()
                        .into(),
                ))
                .await
                .unwrap();
                let frame = ws.next().await.unwrap().unwrap();
                if originating_device {
                    let request: Value = serde_json::from_str(frame.to_text().unwrap()).unwrap();
                    assert_eq!(request["type"], "learnfold_hosted_recover_interrupted");
                    assert_eq!(request["workspaceId"], "course-a");
                    assert_eq!(request["refreshedPagesReceipt"], "a".repeat(64));
                    ws.send(WsMessage::Text(json!({"type":"learnfold_hosted_recovery_result", "id":request["id"], "success":true}).to_string().into())).await.unwrap();
                } else {
                    assert!(matches!(frame, WsMessage::Close(_)));
                }
            });
            let client =
                HostedAgentClient::new(format!("http://{address}"), "test-token".into()).unwrap();
            let result = client
                .recover_interrupted_session(
                    Uuid::new_v4().to_string(),
                    "course-a".into(),
                    "a".repeat(64),
                )
                .await;
            if originating_device {
                assert!(result.unwrap());
            } else {
                assert!(result.unwrap_err().to_string().contains("original device"));
            }
            task.await.unwrap();
        }
    }

    #[tokio::test]
    async fn websocket_turn_waits_through_two_tools_and_surfaces_stream_errors() {
        for fails in [false, true] {
            let server = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = server.local_addr().unwrap();
            let task = tokio::spawn(async move {
                let (tcp, _) = server.accept().await.unwrap();
                let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
                ws.send(WsMessage::Text(
                    json!({"type":"cf_agent_chat_messages", "messages":[]})
                        .to_string()
                        .into(),
                ))
                .await
                .unwrap();
                let request: Value =
                    serde_json::from_str(ws.next().await.unwrap().unwrap().to_text().unwrap())
                        .unwrap();
                let initial = request["id"].as_str().unwrap().to_string();
                // The learner message keeps the platform's optimistic id.
                let body: Value =
                    serde_json::from_str(request["init"]["body"].as_str().unwrap()).unwrap();
                assert_eq!(body["messages"][0]["id"], "client-message-1");
                for (index, id) in [initial.as_str(), "continuation-1"].iter().enumerate() {
                    let chunk = json!({"type":"tool-input-available", "toolCallId":format!("call-{index}"), "toolName":"native-editor-fetch", "input":{}});
                    ws.send(WsMessage::Text(json!({"type":"cf_agent_use_chat_response", "id":id, "continuation":index > 0, "body":chunk.to_string()}).to_string().into())).await.unwrap();
                    let result: Value =
                        serde_json::from_str(ws.next().await.unwrap().unwrap().to_text().unwrap())
                            .unwrap();
                    assert_eq!(result["type"], "cf_agent_tool_result");
                    assert_eq!(result["toolCallId"], format!("call-{index}"));
                    // These trailing frames belong to the response that called
                    // the tool, even though continuation=true for the second.
                    let trailing = json!({"type":"finish-step"});
                    ws.send(WsMessage::Text(json!({"type":"cf_agent_use_chat_response", "id":id, "continuation":index > 0, "body":trailing.to_string()}).to_string().into())).await.unwrap();
                    ws.send(WsMessage::Text(json!({"type":"cf_agent_use_chat_response", "id":id, "continuation":index > 0, "done":true}).to_string().into())).await.unwrap();
                }
                let chunk = if fails {
                    json!({"type":"error", "errorText":"Model unavailable"})
                } else {
                    json!({"type":"text-delta", "delta":"Final answer after both tools"})
                };
                ws.send(WsMessage::Text(json!({"type":"cf_agent_use_chat_response", "id":"continuation-2", "continuation":true, "body":chunk.to_string()}).to_string().into())).await.unwrap();
                let _ = ws.send(WsMessage::Text(json!({"type":"cf_agent_use_chat_response", "id":"continuation-2", "continuation":true, "done":true}).to_string().into())).await;
            });
            let client =
                HostedAgentClient::new(format!("http://{address}"), "test-token".into()).unwrap();
            let result = tokio::time::timeout(
                Duration::from_secs(5),
                client.send(
                    Uuid::new_v4().to_string(),
                    "course-a".into(),
                    "Read the lesson".into(),
                    Some("client-message-1".into()),
                    vec![],
                    Box::new(TestToolHandler),
                    Box::new(TestListener),
                ),
            )
            .await
            .expect("turn stalled");
            if fails {
                assert!(
                    result
                        .unwrap_err()
                        .to_string()
                        .contains("Model unavailable")
                );
            } else {
                assert_eq!(
                    result.unwrap().response_text,
                    "Final answer after both tools"
                );
            }
            task.await.unwrap();
        }
    }

    #[test]
    fn cancellation_is_scoped_to_the_active_session() {
        let client = HostedAgentClient::new(
            "https://agent.learnfold.example".into(),
            "test-access-token".into(),
        )
        .unwrap();
        let session = "123e4567-e89b-12d3-a456-426614174000";
        let registration = client.register_cancellation(session);

        assert!(!*registration.receiver.borrow());
        assert!(client.cancel(session.into()).unwrap());
        assert!(*registration.receiver.borrow());

        drop(registration);
        assert!(!client.cancel(session.into()).unwrap());
    }
}
