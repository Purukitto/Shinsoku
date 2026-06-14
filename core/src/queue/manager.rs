use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use anyhow::Result;
use reqwest::Client;
use tokio::runtime::Runtime;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::engine::download::{classify, DownloadItem, DownloadProgress, DownloadStatus};
use crate::engine::orchestrator::{fetch_plan, run_segments};
use crate::engine::throttle::RateLimiter;
use crate::protocols::http::build_client;
use crate::storage::assembler::{finalize, temp_path};
use crate::storage::partial::prepare_destination;

const TICK: Duration = Duration::from_millis(250);
const HISTORY_LEN: usize = 60;

/// Progress sink; the bridge layer forwards to a `StreamSink`.
pub type ProgressEmitter = Box<dyn Fn(DownloadProgress) + Send + Sync>;

/// Items + display order behind one lock.
struct Inner {
    items: HashMap<String, DownloadItem>,
    order: Vec<String>,
}

/// Per running download: cancel handle + per-segment counters read by the aggregator.
struct Active {
    cancel: CancellationToken,
    seg_done: Vec<Arc<AtomicU64>>,
}

/// Shared engine state behind `Arc`.
pub(crate) struct Shared {
    inner: RwLock<Inner>,
    http: Client,
    limiter: Arc<RateLimiter>,
    active: Mutex<HashMap<String, Active>>,
    sink: Mutex<Option<ProgressEmitter>>,
    rt: Runtime,
    max_connections: AtomicU8,
    max_simultaneous: AtomicU8,
    categorize: AtomicBool,
}

/// Handle to the engine; interior mutability throughout, so tasks and bridge
/// calls share one instance.
pub struct QueueManager {
    shared: Arc<Shared>,
}

impl QueueManager {
    pub fn new() -> Self {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to build engine runtime");
        let shared = Arc::new(Shared {
            inner: RwLock::new(Inner {
                items: HashMap::new(),
                order: Vec::new(),
            }),
            http: build_client(),
            limiter: Arc::new(RateLimiter::new(0)),
            active: Mutex::new(HashMap::new()),
            sink: Mutex::new(None),
            rt,
            max_connections: AtomicU8::new(8),
            max_simultaneous: AtomicU8::new(3),
            categorize: AtomicBool::new(true),
        });
        // background loop: progress/speed, scheduler, emit
        let agg = shared.clone();
        shared.rt.spawn(async move { aggregator(agg).await });
        Self { shared }
    }

    /// Clone of the shared HTTP client.
    pub fn http(&self) -> Client {
        self.shared.http.clone()
    }

    pub fn add(&self, url: String, dest_dir: String, connections: u8) -> String {
        let id = Uuid::new_v4().to_string();
        let filename = filename_from_url(&url);
        let host = url.split('/').nth(2).unwrap_or("").to_string();
        let conns = connections
            .max(1)
            .min(self.shared.max_connections.load(Ordering::Relaxed));
        let item = DownloadItem {
            id: id.clone(),
            url,
            filename: filename.clone(),
            dest_path: join_path(&dest_dir, &filename),
            total_bytes: 0,
            downloaded_bytes: 0,
            speed_bps: 0,
            peak_bps: 0,
            status: DownloadStatus::Queued,
            connections: conns,
            segments: vec![],
            speed_history: vec![0; HISTORY_LEN],
            added_at_ms: chrono::Utc::now().timestamp_millis(),
            mime_type: None,
            resumable: false,
            host,
            file_type: classify(&filename, None),
            error: None,
        };
        {
            let mut inner = self.shared.inner.write().unwrap();
            inner.items.insert(id.clone(), item);
            inner.order.insert(0, id.clone());
        }
        emit_item(&self.shared, &id);
        schedule(&self.shared);
        id
    }

    pub fn pause(&self, id: &str) {
        {
            let mut inner = self.shared.inner.write().unwrap();
            if let Some(it) = inner.items.get_mut(id) {
                it.status = DownloadStatus::Paused;
                it.speed_bps = 0;
            }
        }
        if let Some(a) = self.shared.active.lock().unwrap().get(id) {
            a.cancel.cancel();
        }
        emit_item(&self.shared, id);
    }

    pub fn resume(&self, id: &str) {
        {
            let mut inner = self.shared.inner.write().unwrap();
            if let Some(it) = inner.items.get_mut(id) {
                if matches!(it.status, DownloadStatus::Paused | DownloadStatus::Error) {
                    it.status = DownloadStatus::Queued;
                    it.error = None;
                }
            }
        }
        schedule(&self.shared);
        emit_item(&self.shared, id);
    }

    pub fn remove(&self, id: &str) {
        if let Some(a) = self.shared.active.lock().unwrap().get(id) {
            a.cancel.cancel();
        }
        let dest = {
            let mut inner = self.shared.inner.write().unwrap();
            let d = inner.items.get(id).map(|it| PathBuf::from(&it.dest_path));
            inner.items.remove(id);
            inner.order.retain(|x| x != id);
            d
        };
        self.shared.active.lock().unwrap().remove(id);
        // remove in-flight temp
        if let Some(dest) = dest {
            let temp = temp_path(&dest);
            self.shared.rt.spawn(async move {
                let _ = tokio::fs::remove_file(temp).await;
            });
        }
    }

    /// Full snapshot — initial load and detail views (not per-tick polling).
    pub fn snapshot(&self) -> Vec<DownloadItem> {
        let inner = self.shared.inner.read().unwrap();
        inner
            .order
            .iter()
            .filter_map(|id| inner.items.get(id).cloned())
            .collect()
    }

    pub fn progress_snapshot(&self) -> Vec<DownloadProgress> {
        let inner = self.shared.inner.read().unwrap();
        inner
            .order
            .iter()
            .filter_map(|id| inner.items.get(id))
            .map(progress_of)
            .collect()
    }

    pub fn get(&self, id: &str) -> Option<DownloadItem> {
        self.shared.inner.read().unwrap().items.get(id).cloned()
    }

    /// Register the progress sink and seed it with the current state.
    pub fn set_emitter(&self, emit: ProgressEmitter) {
        for p in self.progress_snapshot() {
            emit(p);
        }
        *self.shared.sink.lock().unwrap() = Some(emit);
    }

    pub fn set_max_connections(&self, n: u8) {
        self.shared
            .max_connections
            .store(n.clamp(1, 32), Ordering::Relaxed);
    }

    pub fn set_max_simultaneous(&self, n: u8) {
        self.shared
            .max_simultaneous
            .store(n.clamp(1, 16), Ordering::Relaxed);
        schedule(&self.shared);
    }

    pub fn set_speed_limit(&self, bps: u64) {
        self.shared.limiter.set_rate(bps);
    }

    pub fn set_categorize(&self, on: bool) {
        self.shared.categorize.store(on, Ordering::Relaxed);
    }
}

impl Default for QueueManager {
    fn default() -> Self {
        Self::new()
    }
}

// ── background loop ───────────────────────────────────────────────────────────

async fn aggregator(shared: Arc<Shared>) {
    let mut ticker = tokio::time::interval(TICK);
    let mut last = Instant::now();
    loop {
        ticker.tick().await;
        let now = Instant::now();
        let dt = (now - last).as_secs_f64().max(0.001);
        last = now;

        // snapshot per-segment counters of running downloads
        let snaps: Vec<(String, Vec<u64>)> = {
            let active = shared.active.lock().unwrap();
            active
                .iter()
                .filter(|(_, a)| !a.seg_done.is_empty())
                .map(|(id, a)| {
                    (
                        id.clone(),
                        a.seg_done.iter().map(|c| c.load(Ordering::Relaxed)).collect(),
                    )
                })
                .collect()
        };

        let mut emits = Vec::new();
        {
            let mut inner = shared.inner.write().unwrap();
            for (id, segs) in &snaps {
                let Some(item) = inner.items.get_mut(id) else { continue };
                if !matches!(item.status, DownloadStatus::Downloading) {
                    continue;
                }
                let done: u64 = segs.iter().sum();
                let speed = (done.saturating_sub(item.downloaded_bytes) as f64 / dt).round() as u64;
                item.downloaded_bytes = done;
                item.speed_bps = speed;
                if speed > item.peak_bps {
                    item.peak_bps = speed;
                }
                for (i, s) in item.segments.iter_mut().enumerate() {
                    if let Some(&d) = segs.get(i) {
                        s.downloaded_bytes = d;
                    }
                }
                push_history(&mut item.speed_history, speed);
                emits.push(progress_of(item));
            }
        }

        schedule(&shared);

        for p in emits {
            emit(&shared, p);
        }
    }
}

/// Promote queued → running up to the simultaneous cap (oldest first).
fn schedule(shared: &Arc<Shared>) {
    let max = shared.max_simultaneous.load(Ordering::Relaxed) as usize;
    let to_start: Vec<String> = {
        let inner = shared.inner.read().unwrap();
        let running = inner
            .items
            .values()
            .filter(|i| matches!(i.status, DownloadStatus::Downloading))
            .count();
        let mut slots = max.saturating_sub(running);
        let mut ids = Vec::new();
        if slots > 0 {
            for id in inner.order.iter().rev() {
                if slots == 0 {
                    break;
                }
                if let Some(it) = inner.items.get(id) {
                    if matches!(it.status, DownloadStatus::Queued) {
                        ids.push(id.clone());
                        slots -= 1;
                    }
                }
            }
        }
        ids
    };
    for id in to_start {
        start_download(shared.clone(), id);
    }
}

fn start_download(shared: Arc<Shared>, id: String) {
    {
        let mut active = shared.active.lock().unwrap();
        if active.contains_key(&id) {
            return; // already running
        }
        active.insert(
            id.clone(),
            Active {
                cancel: CancellationToken::new(),
                seg_done: Vec::new(),
            },
        );
    }
    let cancel = shared.active.lock().unwrap().get(&id).unwrap().cancel.clone();
    {
        let mut inner = shared.inner.write().unwrap();
        match inner.items.get_mut(&id) {
            Some(it) => it.status = DownloadStatus::Downloading,
            None => {
                shared.active.lock().unwrap().remove(&id);
                return;
            }
        }
    }
    emit_item(&shared, &id);
    let s = shared.clone();
    shared.rt.spawn(async move { run_download(s, id, cancel).await });
}

async fn run_download(shared: Arc<Shared>, id: String, cancel: CancellationToken) {
    let result = run_download_inner(&shared, &id, &cancel).await;

    // temp to delete after releasing the lock (failure that wrote nothing)
    let mut cleanup_temp: Option<PathBuf> = None;
    {
        let mut inner = shared.inner.write().unwrap();
        if let Some(item) = inner.items.get_mut(&id) {
            item.speed_bps = 0;
            if cancel.is_cancelled() {
                if matches!(item.status, DownloadStatus::Downloading) {
                    item.status = DownloadStatus::Paused;
                }
            } else {
                match &result {
                    Ok(()) => {
                        item.status = DownloadStatus::Completed;
                        item.error = None;
                        if item.total_bytes > 0 {
                            item.downloaded_bytes = item.total_bytes;
                        }
                        for s in &mut item.segments {
                            s.downloaded_bytes = s.end_byte.saturating_sub(s.start_byte);
                        }
                    }
                    Err(e) => {
                        item.status = DownloadStatus::Error;
                        item.error = Some(e.to_string());
                        // no bytes written → drop temp
                        if item.downloaded_bytes == 0 {
                            cleanup_temp = Some(temp_path(&PathBuf::from(&item.dest_path)));
                        }
                    }
                }
            }
        }
    }

    shared.active.lock().unwrap().remove(&id);
    if let Some(temp) = cleanup_temp {
        let _ = tokio::fs::remove_file(temp).await;
    }
    emit_item(&shared, &id);
    schedule(&shared);
}

async fn run_download_inner(
    shared: &Arc<Shared>,
    id: &str,
    cancel: &CancellationToken,
) -> Result<()> {
    let (url, dest, mut segments, is_resume, connections) = {
        let inner = shared.inner.read().unwrap();
        let it = inner
            .items
            .get(id)
            .ok_or_else(|| anyhow::anyhow!("download {id} not found"))?;
        let is_resume = it.total_bytes > 0 && !it.segments.is_empty();
        (
            it.url.clone(),
            PathBuf::from(&it.dest_path),
            it.segments.clone(),
            is_resume,
            it.connections,
        )
    };
    let mut dest = dest;
    let mut temp = temp_path(&dest);

    if !is_resume {
        let plan = fetch_plan(&shared.http, &url, connections).await?;
        let filename = plan
            .filename
            .clone()
            .unwrap_or_else(|| filename_of(&dest));
        let ftype = classify(&filename, plan.mime_type.as_deref());

        // route into a category subfolder of the base dir when enabled
        if shared.categorize.load(Ordering::Relaxed) {
            let base = dest
                .parent()
                .map(|p| p.to_path_buf())
                .unwrap_or_else(|| PathBuf::from("."));
            dest = base.join(category_folder(&ftype)).join(&filename);
            if let Some(parent) = dest.parent() {
                let _ = tokio::fs::create_dir_all(parent).await;
            }
            temp = temp_path(&dest);
        }

        // don't clobber an existing file: file.ext → file (1).ext, …
        dest = unique_path(&dest);
        temp = temp_path(&dest);

        {
            let mut inner = shared.inner.write().unwrap();
            if let Some(it) = inner.items.get_mut(id) {
                it.total_bytes = plan.total;
                it.resumable = plan.resumable;
                it.mime_type = plan.mime_type.clone();
                it.segments = plan.segments.clone();
                it.connections = plan.segments.len() as u8;
                it.file_type = ftype;
                it.dest_path = dest.to_string_lossy().to_string();
            }
        }
        prepare_destination(&temp, plan.total).await?;
        segments = plan.segments;
    }

    // seed counters from bytes already on disk (resume)
    let counters: Vec<Arc<AtomicU64>> = segments
        .iter()
        .map(|s| Arc::new(AtomicU64::new(s.downloaded_bytes)))
        .collect();
    if let Some(a) = shared.active.lock().unwrap().get_mut(id) {
        a.seg_done = counters.clone();
    }

    let result = run_segments(
        &shared.http,
        shared.limiter.clone(),
        &url,
        &temp,
        &segments,
        &counters,
        cancel.clone(),
    )
    .await;

    persist_progress(shared, id, &counters);
    result?;

    if cancel.is_cancelled() {
        return Ok(()); // paused; keep partial for resume
    }
    finalize(&temp, &dest).await?;
    Ok(())
}

/// Write counters back into the item so resume continues from the right offsets.
fn persist_progress(shared: &Shared, id: &str, counters: &[Arc<AtomicU64>]) {
    let mut inner = shared.inner.write().unwrap();
    if let Some(it) = inner.items.get_mut(id) {
        let mut total = 0u64;
        for (i, s) in it.segments.iter_mut().enumerate() {
            if let Some(c) = counters.get(i) {
                let d = c.load(Ordering::Relaxed);
                s.downloaded_bytes = d;
                total += d;
            }
        }
        it.downloaded_bytes = total;
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn emit(shared: &Shared, p: DownloadProgress) {
    if let Some(emit) = shared.sink.lock().unwrap().as_ref() {
        emit(p);
    }
}

fn emit_item(shared: &Shared, id: &str) {
    let p = {
        let inner = shared.inner.read().unwrap();
        inner.items.get(id).map(progress_of)
    };
    if let Some(p) = p {
        emit(shared, p);
    }
}

fn progress_of(it: &DownloadItem) -> DownloadProgress {
    DownloadProgress {
        id: it.id.clone(),
        downloaded_bytes: it.downloaded_bytes,
        total_bytes: it.total_bytes,
        speed_bps: it.speed_bps,
        status: it.status.clone(),
    }
}

fn push_history(h: &mut Vec<u64>, v: u64) {
    if h.len() >= HISTORY_LEN {
        h.remove(0);
    }
    h.push(v);
}

fn filename_from_url(url: &str) -> String {
    url.split('?')
        .next()
        .unwrap_or(url)
        .rsplit('/')
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or("download")
        .to_string()
}

/// First free path for `dest`, appending ` (n)` before the extension. Also
/// avoids names whose temp file is already in flight.
fn unique_path(dest: &Path) -> PathBuf {
    if !dest.exists() && !temp_path(dest).exists() {
        return dest.to_path_buf();
    }
    let parent = dest.parent().unwrap_or_else(|| Path::new("."));
    let stem = dest.file_stem().and_then(|s| s.to_str()).unwrap_or("download");
    let ext = dest.extension().and_then(|e| e.to_str());
    for n in 1..100_000 {
        let name = match ext {
            Some(e) => format!("{stem} ({n}).{e}"),
            None => format!("{stem} ({n})"),
        };
        let candidate = parent.join(name);
        if !candidate.exists() && !temp_path(&candidate).exists() {
            return candidate;
        }
    }
    dest.to_path_buf()
}

/// Category subfolder for a file-type bucket.
fn category_folder(file_type: &str) -> &'static str {
    match file_type {
        "video" => "Videos",
        "audio" => "Music",
        "image" => "Images",
        "archive" => "Compressed",
        "doc" => "Documents",
        "app" | "iso" => "Programs",
        _ => "Other",
    }
}

fn filename_of(p: &Path) -> String {
    p.file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("download")
        .to_string()
}

fn join_path(dir: &str, name: &str) -> String {
    let mut p = PathBuf::from(dir);
    p.push(name);
    p.to_string_lossy().to_string()
}
