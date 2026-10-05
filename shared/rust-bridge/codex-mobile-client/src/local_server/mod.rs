//! Attach to or spawn a local `codex app-server` process on the host Mac.
//!
//! Used by the direct-dist (non-sandboxed) Mac Catalyst lane to provide a
//! first-class "Local Mac" server without requiring the user to run a
//! terminal command. Not used on the App Store Mac lane (sandboxed) or iOS.
//!
//! Flow per `attach_or_spawn`:
//!   1. Verify the Codex initialize handshake on `127.0.0.1:{port}`. If a
//!      compatible app-server is listening, attach to it and do not spawn.
//!   2. Resolve a `codex` binary from the same candidate paths the SSH
//!      bootstrap would probe remotely.
//!   3. If not found, fail with a clear "install Codex" error.
//!   4. Spawn `codex app-server --listen ws://127.0.0.1:{port}` and poll
//!      the WebSocket up to 20 × 250 ms for readiness.
//!
//! The returned `LocalServerHandle` keeps the child alive; dropping it or
//! calling `stop()` terminates the process.

use std::collections::HashSet;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use serde_json::json;
use tokio::net::TcpStream;
use tokio::process::{Child, Command};
use tokio::time::sleep;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tracing::{debug, info, warn};

/// How long to wait for a single connect attempt before considering nothing
/// is listening. Matches the "quick attach check" semantics in the plan.
const PROBE_CONNECT_TIMEOUT: Duration = Duration::from_millis(150);
const PROBE_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(2);
const BINARY_VERSION_TIMEOUT: Duration = Duration::from_secs(2);

/// Max number of readiness poll iterations after spawn. 20 × 250 ms == 5 s.
const READINESS_MAX_ATTEMPTS: u32 = 20;
const READINESS_POLL_INTERVAL: Duration = Duration::from_millis(250);

/// POSIX candidate lines shared with Alleycat's Codex resolver.
pub(crate) const fn shell_candidate_lines() -> &'static [&'static str] {
    alleycat_bridge_core::codex_resolver::POSIX_SHELL_CANDIDATE_LINES
}

// ---------------------------------------------------------------------------
// Probe + resolve
// ---------------------------------------------------------------------------

/// Verify that a listener speaks Codex app-server's initialize protocol.
/// An arbitrary TCP or WebSocket listener is not a valid local Codex.
pub async fn probe_local_server(port: u16) -> bool {
    tokio::time::timeout(PROBE_HANDSHAKE_TIMEOUT, async {
        let (mut socket, _) = connect_async(format!("ws://127.0.0.1:{port}")).await.ok()?;
        socket
            .send(Message::Text(
                json!({
                    "id": "learnfold-local-probe",
                    "method": "initialize",
                    "params": {
                        "clientInfo": {
                            "name": "learnfold_local_probe",
                            "title": "Learnfold",
                            "version": env!("CARGO_PKG_VERSION")
                        },
                        "capabilities": {"experimentalApi": true}
                    }
                })
                .to_string()
                .into(),
            ))
            .await
            .ok()?;
        while let Some(message) = socket.next().await {
            let message = message.ok()?;
            let Message::Text(text) = message else {
                continue;
            };
            let value: serde_json::Value = serde_json::from_str(&text).ok()?;
            if value.get("id") != Some(&json!("learnfold-local-probe")) {
                continue;
            }
            let valid = value.get("error").is_none()
                && value
                    .pointer("/result/userAgent")
                    .and_then(|value| value.as_str())
                    .is_some_and(|agent| !agent.is_empty())
                && value
                    .pointer("/result/codexHome")
                    .and_then(|value| value.as_str())
                    .is_some_and(|home| Path::new(home).is_absolute());
            let _ = socket.close(None).await;
            return Some(valid);
        }
        None
    })
    .await
    .ok()
    .flatten()
    .unwrap_or(false)
}

/// Find installed Codex without relying on Finder inheriting a login-shell
/// PATH. NVM's versioned bins also need their sibling `node` on the child PATH.
pub async fn resolve_codex_binary_local() -> Option<PathBuf> {
    let mut candidates =
        alleycat_bridge_core::codex_resolver::program_candidates(Path::new("codex"));
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        let nvm_dir = std::env::var_os("NVM_DIR")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".nvm"));
        candidates.extend(nvm_codex_candidates(&nvm_dir));
        // Catalyst's Rust target is iOS, so the shared resolver's macOS
        // cfg does not include these app-bundled candidates.
        candidates.push(home.join("Applications/Codex.app/Contents/Resources/codex"));
        candidates.push(PathBuf::from(
            "/Applications/Codex.app/Contents/Resources/codex",
        ));
    }
    resolve_codex_candidates(candidates).await
}

async fn resolve_codex_candidates(candidates: Vec<PathBuf>) -> Option<PathBuf> {
    let mut seen = HashSet::new();
    let mut best = None;
    for candidate in candidates {
        if !is_executable_file(&candidate) || !seen.insert(candidate.clone()) {
            continue;
        }
        let output = tokio::time::timeout(
            BINARY_VERSION_TIMEOUT,
            Command::new(&candidate)
                .arg("--version")
                .env("PATH", codex_child_path(&candidate))
                .stdin(Stdio::null())
                .kill_on_drop(true)
                .output(),
        )
        .await;
        let Ok(Ok(output)) = output else { continue };
        if !output.status.success() {
            continue;
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let Some(version) = alleycat_bridge_core::codex_resolver::parse_codex_cli_version(&text)
        else {
            continue;
        };
        if best
            .as_ref()
            .is_none_or(|(previous, _)| version > *previous)
        {
            best = Some((version, candidate));
        }
    }
    best.map(|(_, path)| path)
}

fn nvm_codex_candidates(nvm_dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(nvm_dir.join("versions/node")) else {
        return Vec::new();
    };
    let mut candidates = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path().join("bin/codex"))
        .filter(|path| is_executable_file(path))
        .collect::<Vec<_>>();
    candidates.sort();
    candidates
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn codex_child_path(codex_path: &Path) -> OsString {
    let mut paths = Vec::new();
    if let Some(parent) = codex_path.parent() {
        paths.push(parent.to_path_buf());
    }
    if let Some(path) = std::env::var_os("PATH") {
        paths.extend(std::env::split_paths(&path));
    }
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        paths.extend(
            [".local/bin", ".cargo/bin", ".volta/bin", ".bun/bin"].map(|path| home.join(path)),
        );
    }
    paths.extend(
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        .map(PathBuf::from),
    );
    let mut seen = HashSet::new();
    paths.retain(|path| seen.insert(path.clone()));
    std::env::join_paths(paths).unwrap_or_else(|_| {
        codex_path
            .parent()
            .unwrap_or(Path::new("/usr/bin"))
            .as_os_str()
            .to_os_string()
    })
}

// ---------------------------------------------------------------------------
// Spawn
// ---------------------------------------------------------------------------

/// Errors produced by the local-server bootstrap flow.
#[derive(Debug, thiserror::Error)]
pub enum LocalServerError {
    #[error(
        "codex binary not found locally; install the Codex CLI and make `codex` available on PATH"
    )]
    BinaryNotFound,
    #[error("failed to spawn codex app-server: {0}")]
    Spawn(String),
    #[error(
        "127.0.0.1:{port} is occupied by a listener that does not speak compatible Codex app-server; choose another port or stop that listener"
    )]
    EndpointOccupied { port: u16 },
    #[error("codex app-server exited before becoming ready: {0}")]
    ProcessExited(String),
    #[error(
        "codex app-server did not become ready on 127.0.0.1:{port} within {timeout_ms}ms: {reason}"
    )]
    ReadinessTimeout {
        port: u16,
        timeout_ms: u64,
        reason: String,
    },
}

/// Handle to a spawned `codex app-server` process. Drop (or `stop()`) kills
/// the child so we never leak the process when the app quits.
pub struct LocalServerHandle {
    child: Option<Child>,
    port: u16,
    codex_path: PathBuf,
}

impl LocalServerHandle {
    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn codex_path(&self) -> &Path {
        &self.codex_path
    }

    /// Gracefully terminate the child. First sends SIGTERM; if the process
    /// doesn't exit within a short grace period, the `Child` is dropped
    /// (which kills on Unix via tokio's `kill_on_drop`).
    pub async fn stop(mut self) {
        self.stop_internal().await;
    }

    async fn stop_internal(&mut self) {
        let Some(mut child) = self.child.take() else {
            return;
        };

        #[cfg(unix)]
        {
            if let Some(id) = child.id() {
                // Best-effort SIGTERM first; ignore errors.
                let _ = nix_sigterm(id as i32);
            }
        }

        // Give codex up to 2s to exit cleanly.
        let wait_result = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;

        match wait_result {
            Ok(Ok(status)) => {
                debug!("local codex exited status={:?}", status);
            }
            Ok(Err(err)) => {
                warn!("local codex wait failed: {err}");
            }
            Err(_) => {
                warn!("local codex did not exit within grace period, killing");
                let _ = child.kill().await;
                let _ = child.wait().await;
            }
        }
    }
}

impl Drop for LocalServerHandle {
    fn drop(&mut self) {
        let Some(mut child) = self.child.take() else {
            return;
        };
        #[cfg(unix)]
        if let Some(id) = child.id() {
            let _ = nix_sigterm(id as i32);
        }
        // `kill_on_drop(true)` below ensures the child will be killed if
        // SIGTERM didn't take effect before the runtime goes away.
        let _ = child.start_kill();
    }
}

#[cfg(unix)]
fn nix_sigterm(pid: i32) -> std::io::Result<()> {
    // SIGTERM = 15. Avoid pulling in nix/libc crates just for this.
    // SAFETY: FFI to libc kill with a valid signal number and a pid we
    // produced; no memory involved.
    let rc = unsafe { raw_kill(pid, 15) };
    if rc == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(unix)]
unsafe extern "C" {
    #[link_name = "kill"]
    fn raw_kill(pid: i32, sig: i32) -> i32;
}

/// Attach to a compatible app-server, or spawn one if nothing is listening.
/// Returns a handle describing the connection and,
/// when we spawned, a process to keep alive.
pub async fn attach_or_spawn_local_server(
    port: u16,
    codex_home: Option<PathBuf>,
) -> Result<LocalServerAttach, LocalServerError> {
    if probe_local_server(port).await {
        info!("attaching to existing local codex on 127.0.0.1:{}", port);
        return Ok(LocalServerAttach {
            port,
            handle: None,
            attached_to_existing: true,
            codex_path: None,
        });
    }

    if matches!(
        tokio::time::timeout(
            PROBE_CONNECT_TIMEOUT,
            TcpStream::connect(("127.0.0.1", port))
        )
        .await,
        Ok(Ok(_))
    ) {
        return Err(LocalServerError::EndpointOccupied { port });
    }

    info!(
        "no existing codex on 127.0.0.1:{}; attempting to spawn",
        port
    );

    let codex_path = resolve_codex_binary_local()
        .await
        .ok_or(LocalServerError::BinaryNotFound)?;

    let mut handle = spawn_local_server(port, &codex_path, codex_home.as_deref()).await?;

    match wait_for_local_server_ready(port, &mut handle).await {
        Ok(()) => Ok(LocalServerAttach {
            port,
            handle: Some(handle),
            attached_to_existing: false,
            codex_path: Some(codex_path),
        }),
        Err(err) => {
            // Drop the handle so we don't leak the half-started child.
            drop(handle);
            Err(err)
        }
    }
}

async fn spawn_local_server(
    port: u16,
    codex_path: &Path,
    codex_home: Option<&Path>,
) -> Result<LocalServerHandle, LocalServerError> {
    let listen_url = format!("ws://127.0.0.1:{port}");
    let mut cmd = Command::new(codex_path);
    cmd.arg("app-server")
        .arg("--listen")
        .arg(&listen_url)
        .stdin(Stdio::null())
        // Route stdout/stderr to the parent process so `codex` logs appear
        // alongside the app's own logs (Console.app on Mac).
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .env("PATH", codex_child_path(codex_path))
        .kill_on_drop(true);

    if let Some(home) = codex_home {
        cmd.env("CODEX_HOME", home);
    }

    let child = cmd
        .spawn()
        .map_err(|err| LocalServerError::Spawn(err.to_string()))?;

    info!(
        "spawned local codex pid={:?} path={:?} listen={}",
        child.id(),
        codex_path,
        listen_url
    );

    Ok(LocalServerHandle {
        child: Some(child),
        port,
        codex_path: codex_path.to_path_buf(),
    })
}

async fn wait_for_local_server_ready(
    port: u16,
    handle: &mut LocalServerHandle,
) -> Result<(), LocalServerError> {
    let timeout = READINESS_POLL_INTERVAL * READINESS_MAX_ATTEMPTS;
    let deadline = tokio::time::Instant::now() + timeout;

    for attempt in 0..READINESS_MAX_ATTEMPTS {
        if let Some(child) = handle.child.as_mut() {
            if let Some(status) = child
                .try_wait()
                .map_err(|error| LocalServerError::Spawn(error.to_string()))?
            {
                return Err(LocalServerError::ProcessExited(status.to_string()));
            }
        }
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, probe_local_server(port)).await {
            Ok(true) => {
                debug!(
                    "local codex ready on 127.0.0.1:{} after attempt {}",
                    port,
                    attempt + 1
                );
                return Ok(());
            }
            _ => {
                if attempt == 0 || attempt + 1 == READINESS_MAX_ATTEMPTS {
                    debug!(
                        "local codex readiness attempt {} failed: {}",
                        attempt + 1,
                        "initialize handshake not ready"
                    );
                }
            }
        }
        sleep(
            READINESS_POLL_INTERVAL
                .min(deadline.saturating_duration_since(tokio::time::Instant::now())),
        )
        .await;
    }

    Err(LocalServerError::ReadinessTimeout {
        port,
        timeout_ms: timeout.as_millis() as u64,
        reason: "compatible initialize handshake was not received; check Codex installation and Console logs".to_string(),
    })
}

// ---------------------------------------------------------------------------
// Attach result
// ---------------------------------------------------------------------------

/// Outcome of `attach_or_spawn_local_server`.
///
/// `handle` is `Some` when this invocation started the child; `None` when
/// we attached to a codex that was already listening (user ran it in a
/// terminal).
pub struct LocalServerAttach {
    pub port: u16,
    pub handle: Option<LocalServerHandle>,
    pub attached_to_existing: bool,
    pub codex_path: Option<PathBuf>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_candidate_lines_has_matching_entries() {
        let shell = shell_candidate_lines().join("\n");
        assert!(shell.contains("_litter_consider_path_candidates codex codex"));
        assert!(shell.contains("packages/standalone/current/codex"));
        assert!(!shell.contains(".litter/bin/codex"));
        assert!(!shell.contains(".litter/codex/node_modules/.bin/codex"));
        assert!(shell.contains(".local/bin/codex"));
        assert!(shell.contains("/opt/homebrew/bin/codex"));
        assert!(shell.contains("/usr/local/bin/codex"));
        assert!(shell.contains("/usr/bin/codex"));
    }

    #[tokio::test]
    async fn probe_returns_false_for_unused_port() {
        // Pick a high port unlikely to be in use in CI. If a flake
        // happens, bump this to a different port.
        assert!(!probe_local_server(1).await);
    }

    #[tokio::test]
    async fn bootstrap_rejects_an_unrelated_tcp_listener() {
        use tokio::io::AsyncWriteExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            loop {
                let (mut stream, _) = listener.accept().await.unwrap();
                let _ = stream
                    .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
                    .await;
            }
        });
        let result = attach_or_spawn_local_server(port, None).await;
        assert!(
            matches!(result, Err(LocalServerError::EndpointOccupied { port: occupied }) if occupied == port)
        );
        server.abort();
    }

    #[tokio::test]
    async fn bootstrap_attaches_only_after_a_codex_initialize_response() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            let request = socket.next().await.unwrap().unwrap().into_text().unwrap();
            let request: serde_json::Value = serde_json::from_str(&request).unwrap();
            assert_eq!(request["method"], "initialize");
            socket.send(Message::Text(json!({
                "id": request["id"],
                "result": {"userAgent": "codex-cli/0.160.0", "codexHome": "/tmp/test-codex-home"}
            }).to_string().into())).await.unwrap();
            let _ = socket.next().await;
        });
        let connection = attach_or_spawn_local_server(port, None).await.unwrap();
        assert!(connection.attached_to_existing);
        assert!(connection.handle.is_none());
        assert_eq!(connection.port, port);
        server.await.unwrap();
    }

    #[tokio::test]
    async fn probe_rejects_a_websocket_without_codex_initialize_fields() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
            let request = socket.next().await.unwrap().unwrap().into_text().unwrap();
            let request: serde_json::Value = serde_json::from_str(&request).unwrap();
            socket
                .send(Message::Text(
                    json!({"id": request["id"], "result": {}})
                        .to_string()
                        .into(),
                ))
                .await
                .unwrap();
            let _ = socket.next().await;
        });
        assert!(!probe_local_server(port).await);
        server.await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn nvm_codex_resolves_with_its_sibling_node_on_path() {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        let nvm_dir = directory.path().join(".nvm");
        let bin = nvm_dir.join("versions/node/v22.18.0/bin");
        std::fs::create_dir_all(&bin).unwrap();
        let codex = bin.join("codex");
        let node = bin.join("node");
        std::fs::write(&codex, "#!/usr/bin/env node\n").unwrap();
        std::fs::write(&node, "#!/bin/sh\nprintf 'codex-cli 0.160.0\\n'\n").unwrap();
        for executable in [&codex, &node] {
            std::fs::set_permissions(executable, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let candidates = nvm_codex_candidates(&nvm_dir);
        assert_eq!(candidates, vec![codex.clone()]);
        let paths = std::env::split_paths(&codex_child_path(&codex)).collect::<Vec<_>>();
        assert_eq!(paths.first(), Some(&bin));
        assert_eq!(resolve_codex_candidates(candidates).await, Some(codex));
    }
}
