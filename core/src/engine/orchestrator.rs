use anyhow::Result;
use reqwest::header::HeaderMap;
use reqwest::Client;
use std::future::Future;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio_util::sync::CancellationToken;

use crate::engine::download::SegmentInfo;
use crate::engine::retry::{is_transient, GaveUp, Retry};
use crate::engine::segment::split_into_segments;
use crate::engine::throttle::RateLimiter;
use crate::engine::worker::{download_segment, Span};
use crate::protocols::http::probe;

/// Probe result + segment layout.
#[derive(Debug, Clone)]
pub struct Plan {
    pub total: u64,
    pub resumable: bool,
    pub mime_type: Option<String>,
    pub filename: Option<String>,
    pub segments: Vec<SegmentInfo>,
}

/// Probe and decide segments. Multi-segment only with byte ranges + known
/// length; otherwise a single open-ended stream (`end_byte == 0` if unknown).
pub async fn fetch_plan(
    client: &Client,
    url: &str,
    connections: u8,
    headers: &HeaderMap,
) -> Result<Plan> {
    let info = probe(client, url, headers).await?;
    let total = info.total_bytes;
    let multi = info.resumable && total > 0;
    let segments = if multi {
        split_into_segments(total, connections.max(1))
    } else {
        vec![SegmentInfo {
            index: 0,
            start_byte: 0,
            end_byte: total,
            downloaded_bytes: 0,
            active: true,
        }]
    };
    Ok(Plan {
        total,
        resumable: info.resumable,
        mime_type: info.mime_type,
        filename: info.filename,
        segments,
    })
}

/// Run all segments in parallel into the preallocated file. A segment that hits a
/// transient failure reconnects from its own offset; a permanent failure, or one
/// that outlasts the retry budget, cancels the rest and is returned. `cancel`
/// (pause) stops them cleanly (Ok).
#[allow(clippy::too_many_arguments)]
pub async fn run_segments(
    client: &Client,
    limiter: Arc<RateLimiter>,
    url: &str,
    dest: &Path,
    segments: &[SegmentInfo],
    counters: &[Arc<AtomicU64>],
    headers: &HeaderMap,
    cancel: CancellationToken,
    retry: &Retry,
) -> Result<()> {
    // Child token: an error tears down siblings without flipping the caller's
    // pause token (caller uses it to tell pause from failure). Parent cancel
    // still propagates to children.
    let group = cancel.child_token();
    // segments tile [0, total); a single open-ended segment has end_byte 0
    let total = segments.last().map_or(0, |s| s.end_byte);
    let all: Arc<[Arc<AtomicU64>]> = counters.into();
    // first root failure; errors seen after the group is cancelled are fallout
    let failure: Arc<Mutex<Option<anyhow::Error>>> = Arc::new(Mutex::new(None));

    let mut handles = Vec::with_capacity(segments.len());
    for (i, seg) in segments.iter().enumerate() {
        let client = client.clone();
        let limiter = limiter.clone();
        let url = url.to_string();
        let dest = dest.to_path_buf();
        let token = group.clone();
        let headers = headers.clone();
        let all = all.clone();
        let retry = retry.clone();
        let failure = failure.clone();
        let span = Span {
            start: seg.start_byte,
            end: seg.end_byte,
            total,
        };
        handles.push(tokio::spawn(async move {
            let stall = retry.policy.stall_timeout;
            let result = retry_segment(&retry, &token, &all, i, || {
                download_segment(
                    &client, &limiter, &url, &dest, span, &headers, &all[i], &token, stall,
                )
            })
            .await;
            if let Err(e) = result {
                if !token.is_cancelled() {
                    failure.lock().unwrap().get_or_insert(e);
                }
                token.cancel(); // siblings only
            }
        }));
    }

    for h in handles {
        if let Err(join) = h.await {
            failure
                .lock()
                .unwrap()
                .get_or_insert_with(|| anyhow::anyhow!("segment task failed: {join}"));
            group.cancel();
        }
    }

    let first = failure.lock().unwrap().take();
    first.map_or(Ok(()), Err)
}

/// Drive one segment through transient failures. Reconnects at once after an
/// attempt that made progress, otherwise backs off. Gives up after `retries`
/// failures in a row during which the whole download made no progress, so a host
/// that caps connections keeps the extra segments waiting instead of failing a
/// download that is still moving.
async fn retry_segment<F, Fut>(
    retry: &Retry,
    cancel: &CancellationToken,
    all: &[Arc<AtomicU64>],
    i: usize,
    mut attempt: F,
) -> Result<()>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<()>>,
{
    let sum = || all.iter().map(|c| c.load(Ordering::Relaxed)).sum::<u64>();
    let (mut streak, mut idle) = (0u32, 0u32);
    let mut last_sum = sum();
    loop {
        let mine = all[i].load(Ordering::Relaxed);
        let e = match attempt().await {
            Ok(()) => return Ok(()),
            Err(e) => e,
        };
        if !is_transient(&e) || cancel.is_cancelled() || retry.policy.retries == 0 {
            return Err(e);
        }
        if all[i].load(Ordering::Relaxed) != mine {
            streak = 0;
        }
        streak += 1;
        let now = sum();
        idle = if now == last_sum { idle + 1 } else { 0 };
        last_sum = now;
        if idle > retry.policy.retries {
            return Err(e.context(GaveUp(idle)));
        }
        if !retry.wait(streak, cancel).await {
            return Err(e);
        }
    }
}
