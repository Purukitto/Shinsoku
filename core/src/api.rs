//! flutter_rust_bridge API surface — the only module scanned by codegen
//! (`rust_input: crate::api`). Keep it thin: marshal between Dart and the
//! engine in `queue`/`engine`, which stay independent of the bridge.

use flutter_rust_bridge::frb;

use crate::engine::download::{classify, DownloadItem, DownloadProgress, ProbeResult};
use crate::frb_generated::StreamSink;
use crate::protocols::http::{build_client, probe};
use crate::queue::manager::QueueManager;

#[frb(opaque)]
pub struct ShinsokuEngine {
    manager: QueueManager,
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

#[frb(sync)]
pub fn create_engine() -> ShinsokuEngine {
    ShinsokuEngine {
        manager: QueueManager::new(),
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
) -> String {
    engine.manager.add(url, dest_dir, connections)
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

// ── Live updates ──────────────────────────────────────────────────────────────

/// Live progress stream; emits on change plus an initial snapshot. Call once.
pub fn subscribe_progress(engine: &ShinsokuEngine, sink: StreamSink<DownloadProgress>) {
    engine
        .manager
        .set_emitter(Box::new(move |p| {
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

/// HEAD-probe a URL for the Add dialog. One-shot client (runs on the bridge
/// runtime, not the engine's pool).
pub async fn probe_url(url: String) -> anyhow::Result<ProbeResult> {
    let client = build_client();
    let info = probe(&client, &url).await?;
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
