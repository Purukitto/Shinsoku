//! Loopback HTTP capture endpoint. Browser extensions POST intercepted
//! downloads here; we hand them to the engine with the browser's
//! cookies/referrer/UA so logged-in / referrer-gated downloads work.
//!
//! Security: bound to 127.0.0.1 only, every request must carry the shared
//! `X-Shinsoku-Token`, and no permissive CORS headers are emitted — a web page
//! can't send the custom token header cross-origin (preflight fails), while an
//! extension holding `127.0.0.1` host permission bypasses CORS.

use std::io;
use std::net::{Ipv4Addr, TcpListener as StdListener};
use std::sync::atomic::{AtomicI64, AtomicU32, Ordering};
use std::sync::Arc;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

use crate::engine::download::DownloadKind;
use crate::engine::retry::describe;
use crate::queue::manager::QueueManager;

const TOKEN_HEADER: &str = "x-shinsoku-token";
/// Cap on segments for captured downloads; `add` clamps to the engine's
/// configured maximum, so this just means "use the user's max".
const CAPTURE_CONNECTIONS: u8 = 32;

#[derive(Clone)]
struct AppState {
    manager: QueueManager,
    token: Arc<String>,
    dest_dir: Arc<String>,
    stats: Arc<CaptureStats>,
}

/// Activity the app surfaces so the UI can show a real "browser connected"
/// state rather than just "server listening".
#[derive(Default)]
struct CaptureStats {
    last_seen_ms: AtomicI64,
    captures: AtomicU32,
}

impl CaptureStats {
    fn touch(&self) {
        self.last_seen_ms
            .store(chrono::Utc::now().timestamp_millis(), Ordering::Relaxed);
    }

    fn record_capture(&self) {
        self.captures.fetch_add(1, Ordering::Relaxed);
    }

    fn snapshot(&self) -> (i64, u32) {
        (
            self.last_seen_ms.load(Ordering::Relaxed),
            self.captures.load(Ordering::Relaxed),
        )
    }
}

/// Browser-supplied download. Unknown fields (mime/size/filename) are ignored;
/// the engine derives filename/type from the probe.
#[derive(Deserialize)]
struct AddReq {
    url: String,
    referrer: Option<String>,
    cookie: Option<String>,
    user_agent: Option<String>,
    /// Optional digest (SHA-256/MD5 hex) the extension may attach; verified on
    /// completion. Most pages don't expose one, so this is usually absent.
    checksum: Option<String>,
}

/// Browser-detected HLS stream (toolbar popup). The engine fetches the playlist
/// and downloads it; only the request headers matter here.
#[derive(Deserialize)]
struct AddStreamReq {
    url: String,
    title: Option<String>,
    referrer: Option<String>,
    cookie: Option<String>,
    user_agent: Option<String>,
}

#[derive(Serialize)]
struct AddResp {
    id: String,
    /// The link went to a stopped download waiting for a fresh one.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    refreshed: bool,
}

/// 409 body when a download waiting for a fresh link refuses the one sent.
#[derive(Serialize)]
struct ErrResp {
    error: String,
}

#[derive(Serialize)]
struct Ping {
    app: &'static str,
    version: &'static str,
}

/// Running server; dropping/stopping cancels the graceful-shutdown future.
pub struct CaptureHandle {
    cancel: CancellationToken,
    pub port: u16,
    stats: Arc<CaptureStats>,
}

impl CaptureHandle {
    pub fn stop(&self) {
        self.cancel.cancel();
    }

    /// (last authenticated-request epoch ms, total captures). last_seen is 0
    /// until a browser first talks to us this session.
    pub fn stats(&self) -> (i64, u32) {
        self.stats.snapshot()
    }
}

impl Drop for CaptureHandle {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

/// Bind on 127.0.0.1 (starting at `port`, trying a few above if taken) and serve
/// on the engine's runtime. Returns a handle carrying the actually-bound port.
pub fn start(
    manager: QueueManager,
    dest_dir: String,
    port: u16,
    token: String,
) -> io::Result<CaptureHandle> {
    let std_listener = bind_std(port)?;
    let bound = std_listener.local_addr()?.port();
    std_listener.set_nonblocking(true)?;

    let stats = Arc::new(CaptureStats::default());
    let state = AppState {
        manager: manager.clone(),
        token: Arc::new(token),
        dest_dir: Arc::new(dest_dir),
        stats: stats.clone(),
    };
    let app = Router::new()
        .route("/api/ping", get(ping))
        .route("/api/add", post(add))
        .route("/api/add-stream", post(add_stream))
        .with_state(state);

    let cancel = CancellationToken::new();
    let child = cancel.clone();
    manager.runtime().spawn(async move {
        let listener = match TcpListener::from_std(std_listener) {
            Ok(l) => l,
            Err(_) => return,
        };
        let _ = axum::serve(listener, app)
            .with_graceful_shutdown(async move { child.cancelled().await })
            .await;
    });

    Ok(CaptureHandle {
        cancel,
        port: bound,
        stats,
    })
}

fn bind_std(start: u16) -> io::Result<StdListener> {
    if start == 0 {
        return StdListener::bind((Ipv4Addr::LOCALHOST, 0));
    }
    let mut last = None;
    for p in start..start.saturating_add(16) {
        match StdListener::bind((Ipv4Addr::LOCALHOST, p)) {
            Ok(l) => return Ok(l),
            Err(e) => last = Some(e),
        }
    }
    Err(last.unwrap_or_else(|| io::Error::new(io::ErrorKind::AddrInUse, "no free port")))
}

fn check_token(state: &AppState, headers: &HeaderMap) -> Result<(), StatusCode> {
    let ok = headers
        .get(TOKEN_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(|v| v == state.token.as_str())
        .unwrap_or(false);
    if ok {
        state.stats.touch();
        Ok(())
    } else {
        Err(StatusCode::UNAUTHORIZED)
    }
}

async fn ping(State(state): State<AppState>, headers: HeaderMap) -> Result<Json<Ping>, StatusCode> {
    check_token(&state, &headers)?;
    Ok(Json(Ping {
        app: "shinsoku",
        version: env!("CARGO_PKG_VERSION"),
    }))
}

async fn add(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<AddReq>,
) -> Result<Response, StatusCode> {
    check_token(&state, &headers)?;
    if !(req.url.starts_with("http://") || req.url.starts_with("https://")) {
        return Err(StatusCode::BAD_REQUEST);
    }

    let hdrs = capture_headers(req.cookie, req.referrer, req.user_agent);
    if let Some(r) = state
        .manager
        .take_captured_link(req.url.clone(), hdrs.clone(), DownloadKind::Http)
        .await
    {
        return Ok(refreshed(&state, r));
    }
    let conns = state.manager.default_connections().min(CAPTURE_CONNECTIONS);
    let id = state.manager.add(
        req.url,
        (*state.dest_dir).clone(),
        conns,
        hdrs,
        req.checksum,
    );
    state.stats.record_capture();
    Ok(Json(AddResp {
        id,
        refreshed: false,
    })
    .into_response())
}

async fn add_stream(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<AddStreamReq>,
) -> Result<Response, StatusCode> {
    check_token(&state, &headers)?;
    if !(req.url.starts_with("http://") || req.url.starts_with("https://")) {
        return Err(StatusCode::BAD_REQUEST);
    }
    let hdrs = capture_headers(req.cookie, req.referrer, req.user_agent);
    if let Some(r) = state
        .manager
        .take_captured_link(req.url.clone(), hdrs.clone(), DownloadKind::Hls)
        .await
    {
        return Ok(refreshed(&state, r));
    }
    let id = state
        .manager
        .add_hls(req.url, (*state.dest_dir).clone(), hdrs, req.title);
    state.stats.record_capture();
    Ok(Json(AddResp {
        id,
        refreshed: false,
    })
    .into_response())
}

/// Reply for a link handed to a download waiting for a fresh one: 409 with the
/// reason when refused, so the extension leaves the browser's download alone.
fn refreshed(state: &AppState, r: anyhow::Result<String>) -> Response {
    match r {
        Ok(id) => {
            state.stats.record_capture();
            Json(AddResp {
                id,
                refreshed: true,
            })
            .into_response()
        }
        Err(e) => (
            StatusCode::CONFLICT,
            Json(ErrResp {
                error: describe(&e),
            }),
        )
            .into_response(),
    }
}

/// Build the Cookie/Referer/User-Agent header vec the browser would have sent,
/// dropping empty values.
fn capture_headers(
    cookie: Option<String>,
    referrer: Option<String>,
    user_agent: Option<String>,
) -> Vec<(String, String)> {
    let mut hdrs = Vec::with_capacity(3);
    if let Some(c) = cookie.filter(|v| !v.is_empty()) {
        hdrs.push(("Cookie".into(), c));
    }
    if let Some(r) = referrer.filter(|v| !v.is_empty()) {
        hdrs.push(("Referer".into(), r));
    }
    if let Some(ua) = user_agent.filter(|v| !v.is_empty()) {
        hdrs.push(("User-Agent".into(), ua));
    }
    hdrs
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir() -> String {
        std::env::temp_dir().to_string_lossy().to_string()
    }

    #[tokio::test]
    async fn ping_requires_token() {
        let handle = start(QueueManager::new(), tmp_dir(), 0, "secret".into()).unwrap();
        let port = handle.port;
        let client = reqwest::Client::new();

        let no_token = client
            .get(format!("http://127.0.0.1:{port}/api/ping"))
            .send()
            .await
            .unwrap();
        assert_eq!(no_token.status(), 401);

        let with_token = client
            .get(format!("http://127.0.0.1:{port}/api/ping"))
            .header("X-Shinsoku-Token", "secret")
            .send()
            .await
            .unwrap();
        assert_eq!(with_token.status(), 200);
    }

    #[tokio::test]
    async fn add_enqueues_with_token() {
        let manager = QueueManager::new();
        let handle = start(manager.clone(), tmp_dir(), 0, "secret".into()).unwrap();
        let port = handle.port;
        let client = reqwest::Client::new();

        // non-routable host: item is created synchronously before the background
        // probe runs, so the queue lookup below is race-free.
        let resp = client
            .post(format!("http://127.0.0.1:{port}/api/add"))
            .header("X-Shinsoku-Token", "secret")
            .json(&serde_json::json!({ "url": "http://example.invalid/file.bin" }))
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 200);

        let body: serde_json::Value = resp.json().await.unwrap();
        let id = body["id"].as_str().unwrap();
        assert!(!id.is_empty());
        assert!(manager.get(id).is_some(), "captured download not in queue");
    }
}
