//! flutter_rust_bridge API surface — the only module scanned by codegen
//! (`rust_input: crate::api`). Keep it thin: marshal between Dart and the
//! engine in `queue`/`engine`, which stay independent of the bridge.

use std::sync::Mutex;

use flutter_rust_bridge::frb;

use crate::capture::CaptureHandle;
use crate::engine::download::{classify, DownloadItem, DownloadProgress, ProbeResult};
use crate::engine::retry::{describe, within, RetryPolicy};
use crate::frb_generated::StreamSink;
use crate::protocols::http::{build_client, build_headers, probe};
use crate::queue::manager::QueueManager;

#[frb(opaque)]
pub struct ShinsokuEngine {
    manager: QueueManager,
    capture: Mutex<Option<CaptureHandle>>,
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

/// Create the engine. `db_path` is the JSON store for the download list/history;
/// an empty string disables persistence (in-memory only).
#[frb(sync)]
pub fn create_engine(db_path: String) -> ShinsokuEngine {
    let manager = if db_path.is_empty() {
        QueueManager::new()
    } else {
        QueueManager::with_store(std::path::PathBuf::from(db_path))
    };
    ShinsokuEngine {
        manager,
        capture: Mutex::new(None),
    }
}

// ── Download control ──────────────────────────────────────────────────────────

/// Queue a download, return its id; probe + start run on a background task.
#[frb(sync)]
pub fn add_download(
    engine: &ShinsokuEngine,
    url: String,
    dest_dir: String,
    connections: u8,
    headers: Vec<(String, String)>,
    expected_checksum: Option<String>,
) -> String {
    engine
        .manager
        .add(url, dest_dir, connections, headers, expected_checksum)
}

/// Queue an HLS (M3U8) stream. The engine fetches the playlist, picks the
/// highest-bitrate variant, and concatenates the media segments into one file.
#[frb(sync)]
pub fn add_stream(
    engine: &ShinsokuEngine,
    url: String,
    dest_dir: String,
    headers: Vec<(String, String)>,
    title: Option<String>,
) -> String {
    engine.manager.add_hls(url, dest_dir, headers, title)
}

#[frb(sync)]
pub fn pause_download(engine: &ShinsokuEngine, id: String) {
    engine.manager.pause(&id);
}

#[frb(sync)]
pub fn resume_download(engine: &ShinsokuEngine, id: String) {
    engine.manager.resume(&id);
}

#[frb(sync)]
pub fn remove_download(engine: &ShinsokuEngine, id: String) {
    engine.manager.remove(&id);
}

/// Point a stopped download at a new link for the same file and resume it.
/// Fails, leaving the download as it was, when the link doesn't work or serves
/// a different file. Keeps the download's request headers.
pub async fn refresh_download(
    engine: &ShinsokuEngine,
    id: String,
    url: String,
) -> anyhow::Result<()> {
    // the Dart side shows the message as is
    engine
        .manager
        .refresh_url(&id, url, None)
        .await
        .map_err(|e| anyhow::anyhow!(describe(&e)))
}

/// While set, the next link the browser extension captures goes to download
/// `id` (with the browser's fresh cookies) instead of a new download. `None`
/// stops waiting.
#[frb(sync)]
pub fn await_link(engine: &ShinsokuEngine, id: Option<String>) {
    engine.manager.await_link(id);
}

/// The download waiting for a captured link, and why the last link sent to it
/// was refused.
pub struct LinkWait {
    pub id: String,
    pub error: Option<String>,
}

/// `None` once a captured link has been taken, or when nothing is waiting.
#[frb(sync)]
pub fn link_wait(engine: &ShinsokuEngine) -> Option<LinkWait> {
    engine.manager.refresh_target().map(|t| LinkWait {
        id: t.id,
        error: t.error,
    })
}

// ── Live updates ──────────────────────────────────────────────────────────────

/// Live progress stream; emits on change plus an initial snapshot. Call once.
pub fn subscribe_progress(engine: &ShinsokuEngine, sink: StreamSink<DownloadProgress>) {
    engine.manager.set_emitter(Box::new(move |p| {
        let _ = sink.add(p);
    }));
}

// ── State queries ─────────────────────────────────────────────────────────────

pub fn get_downloads(engine: &ShinsokuEngine) -> Vec<DownloadItem> {
    engine.manager.snapshot()
}

pub fn get_progress(engine: &ShinsokuEngine) -> Vec<DownloadProgress> {
    engine.manager.progress_snapshot()
}

pub fn get_download(engine: &ShinsokuEngine, id: String) -> Option<DownloadItem> {
    engine.manager.get(&id)
}

/// True when the URL path ends in `.m3u8` (query/fragment ignored) — an HLS
/// playlist, handled by the stream path rather than a byte-range download.
fn is_hls_url(url: &str) -> bool {
    url.split(['?', '#'])
        .next()
        .unwrap_or(url)
        .to_ascii_lowercase()
        .ends_with(".m3u8")
}

/// HEAD-probe a URL for the Add dialog. One-shot client (runs on the bridge
/// runtime, not the engine's pool). An `.m3u8` URL is reported as an HLS stream
/// without a HEAD, so the dialog routes Add → [`add_stream`].
pub async fn probe_url(url: String) -> anyhow::Result<ProbeResult> {
    if is_hls_url(&url) {
        let stem = url
            .split(['?', '#'])
            .next()
            .unwrap_or(&url)
            .rsplit('/')
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or("stream");
        let stem = stem.get(..stem.len() - 5).unwrap_or(stem); // drop ".m3u8"
        let host = url.split('/').nth(2).unwrap_or("").to_string();
        return Ok(ProbeResult {
            filename: format!("{stem}.ts"),
            total_bytes: 0,
            resumable: false,
            mime_type: Some("application/vnd.apple.mpegurl".to_string()),
            host,
            file_type: "video".to_string(),
        });
    }
    let client = build_client();
    let stall = RetryPolicy::default().stall_timeout;
    let info = within(stall, probe(&client, &url, &build_headers(&[]))).await??;
    let filename = info.filename.clone().unwrap_or_else(|| {
        url.split('?')
            .next()
            .unwrap_or(&url)
            .rsplit('/')
            .next()
            .filter(|s| !s.is_empty())
            .unwrap_or("download")
            .to_string()
    });
    let host = url.split('/').nth(2).unwrap_or("").to_string();
    let file_type = classify(&filename, info.mime_type.as_deref());
    Ok(ProbeResult {
        filename,
        total_bytes: info.total_bytes,
        resumable: info.resumable,
        mime_type: info.mime_type,
        host,
        file_type,
    })
}

// ── Settings ──────────────────────────────────────────────────────────────────

#[frb(sync)]
pub fn set_max_connections(engine: &ShinsokuEngine, n: u8) {
    engine.manager.set_max_connections(n);
}

#[frb(sync)]
pub fn set_speed_limit_bps(engine: &ShinsokuEngine, bps: u64) {
    engine.manager.set_speed_limit(bps);
}

#[frb(sync)]
pub fn set_max_simultaneous(engine: &ShinsokuEngine, n: u8) {
    engine.manager.set_max_simultaneous(n);
}

/// Sort downloads into category subfolders under the download dir.
#[frb(sync)]
pub fn set_categorize(engine: &ShinsokuEngine, on: bool) {
    engine.manager.set_categorize(on);
}

/// Off-peak acceleration window (minutes since local midnight; `start > end`
/// wraps past midnight). Inside it downloads ignore the speed limit; outside it
/// the limit set via [`set_speed_limit_bps`] applies.
#[frb(sync)]
pub fn set_off_peak(engine: &ShinsokuEngine, enabled: bool, start_min: u16, end_min: u16) {
    engine.manager.set_off_peak(enabled, start_min, end_min);
}

// ── Browser capture ─────────────────────────────────────────────────────────

/// Start the loopback capture server the browser extension posts to. Tries
/// `port` (then a few above if taken); returns the bound port, or 0 on failure.
/// Captured downloads land in `dest_dir`. Restarts if already running.
#[frb(sync)]
pub fn start_capture_server(
    engine: &ShinsokuEngine,
    port: u16,
    token: String,
    dest_dir: String,
) -> u16 {
    let mut guard = engine.capture.lock().unwrap();
    *guard = None; // stop any previous instance first
    match crate::capture::start(engine.manager.clone(), dest_dir, port, token) {
        Ok(handle) => {
            let bound = handle.port;
            *guard = Some(handle);
            bound
        }
        Err(_) => 0,
    }
}

#[frb(sync)]
pub fn stop_capture_server(engine: &ShinsokuEngine) {
    *engine.capture.lock().unwrap() = None;
}

/// Live capture state for the UI. `last_seen_ms` is 0 until a browser first
/// authenticates this session; once non-zero, an extension is paired.
pub struct CaptureStatus {
    pub running: bool,
    pub port: u16,
    pub last_seen_ms: i64,
    pub captures: u32,
}

#[frb(sync)]
pub fn capture_status(engine: &ShinsokuEngine) -> CaptureStatus {
    match engine.capture.lock().unwrap().as_ref() {
        Some(h) => {
            let (last_seen_ms, captures) = h.stats();
            CaptureStatus {
                running: true,
                port: h.port,
                last_seen_ms,
                captures,
            }
        }
        None => CaptureStatus {
            running: false,
            port: 0,
            last_seen_ms: 0,
            captures: 0,
        },
    }
}
