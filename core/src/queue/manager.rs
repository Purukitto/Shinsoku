use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicU32, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use anyhow::{bail, Result};
use chrono::{Datelike, Timelike};
use futures::StreamExt;
use reqwest::header::HeaderMap;
use reqwest::Client;
use tokio::fs::{File, OpenOptions};
use tokio::io::{AsyncSeekExt, AsyncWriteExt, BufWriter, SeekFrom};
use tokio::runtime::Runtime;
use tokio_util::sync::CancellationToken;
use url::Url;
use uuid::Uuid;

use crate::engine::download::{
    classify, DownloadItem, DownloadKind, DownloadProgress, DownloadStatus,
};
use crate::engine::orchestrator::{fetch_plan, run_segments};
use crate::engine::retry::{describe, within, Retry, RetryPolicy};
use crate::engine::throttle::RateLimiter;
use crate::protocols::hls::{self, KeyMethod};
use crate::protocols::http::{build_client, build_headers, probe_range};
use crate::storage::assembler::{finalize, temp_path};
use crate::storage::integrity::{hash_file, HashAlgo};
use crate::storage::partial::prepare_destination;
use crate::storage::store;

const TICK: Duration = Duration::from_millis(250);
const HISTORY_LEN: usize = 60;
/// Checkpoint in-progress segment offsets to disk every N ticks (~5s) so a crash
/// resumes near where it left off rather than from scratch.
const CHECKPOINT_TICKS: u32 = 20;
/// Cap persisted completed downloads (most recent kept) to bound the store file.
const HISTORY_CAP: usize = 500;
/// Off-peak day mask with every day of the week set.
pub const EVERY_DAY: u8 = 0x7f;

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
    /// Retries this run has made; mirrored into `DownloadItem.retry_count`.
    retries: Arc<AtomicU32>,
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
    /// User-configured global download limit (bytes/s; 0 = unlimited). The rate
    /// actually pushed to `limiter` is derived from this and the off-peak window.
    speed_limit: AtomicU64,
    /// Off-peak hours, in minutes since local midnight; they wrap past midnight
    /// when start > end and never open when start == end. `off_peak_days` picks
    /// the days they begin on (bit 0 = Monday … bit 6 = Sunday). Scheduled
    /// downloads run only inside them; with `off_peak_full_speed` the limiter
    /// also runs unthrottled inside them, regardless of `speed_limit`.
    off_peak_full_speed: AtomicBool,
    off_peak_start_min: AtomicU16,
    off_peak_end_min: AtomicU16,
    off_peak_days: AtomicU8,
    /// Read once per run, so a change applies from the next start or resume.
    retry_policy: Mutex<RetryPolicy>,
    /// Persistence target; `None` disables persistence (used by tests).
    store: Option<PathBuf>,
    /// Serialises store writes so concurrent saves can't interleave.
    persist_lock: Mutex<()>,
    /// Download waiting for its next captured link (see [`QueueManager::await_link`]).
    refresh_target: Mutex<Option<RefreshTarget>>,
}

/// A stopped download that the next link captured from the browser goes to,
/// instead of a new download.
#[derive(Debug, Clone)]
pub struct RefreshTarget {
    pub id: String,
    /// Why the last captured link was refused; the target stays armed.
    pub error: Option<String>,
}

/// Handle to the engine; interior mutability throughout, so tasks and bridge
/// calls share one instance. Cloning shares the same `Shared` (cheap Arc bump),
/// letting the capture server drive the same queue.
#[derive(Clone)]
pub struct QueueManager {
    shared: Arc<Shared>,
}

impl QueueManager {
    /// In-memory only (no persistence). Used by tests.
    pub fn new() -> Self {
        Self::build(
            None,
            Inner {
                items: HashMap::new(),
                order: Vec::new(),
            },
        )
    }

    /// Load any persisted downloads from `path` and write changes back, so the
    /// queue and completed history survive restarts.
    pub fn with_store(path: PathBuf) -> Self {
        let inner = load_items(&path);
        Self::build(Some(path), inner)
    }

    fn build(store: Option<PathBuf>, inner: Inner) -> Self {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("failed to build engine runtime");
        let shared = Arc::new(Shared {
            inner: RwLock::new(inner),
            http: build_client(),
            limiter: Arc::new(RateLimiter::new(0)),
            active: Mutex::new(HashMap::new()),
            sink: Mutex::new(None),
            rt,
            max_connections: AtomicU8::new(8),
            max_simultaneous: AtomicU8::new(3),
            categorize: AtomicBool::new(true),
            speed_limit: AtomicU64::new(0),
            off_peak_full_speed: AtomicBool::new(false),
            off_peak_start_min: AtomicU16::new(0),
            off_peak_end_min: AtomicU16::new(0),
            off_peak_days: AtomicU8::new(EVERY_DAY),
            retry_policy: Mutex::new(RetryPolicy::default()),
            store,
            persist_lock: Mutex::new(()),
            refresh_target: Mutex::new(None),
        });
        // background loop: progress/speed, scheduler, emit
        let agg = shared.clone();
        shared.rt.spawn(async move { aggregator(agg).await });
        // queued/interrupted items loaded from the store start as soon as slots free up
        schedule(&shared);
        Self { shared }
    }

    /// Clone of the shared HTTP client.
    pub fn http(&self) -> Client {
        self.shared.http.clone()
    }

    /// The engine's tokio runtime (capture server spawns onto it).
    pub fn runtime(&self) -> &Runtime {
        &self.shared.rt
    }

    /// Configured max segments; capture uses this as the per-download default.
    pub fn default_connections(&self) -> u8 {
        self.shared.max_connections.load(Ordering::Relaxed)
    }

    pub fn add(
        &self,
        url: String,
        dest_dir: String,
        connections: u8,
        headers: Vec<(String, String)>,
        expected_checksum: Option<String>,
        scheduled: bool,
    ) -> String {
        let id = Uuid::new_v4().to_string();
        let filename = filename_from_url(&url);
        let host = host_of(&url);
        let conns = connections
            .max(1)
            .min(self.shared.max_connections.load(Ordering::Relaxed));
        let item = DownloadItem {
            id: id.clone(),
            url,
            filename: filename.clone(),
            dest_path: join_path(&dest_dir, &filename),
            dest_dir,
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
            completed_at_ms: None,
            headers,
            expected_checksum: expected_checksum.filter(|s| !s.trim().is_empty()),
            checksum: None,
            checksum_algo: None,
            checksum_verified: None,
            kind: DownloadKind::Http,
            segment_total: 0,
            segment_done: 0,
            retry_count: 0,
            scheduled,
        };
        {
            let mut inner = self.shared.inner.write().unwrap();
            inner.items.insert(id.clone(), item);
            inner.order.insert(0, id.clone());
        }
        emit_item(&self.shared, &id);
        schedule(&self.shared);
        schedule_persist(&self.shared);
        id
    }

    /// Queue an HLS (M3U8) download. `url` is the playlist; the engine fetches it,
    /// picks the highest-bitrate variant, and concatenates the media segments.
    pub fn add_hls(
        &self,
        url: String,
        dest_dir: String,
        headers: Vec<(String, String)>,
        title: Option<String>,
        scheduled: bool,
    ) -> String {
        let id = Uuid::new_v4().to_string();
        let filename = hls_filename(&url, title.as_deref());
        let host = host_of(&url);
        let conns = self.shared.max_connections.load(Ordering::Relaxed).max(1);
        let item = DownloadItem {
            id: id.clone(),
            url,
            filename: filename.clone(),
            dest_path: join_path(&dest_dir, &filename),
            dest_dir,
            total_bytes: 0,
            downloaded_bytes: 0,
            speed_bps: 0,
            peak_bps: 0,
            status: DownloadStatus::Queued,
            connections: conns,
            segments: vec![],
            speed_history: vec![0; HISTORY_LEN],
            added_at_ms: chrono::Utc::now().timestamp_millis(),
            mime_type: Some("application/vnd.apple.mpegurl".into()),
            resumable: true,
            host,
            file_type: "video".into(),
            error: None,
            completed_at_ms: None,
            headers,
            expected_checksum: None,
            checksum: None,
            checksum_algo: None,
            checksum_verified: None,
            kind: DownloadKind::Hls,
            segment_total: 0,
            segment_done: 0,
            retry_count: 0,
            scheduled,
        };
        {
            let mut inner = self.shared.inner.write().unwrap();
            inner.items.insert(id.clone(), item);
            inner.order.insert(0, id.clone());
        }
        emit_item(&self.shared, &id);
        schedule(&self.shared);
        schedule_persist(&self.shared);
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
        schedule_persist(&self.shared);
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
        schedule_persist(&self.shared);
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
        schedule_persist(&self.shared);
    }

    /// Point a stopped download at a new link for the same file, then queue it
    /// to resume. The link must serve that file: the same size for a byte-range
    /// download, the same segment count for HLS. `headers` replaces the stored
    /// request headers (a capture brings fresh cookies); `None` keeps them.
    pub async fn refresh_url(
        &self,
        id: &str,
        url: String,
        headers: Option<Vec<(String, String)>>,
    ) -> Result<()> {
        let url = url.trim().to_string();
        if !(url.starts_with("http://") || url.starts_with("https://")) {
            bail!("Not an http(s) link");
        }
        let it = self
            .get(id)
            .ok_or_else(|| anyhow::anyhow!("Download not found"))?;
        check_refreshable(&it.status)?;
        let hdrs = headers.clone().unwrap_or_else(|| it.headers.clone());
        let (shared, check) = (self.shared.clone(), url.clone());
        // on the engine runtime: the pooled client belongs to it
        self.shared
            .rt
            .spawn(async move { verify_same_file(&shared, &it, &check, &hdrs).await })
            .await??;

        {
            let mut inner = self.shared.inner.write().unwrap();
            let it = inner
                .items
                .get_mut(id)
                .ok_or_else(|| anyhow::anyhow!("Download not found"))?;
            check_refreshable(&it.status)?;
            it.host = host_of(&url);
            it.url = url;
            if let Some(h) = headers {
                it.headers = h;
            }
            it.error = None;
            it.retry_count = 0;
            it.status = DownloadStatus::Queued;
        }
        emit_item(&self.shared, id);
        schedule(&self.shared);
        schedule_persist(&self.shared);
        Ok(())
    }

    /// Send the next link captured from the browser to download `id` instead of
    /// adding a new one; `None` stops waiting.
    pub fn await_link(&self, id: Option<String>) {
        *self.shared.refresh_target.lock().unwrap() =
            id.map(|id| RefreshTarget { id, error: None });
    }

    pub fn refresh_target(&self) -> Option<RefreshTarget> {
        self.shared.refresh_target.lock().unwrap().clone()
    }

    /// Hand a captured link to the download waiting for one (see
    /// [`Self::await_link`]). `None` when nothing is waiting, so the caller adds
    /// a new download. A refused link leaves the download waiting, with the
    /// reason recorded for the UI.
    pub async fn take_captured_link(
        &self,
        url: String,
        headers: Vec<(String, String)>,
        kind: DownloadKind,
    ) -> Option<Result<String>> {
        let id = self.refresh_target()?.id;
        let result = match self.get(&id).map(|it| it.kind) {
            None => {
                self.clear_target(&id);
                return None;
            }
            Some(k) if k != kind => Err(anyhow::anyhow!(match k {
                DownloadKind::Http => "Expected a file download, not a stream",
                DownloadKind::Hls => "Expected a stream; send it from the toolbar popup",
            })),
            Some(_) => self.refresh_url(&id, url, Some(headers)).await,
        };
        match &result {
            Ok(()) => self.clear_target(&id),
            Err(e) => {
                if let Some(t) = self.shared.refresh_target.lock().unwrap().as_mut() {
                    if t.id == id {
                        t.error = Some(describe(e));
                    }
                }
            }
        }
        Some(result.map(|()| id))
    }

    /// Stop waiting for a link, unless the target has since moved to another id.
    fn clear_target(&self, id: &str) {
        let mut t = self.shared.refresh_target.lock().unwrap();
        if t.as_ref().is_some_and(|t| t.id == id) {
            *t = None;
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
        self.shared.speed_limit.store(bps, Ordering::Relaxed);
        apply_effective_limit(&self.shared);
    }

    /// Configure off-peak hours (minutes since local midnight) and the days they
    /// begin on (bit 0 = Monday). Scheduled downloads run only inside them; with
    /// `full_speed` the configured `speed_limit` is lifted inside them too.
    pub fn set_off_peak(&self, full_speed: bool, start_min: u16, end_min: u16, days: u8) {
        self.shared
            .off_peak_full_speed
            .store(full_speed, Ordering::Relaxed);
        self.shared
            .off_peak_start_min
            .store(start_min, Ordering::Relaxed);
        self.shared
            .off_peak_end_min
            .store(end_min, Ordering::Relaxed);
        self.shared
            .off_peak_days
            .store(days & EVERY_DAY, Ordering::Relaxed);
        apply_effective_limit(&self.shared);
        hold_scheduled(&self.shared);
        schedule(&self.shared);
    }

    /// Run a download only during off-peak hours, or (`on == false`) as soon as
    /// a slot is free. Scheduling a stopped download queues it for the next
    /// off-peak hours; one running outside them goes back to waiting.
    pub fn set_scheduled(&self, id: &str, on: bool) {
        {
            let mut inner = self.shared.inner.write().unwrap();
            let Some(it) = inner.items.get_mut(id) else {
                return;
            };
            if matches!(it.status, DownloadStatus::Completed) {
                return;
            }
            it.scheduled = on;
            if on && matches!(it.status, DownloadStatus::Paused | DownloadStatus::Error) {
                it.status = DownloadStatus::Queued;
                it.error = None;
            }
        }
        hold_scheduled(&self.shared);
        schedule(&self.shared);
        emit_item(&self.shared, id);
        schedule_persist(&self.shared);
    }

    pub fn set_categorize(&self, on: bool) {
        self.shared.categorize.store(on, Ordering::Relaxed);
    }

    pub fn set_retry_policy(&self, policy: RetryPolicy) {
        *self.shared.retry_policy.lock().unwrap() = policy;
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
    let mut ticks: u32 = 0;
    loop {
        ticker.tick().await;
        let now = Instant::now();
        let dt = (now - last).as_secs_f64().max(0.001);
        last = now;
        ticks = ticks.wrapping_add(1);

        // snapshot per-segment counters + retry counts of running downloads
        let snaps: Vec<(String, Vec<u64>, u32)> = {
            let active = shared.active.lock().unwrap();
            active
                .iter()
                .map(|(id, a)| {
                    (
                        id.clone(),
                        a.seg_done
                            .iter()
                            .map(|c| c.load(Ordering::Relaxed))
                            .collect(),
                        a.retries.load(Ordering::Relaxed),
                    )
                })
                .collect()
        };
        let segmented = snaps.iter().any(|(_, segs, _)| !segs.is_empty());

        let mut emits = Vec::new();
        {
            let mut inner = shared.inner.write().unwrap();
            for (id, segs, retries) in &snaps {
                let Some(item) = inner.items.get_mut(id) else {
                    continue;
                };
                item.retry_count = *retries;
                // HLS has no segment counters; run_hls reports its own bytes
                if segs.is_empty() || !matches!(item.status, DownloadStatus::Downloading) {
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

        // re-evaluate off-peak hours (~1×/s) so crossing an edge flips the
        // effective rate, and starts or stops scheduled downloads, on its own
        if ticks.is_multiple_of(4) {
            apply_effective_limit(&shared);
            hold_scheduled(&shared);
        }

        for p in emits {
            emit(&shared, p);
        }

        // checkpoint live segment offsets so a crash resumes near where it left off
        if ticks.is_multiple_of(CHECKPOINT_TICKS) && segmented {
            schedule_persist(&shared);
        }
    }
}

/// Promote queued → running up to the simultaneous cap (oldest first).
/// Scheduled downloads wait while off-peak hours are closed.
fn schedule(shared: &Arc<Shared>) {
    let max = shared.max_simultaneous.load(Ordering::Relaxed) as usize;
    let off_peak = in_off_peak(shared);
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
                    if matches!(it.status, DownloadStatus::Queued) && (off_peak || !it.scheduled) {
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

/// Send scheduled downloads that are running outside off-peak hours back to
/// waiting. They stay queued, so the next off-peak hours start them again.
fn hold_scheduled(shared: &Arc<Shared>) {
    if in_off_peak(shared) {
        return;
    }
    let held: Vec<String> = {
        let mut inner = shared.inner.write().unwrap();
        inner
            .items
            .values_mut()
            .filter(|it| it.scheduled && matches!(it.status, DownloadStatus::Downloading))
            .map(|it| {
                // queued before the cancel, so the run's exit leaves it waiting
                it.status = DownloadStatus::Queued;
                it.speed_bps = 0;
                it.id.clone()
            })
            .collect()
    };
    if held.is_empty() {
        return;
    }
    {
        let active = shared.active.lock().unwrap();
        for id in &held {
            if let Some(a) = active.get(id) {
                a.cancel.cancel();
            }
        }
    }
    for id in &held {
        emit_item(shared, id);
    }
    schedule_persist(shared);
}

/// Push the effective limiter rate: unthrottled during off-peak hours when
/// they run at full speed, otherwise the user's configured `speed_limit`.
fn apply_effective_limit(shared: &Shared) {
    let eff = if shared.off_peak_full_speed.load(Ordering::Relaxed) && in_off_peak(shared) {
        0
    } else {
        shared.speed_limit.load(Ordering::Relaxed)
    };
    shared.limiter.set_rate(eff);
}

/// Whether the current local wall-clock time falls in off-peak hours.
fn in_off_peak(shared: &Shared) -> bool {
    let now = chrono::Local::now();
    window_open(
        now.weekday().num_days_from_monday(),
        now.hour() as u16 * 60 + now.minute() as u16,
        shared.off_peak_start_min.load(Ordering::Relaxed),
        shared.off_peak_end_min.load(Ordering::Relaxed),
        shared.off_peak_days.load(Ordering::Relaxed),
    )
}

/// Whether hours `[start, end)` are open at minute `mins` of `day` (0 = Monday).
/// `start > end` wraps past midnight (e.g. 23:00–07:00); `start == end` never
/// opens. `days` (bit 0 = Monday) picks the days the hours begin on, so with
/// only Friday set, 23:00–07:00 runs from Friday night into Saturday morning.
fn window_open(day: u32, mins: u16, start: u16, end: u16, days: u8) -> bool {
    let begins_on = |d: u32| days & (1 << (d % 7)) != 0;
    if start == end {
        false
    } else if start < end {
        mins >= start && mins < end && begins_on(day)
    } else if mins >= start {
        begins_on(day)
    } else {
        // after midnight: these hours began the day before
        mins < end && begins_on(day + 6)
    }
}

fn start_download(shared: Arc<Shared>, id: String) {
    let cancel = CancellationToken::new();
    let retry = Retry::new(*shared.retry_policy.lock().unwrap());
    {
        let mut active = shared.active.lock().unwrap();
        if active.contains_key(&id) {
            return; // already running
        }
        active.insert(
            id.clone(),
            Active {
                cancel: cancel.clone(),
                seg_done: Vec::new(),
                retries: retry.count.clone(),
            },
        );
    }
    {
        let mut inner = shared.inner.write().unwrap();
        match inner.items.get_mut(&id) {
            Some(it) => {
                it.status = DownloadStatus::Downloading;
                it.retry_count = 0;
            }
            None => {
                shared.active.lock().unwrap().remove(&id);
                return;
            }
        }
    }
    emit_item(&shared, &id);
    let s = shared.clone();
    shared
        .rt
        .spawn(async move { run_download(s, id, cancel, retry).await });
}

async fn run_download(shared: Arc<Shared>, id: String, cancel: CancellationToken, retry: Retry) {
    let result = run_download_inner(&shared, &id, &cancel, &retry).await;

    // temp to delete after releasing the lock (failure that wrote nothing)
    let mut cleanup_temp: Option<PathBuf> = None;
    // dest of a freshly completed file → hash it once the item is visibly done
    let mut completed_dest: Option<PathBuf> = None;
    {
        let mut inner = shared.inner.write().unwrap();
        if let Some(item) = inner.items.get_mut(&id) {
            item.speed_bps = 0;
            item.retry_count = retry.count.load(Ordering::Relaxed);
            if cancel.is_cancelled() {
                if matches!(item.status, DownloadStatus::Downloading) {
                    item.status = DownloadStatus::Paused;
                }
            } else {
                match &result {
                    Ok(()) => {
                        item.status = DownloadStatus::Completed;
                        item.error = None;
                        item.completed_at_ms = Some(chrono::Utc::now().timestamp_millis());
                        if item.total_bytes > 0 {
                            item.downloaded_bytes = item.total_bytes;
                        }
                        for s in &mut item.segments {
                            s.downloaded_bytes = s.end_byte.saturating_sub(s.start_byte);
                        }
                        completed_dest = Some(PathBuf::from(&item.dest_path));
                    }
                    Err(e) => {
                        item.status = DownloadStatus::Error;
                        item.error = Some(describe(e));
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
    schedule_persist(&shared);

    // integrity pass runs after the item already reads Completed, so a slow hash
    // on a large file doesn't stall the UI at "downloading 100%".
    if let Some(dest) = completed_dest {
        compute_checksum(&shared, &id, &dest).await;
        schedule_persist(&shared);
    }
}

/// Hash the finished file (off the async pool) and, if an expected digest was
/// supplied, record whether it matched. Best-effort: a read error just leaves
/// the checksum unset.
async fn compute_checksum(shared: &Arc<Shared>, id: &str, dest: &Path) {
    let expected = {
        let inner = shared.inner.read().unwrap();
        inner
            .items
            .get(id)
            .and_then(|it| it.expected_checksum.clone())
    };
    let algo = match expected.as_deref() {
        Some(e) => HashAlgo::for_expected(e),
        None => HashAlgo::Sha256,
    };
    let path = dest.to_path_buf();
    let computed = match tokio::task::spawn_blocking(move || hash_file(&path, algo)).await {
        Ok(Ok(h)) => h,
        _ => return,
    };

    let mut inner = shared.inner.write().unwrap();
    if let Some(it) = inner.items.get_mut(id) {
        if let Some(exp) = &expected {
            it.checksum_verified = Some(exp.trim().eq_ignore_ascii_case(&computed));
        }
        it.checksum_algo = Some(algo.label().to_string());
        it.checksum = Some(computed);
    }
}

async fn run_download_inner(
    shared: &Arc<Shared>,
    id: &str,
    cancel: &CancellationToken,
    retry: &Retry,
) -> Result<()> {
    let kind = {
        let inner = shared.inner.read().unwrap();
        inner
            .items
            .get(id)
            .map(|it| it.kind)
            .unwrap_or(DownloadKind::Http)
    };
    if kind == DownloadKind::Hls {
        return run_hls(shared, id, cancel, retry).await;
    }

    let (url, dest, base, total, mut segments, planned, kept, connections, headers) = {
        let inner = shared.inner.read().unwrap();
        let it = inner
            .items
            .get(id)
            .ok_or_else(|| anyhow::anyhow!("download {id} not found"))?;
        (
            it.url.clone(),
            PathBuf::from(&it.dest_path),
            base_dir(it),
            it.total_bytes,
            it.segments.clone(),
            !it.segments.is_empty(),
            it.downloaded_bytes > 0,
            it.connections,
            build_headers(&it.headers),
        )
    };
    // with nothing kept, plan afresh: a plan made when the link failed may be
    // sized from an error page
    let is_resume = total > 0 && planned && kept;
    let mut dest = dest;
    let mut temp = temp_path(&dest);

    if is_resume && !tokio::fs::try_exists(&temp).await.unwrap_or(false) {
        // the partial file is gone: start over under the same plan
        for s in &mut segments {
            s.downloaded_bytes = 0;
        }
        prepare_destination(&temp, total).await?;
    }

    if !is_resume {
        let connections = if planned {
            // drop the earlier plan's empty partial file, or this plan's name
            // becomes "file (1).ext"; its segment count may be the error page's
            let _ = tokio::fs::remove_file(&temp).await;
            shared.max_connections.load(Ordering::Relaxed)
        } else {
            connections
        };
        let stall = retry.policy.stall_timeout;
        let plan = retry
            .run(cancel, || async {
                within(stall, fetch_plan(&shared.http, &url, connections, &headers)).await?
            })
            .await?;
        let filename = plan
            .filename
            .as_deref()
            .map(sanitize_filename)
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| filename_of(&dest));
        let ftype = classify(&filename, plan.mime_type.as_deref());

        // route into a category subfolder of the base dir when enabled
        dest = if shared.categorize.load(Ordering::Relaxed) {
            base.join(category_folder(&ftype)).join(&filename)
        } else {
            base.join(&filename)
        };
        if let Some(parent) = dest.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
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
                it.filename = filename_of(&dest);
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
        &headers,
        cancel.clone(),
        retry,
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

// ── HLS pipeline ────────────────────────────────────────────────────────────

/// Download an HLS (M3U8) stream: fetch the playlist (resolving a master to its
/// highest-bitrate variant), then download + AES-128-decrypt media segments and
/// concatenate them in order. Segments commit strictly in submission order, so
/// the temp file is always a clean prefix — resume re-fetches the playlist and
/// continues from `segment_done`. Progress is tracked here directly (the item is
/// not registered with the byte aggregator), so `downloaded_bytes` always equals
/// the committed byte length (the exact resume anchor).
async fn run_hls(
    shared: &Arc<Shared>,
    id: &str,
    cancel: &CancellationToken,
    retry: &Retry,
) -> Result<()> {
    let (playlist_url, dest, root, headers, resume_committed, resume_done, connections, is_first) = {
        let inner = shared.inner.read().unwrap();
        let it = inner
            .items
            .get(id)
            .ok_or_else(|| anyhow::anyhow!("download {id} not found"))?;
        (
            it.url.clone(),
            PathBuf::from(&it.dest_path),
            base_dir(it),
            build_headers(&it.headers),
            it.downloaded_bytes,
            it.segment_done,
            it.connections.max(1) as usize,
            it.segment_total == 0,
        )
    };
    let fetch = Fetcher {
        client: &shared.http,
        headers: &headers,
        retry,
        cancel,
    };

    let base = Url::parse(&playlist_url).map_err(|e| anyhow::anyhow!("bad playlist url: {e}"))?;
    let media = fetch_media_playlist(&fetch, &base).await?;
    if !media.endlist {
        return Err(anyhow::anyhow!("live streams are not supported"));
    }
    if media.segments.is_empty() {
        return Err(anyhow::anyhow!("playlist has no media segments"));
    }
    if media
        .segments
        .iter()
        .any(|s| matches!(&s.key, Some(k) if k.method == KeyMethod::SampleAes))
    {
        return Err(anyhow::anyhow!("SAMPLE-AES encryption is not supported"));
    }

    let segment_total = media.segments.len() as u32;

    // Resolve output path on the first run (correct extension, categorize, dedupe).
    let dest = if is_first {
        let mut d = if media.init.is_some() {
            with_extension(&dest, "mp4")
        } else {
            dest
        };
        if shared.categorize.load(Ordering::Relaxed) {
            d = root.join(category_folder("video")).join(filename_of(&d));
            if let Some(parent) = d.parent() {
                let _ = tokio::fs::create_dir_all(parent).await;
            }
        }
        d = unique_path(&d);
        {
            let mut inner = shared.inner.write().unwrap();
            if let Some(it) = inner.items.get_mut(id) {
                it.dest_path = d.to_string_lossy().to_string();
                it.filename = filename_of(&d);
                it.segment_total = segment_total;
            }
        }
        emit_item(shared, id);
        d
    } else {
        dest
    };
    let temp = temp_path(&dest);

    // Pre-fetch distinct AES-128 keys (usually one for the whole playlist).
    let keys = fetch_keys(&fetch, &media).await?;

    // Open temp: resume truncates to the committed prefix; otherwise start fresh,
    // writing the fMP4 init segment first when present.
    let resume =
        !is_first && resume_done > 0 && tokio::fs::try_exists(&temp).await.unwrap_or(false);
    let (mut writer, mut committed, start_index) = if resume {
        let mut f = OpenOptions::new().write(true).open(&temp).await?;
        f.set_len(resume_committed).await?;
        f.seek(SeekFrom::Start(resume_committed)).await?;
        (
            BufWriter::with_capacity(256 * 1024, f),
            resume_committed,
            resume_done as usize,
        )
    } else {
        let mut f = File::create(&temp).await?;
        let mut committed = 0u64;
        if let Some(init_url) = &media.init {
            let bytes = fetch.bytes(init_url).await?;
            f.write_all(&bytes).await?;
            committed = bytes.len() as u64;
        }
        {
            let mut inner = shared.inner.write().unwrap();
            if let Some(it) = inner.items.get_mut(id) {
                it.segment_done = 0;
                it.downloaded_bytes = committed;
            }
        }
        (BufWriter::with_capacity(256 * 1024, f), committed, 0)
    };

    // Resolve each remaining segment to an owned task (URL + decryption material)
    // so the stream yields owned values — a closure returning a future that borrows
    // its reference argument hits a higher-ranked-lifetime limitation.
    let tasks: Vec<SegTask> = media.segments[start_index..]
        .iter()
        .map(|seg| {
            let key = seg
                .key
                .as_ref()
                .filter(|k| k.method == KeyMethod::Aes128)
                .and_then(|k| k.uri.as_ref())
                .and_then(|u| keys.get(u.as_str()))
                .copied();
            let iv = seg
                .key
                .as_ref()
                .and_then(|k| k.iv)
                .unwrap_or_else(|| hls::derive_iv(seg.seq));
            SegTask {
                url: seg.url.clone(),
                key,
                iv,
            }
        })
        .collect();

    // Bounded-concurrency, order-preserving segment download → ordered append.
    let (fetch, limiter) = (&fetch, &*shared.limiter);
    let mut stream = futures::stream::iter(tasks)
        .map(|t| async move { fetch.segment(limiter, &t).await })
        .buffered(connections);

    let mut done = resume_done;
    let mut last = Instant::now();
    let mut last_bytes = committed;
    let mut since_persist: u32 = 0;

    loop {
        tokio::select! {
            biased;
            // pause: stop pulling; dropping `stream` aborts in-flight segment fetches
            _ = cancel.cancelled() => break,
            next = stream.next() => match next {
                None => break,
                Some(Err(e)) => return Err(e),
                Some(Ok(bytes)) => {
                    writer.write_all(&bytes).await?;
                    writer.flush().await?; // durable prefix before recording the commit
                    committed += bytes.len() as u64;
                    done += 1;

                    let now = Instant::now();
                    let dt = (now - last).as_secs_f64();
                    let emit = dt >= 0.25;
                    {
                        let mut inner = shared.inner.write().unwrap();
                        if let Some(it) = inner.items.get_mut(id) {
                            it.downloaded_bytes = committed;
                            it.segment_done = done;
                            it.total_bytes = committed / done as u64 * segment_total as u64;
                            if emit {
                                let speed = ((committed - last_bytes) as f64 / dt).round() as u64;
                                it.speed_bps = speed;
                                if speed > it.peak_bps {
                                    it.peak_bps = speed;
                                }
                                push_history(&mut it.speed_history, speed);
                            }
                        }
                    }
                    if emit {
                        emit_item(shared, id);
                        last = now;
                        last_bytes = committed;
                        since_persist += 1;
                        if since_persist >= 20 {
                            schedule_persist(shared);
                            since_persist = 0;
                        }
                    }
                }
            },
        }
    }

    if cancel.is_cancelled() {
        return Ok(()); // paused; committed prefix + segment_done persisted for resume
    }

    // all segments consumed → exact final size, then atomic rename
    {
        let mut inner = shared.inner.write().unwrap();
        if let Some(it) = inner.items.get_mut(id) {
            it.total_bytes = committed;
            it.downloaded_bytes = committed;
            it.segment_done = segment_total;
            it.speed_bps = 0;
        }
    }
    finalize(&temp, &dest).await?;
    Ok(())
}

/// Fetch the playlist and resolve a master to its highest-bitrate media playlist.
async fn fetch_media_playlist(fetch: &Fetcher<'_>, url: &Url) -> Result<hls::MediaPlaylist> {
    let text = fetch.text(url).await?;
    match hls::parse(&text, url)? {
        hls::Playlist::Media(m) => Ok(m),
        hls::Playlist::Master(variants) => {
            let best = hls::pick_best(&variants)
                .ok_or_else(|| anyhow::anyhow!("master playlist has no variants"))?;
            let burl = best.url.clone();
            let text = fetch.text(&burl).await?;
            match hls::parse(&text, &burl)? {
                hls::Playlist::Media(m) => Ok(m),
                hls::Playlist::Master(_) => {
                    Err(anyhow::anyhow!("nested master playlists are not supported"))
                }
            }
        }
    }
}

/// Pre-fetch each distinct AES-128 key (16 bytes), mapped by key URI.
async fn fetch_keys(
    fetch: &Fetcher<'_>,
    media: &hls::MediaPlaylist,
) -> Result<HashMap<String, [u8; 16]>> {
    let mut keys = HashMap::new();
    for seg in &media.segments {
        let Some(k) = &seg.key else { continue };
        if k.method != KeyMethod::Aes128 {
            continue;
        }
        let uri = k
            .uri
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("AES-128 key has no URI"))?;
        let id = uri.as_str();
        if keys.contains_key(id) {
            continue;
        }
        let bytes = fetch.bytes(uri).await?;
        if bytes.len() != 16 {
            return Err(anyhow::anyhow!(
                "AES-128 key must be 16 bytes, got {}",
                bytes.len()
            ));
        }
        let mut arr = [0u8; 16];
        arr.copy_from_slice(&bytes);
        keys.insert(id.to_string(), arr);
    }
    Ok(keys)
}

/// One segment's download plan: where to fetch it and how to decrypt it.
struct SegTask {
    url: Url,
    /// AES-128 key bytes; `None` when the segment is unencrypted.
    key: Option<[u8; 16]>,
    iv: [u8; 16],
}

/// HLS requests with the download's headers, retried through transient failures
/// and bounded by the stall timeout.
struct Fetcher<'a> {
    client: &'a Client,
    headers: &'a HeaderMap,
    retry: &'a Retry,
    cancel: &'a CancellationToken,
}

impl Fetcher<'_> {
    async fn text(&self, url: &Url) -> Result<String> {
        self.whole(url, |r| r.text()).await
    }

    async fn bytes(&self, url: &Url) -> Result<bytes::Bytes> {
        self.whole(url, |r| r.bytes()).await
    }

    /// Small body read in one go (playlist, key, init map); the stall timeout
    /// bounds the whole request.
    async fn whole<T, F, Fut>(&self, url: &Url, read: F) -> Result<T>
    where
        F: Fn(reqwest::Response) -> Fut,
        Fut: std::future::Future<Output = reqwest::Result<T>>,
    {
        let stall = self.retry.policy.stall_timeout;
        self.retry
            .run(self.cancel, || async {
                within(stall, async {
                    let resp = self
                        .client
                        .get(url.clone())
                        .headers(self.headers.clone())
                        .send()
                        .await?
                        .error_for_status()?;
                    Ok::<T, anyhow::Error>(read(resp).await?)
                })
                .await?
            })
            .await
    }

    /// Download one media segment fully (rate-limited) and AES-128-decrypt it if
    /// a key is supplied. Cancellation is handled by the caller dropping the stream.
    async fn segment(&self, limiter: &RateLimiter, task: &SegTask) -> Result<Vec<u8>> {
        let stall = self.retry.policy.stall_timeout;
        self.retry
            .run(self.cancel, || async {
                let req = self
                    .client
                    .get(task.url.clone())
                    .headers(self.headers.clone());
                let resp = within(stall, req.send()).await??.error_for_status()?;
                let mut stream = resp.bytes_stream();
                let mut buf = Vec::new();
                while let Some(chunk) = within(stall, stream.next()).await? {
                    let chunk = chunk?;
                    limiter.acquire(chunk.len() as u64).await;
                    buf.extend_from_slice(&chunk);
                }
                match task.key {
                    Some(key) => hls::decrypt_segment(buf, &key, &task.iv),
                    None => Ok(buf),
                }
            })
            .await
    }
}

// ── link refresh ────────────────────────────────────────────────────────────

fn check_refreshable(status: &DownloadStatus) -> Result<()> {
    match status {
        DownloadStatus::Downloading => bail!("Pause the download before changing its link"),
        DownloadStatus::Completed => bail!("This download has already finished"),
        _ => Ok(()),
    }
}

/// Check that `url` serves the file `it` was downloading. Fails fast: this runs
/// while the user waits, so no retries.
async fn verify_same_file(
    shared: &Arc<Shared>,
    it: &DownloadItem,
    url: &str,
    headers: &[(String, String)],
) -> Result<()> {
    let policy = RetryPolicy {
        retries: 0,
        ..*shared.retry_policy.lock().unwrap()
    };
    let headers = build_headers(headers);
    match it.kind {
        DownloadKind::Http => {
            let info = within(
                policy.stall_timeout,
                probe_range(&shared.http, url, &headers),
            )
            .await??;
            // with nothing written there is no file to match; the run re-probes
            if it.downloaded_bytes == 0 {
                return Ok(());
            }
            if info.total_bytes > 0 && info.total_bytes != it.total_bytes {
                bail!(
                    "That link is a different file ({}; this download is {})",
                    fmt_size(info.total_bytes),
                    fmt_size(it.total_bytes)
                );
            }
            if it.segments.len() > 1 && !info.resumable {
                bail!("That link can't resume a partial download: the server ignores byte ranges");
            }
        }
        DownloadKind::Hls => {
            let base = Url::parse(url).map_err(|e| anyhow::anyhow!("Bad playlist link: {e}"))?;
            let (retry, cancel) = (Retry::new(policy), CancellationToken::new());
            let fetch = Fetcher {
                client: &shared.http,
                headers: &headers,
                retry: &retry,
                cancel: &cancel,
            };
            let media = fetch_media_playlist(&fetch, &base).await?;
            let n = media.segments.len() as u32;
            if it.segment_total > 0 && n != it.segment_total {
                bail!(
                    "That playlist has {n} segments; this download has {}",
                    it.segment_total
                );
            }
        }
    }
    Ok(())
}

/// Binary units, as the app shows sizes.
fn fmt_size(n: u64) -> String {
    const UNITS: [&str; 4] = ["KB", "MB", "GB", "TB"];
    if n < 1024 {
        return format!("{n} B");
    }
    let mut v = n as f64 / 1024.0;
    let mut i = 0;
    while v >= 1024.0 && i < UNITS.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    format!("{v:.1} {}", UNITS[i])
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

// ── persistence ───────────────────────────────────────────────────────────────

/// Persist the current list off the calling thread; no-op without a store path.
fn schedule_persist(shared: &Arc<Shared>) {
    if shared.store.is_none() {
        return;
    }
    let s = shared.clone();
    shared.rt.spawn_blocking(move || persist_now(&s));
}

/// Snapshot the list under the persist lock and write it atomically. Snapshotting
/// inside the lock means the last writer always captures the freshest state.
fn persist_now(shared: &Shared) {
    let Some(path) = shared.store.as_ref() else {
        return;
    };
    let _guard = shared.persist_lock.lock().unwrap();
    let items = {
        let inner = shared.inner.read().unwrap();
        collect_for_persist(&inner)
    };
    let _ = store::save(path, &items);
}

/// Items to persist, in display order, capping completed history to the most
/// recent `HISTORY_CAP` (order is newest-first, so the oldest are dropped).
fn collect_for_persist(inner: &Inner) -> Vec<DownloadItem> {
    let mut completed = 0usize;
    let mut out = Vec::with_capacity(inner.order.len());
    for id in &inner.order {
        let Some(it) = inner.items.get(id) else {
            continue;
        };
        if matches!(it.status, DownloadStatus::Completed) {
            if completed >= HISTORY_CAP {
                continue;
            }
            completed += 1;
        }
        out.push(it.clone());
    }
    out
}

/// Load persisted items, normalising transient state: interrupted downloads
/// (`Downloading`) become `Paused` so the user resumes them deliberately, or
/// `Queued` when scheduled, since those run unattended. Live speed is cleared.
/// Display order follows the persisted sequence.
fn load_items(path: &Path) -> Inner {
    let mut items = HashMap::new();
    let mut order = Vec::new();
    for mut it in store::load(path) {
        if items.contains_key(&it.id) {
            continue;
        }
        it.speed_bps = 0;
        if matches!(it.status, DownloadStatus::Downloading) {
            it.status = if it.scheduled {
                DownloadStatus::Queued
            } else {
                DownloadStatus::Paused
            };
        }
        order.push(it.id.clone());
        items.insert(it.id.clone(), it);
    }
    Inner { items, order }
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

fn host_of(url: &str) -> String {
    url.split('/').nth(2).unwrap_or("").to_string()
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

/// Initial filename for an HLS download: the page title (sanitised) or the
/// playlist's basename minus `.m3u8`. Extension is a `.ts` placeholder; `run_hls`
/// corrects it to `.ts`/`.mp4` once the segment type is known.
fn hls_filename(url: &str, title: Option<&str>) -> String {
    let base = title
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .map(sanitize_filename)
        .unwrap_or_else(|| {
            let stem = filename_from_url(url);
            stem.strip_suffix(".m3u8").unwrap_or(&stem).to_string()
        });
    let base = if base.is_empty() {
        "stream".to_string()
    } else {
        base
    };
    format!("{base}.ts")
}

/// Strip characters illegal in Windows filenames.
fn sanitize_filename(s: &str) -> String {
    s.chars()
        .map(|c| if "\\/:*?\"<>|".contains(c) { '_' } else { c })
        .collect::<String>()
        .trim()
        .to_string()
}

fn with_extension(path: &Path, ext: &str) -> PathBuf {
    let mut p = path.to_path_buf();
    p.set_extension(ext);
    p
}

/// First free path for `dest`, appending ` (n)` before the extension. Also
/// avoids names whose temp file is already in flight.
fn unique_path(dest: &Path) -> PathBuf {
    if !dest.exists() && !temp_path(dest).exists() {
        return dest.to_path_buf();
    }
    let parent = dest.parent().unwrap_or_else(|| Path::new("."));
    let stem = dest
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("download");
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

/// Folder the download was added to: category subfolders and re-plans start
/// here, so a second plan doesn't nest inside the first one's category folder.
fn base_dir(it: &DownloadItem) -> PathBuf {
    if !it.dest_dir.is_empty() {
        return PathBuf::from(&it.dest_dir);
    }
    Path::new(&it.dest_path)
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."))
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

#[cfg(test)]
mod tests {
    use super::{window_open, EVERY_DAY};

    const fn hm(h: u16, m: u16) -> u16 {
        h * 60 + m
    }

    const MON: u32 = 0;
    const FRI: u32 = 4;
    const SAT: u32 = 5;
    const SUN: u32 = 6;

    /// Open on every day of the week, with every day picked.
    fn open(mins: u16, start: u16, end: u16) -> bool {
        (0..7).all(|d| window_open(d, mins, start, end, EVERY_DAY))
    }

    #[test]
    fn window_wrapping_midnight() {
        let (start, end) = (hm(23, 0), hm(7, 0));
        assert!(open(hm(0, 0), start, end));
        assert!(open(hm(6, 59), start, end));
        assert!(open(hm(23, 0), start, end));
        assert!(!open(hm(7, 0), start, end)); // end is exclusive
        assert!(!open(hm(12, 0), start, end));
        assert!(!open(hm(22, 59), start, end));
    }

    #[test]
    fn window_same_day() {
        let (start, end) = (hm(1, 0), hm(5, 0));
        assert!(open(hm(2, 0), start, end));
        assert!(open(hm(1, 0), start, end));
        assert!(!open(hm(0, 0), start, end));
        assert!(!open(hm(5, 0), start, end)); // end is exclusive
    }

    #[test]
    fn empty_window_is_never_active() {
        assert!(!open(hm(3, 0), hm(5, 0), hm(5, 0)));
    }

    #[test]
    fn days_pick_when_the_hours_begin() {
        let fri = 1 << FRI;
        let (start, end) = (hm(23, 0), hm(7, 0));
        assert!(window_open(FRI, hm(23, 30), start, end, fri));
        // Friday night carries on into Saturday morning
        assert!(window_open(SAT, hm(6, 0), start, end, fri));
        assert!(!window_open(SAT, hm(23, 30), start, end, fri));
        // Friday's early hours belong to Thursday night
        assert!(!window_open(FRI, hm(6, 0), start, end, fri));
    }

    #[test]
    fn sunday_night_runs_into_monday() {
        let sun = 1 << SUN;
        let (start, end) = (hm(22, 0), hm(2, 0));
        assert!(window_open(MON, hm(1, 0), start, end, sun));
        assert!(!window_open(SUN, hm(1, 0), start, end, sun));
    }

    #[test]
    fn same_day_hours_follow_the_days() {
        let weekend = (1 << SAT) | (1 << SUN);
        let (start, end) = (hm(9, 0), hm(17, 0));
        assert!(window_open(SAT, hm(12, 0), start, end, weekend));
        assert!(!window_open(MON, hm(12, 0), start, end, weekend));
        assert!(!window_open(SAT, hm(12, 0), start, end, 0));
    }
}
