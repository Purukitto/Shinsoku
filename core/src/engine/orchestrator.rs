use anyhow::Result;
use reqwest::header::HeaderMap;
use reqwest::Client;
use std::path::Path;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use tokio_util::sync::CancellationToken;

use crate::engine::download::SegmentInfo;
use crate::engine::segment::split_into_segments;
use crate::engine::throttle::RateLimiter;
use crate::engine::worker::download_segment;
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

/// Run all segments in parallel into the preallocated file. First error cancels
/// the rest and returns Err; `cancel` (pause) stops them cleanly (Ok).
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
) -> Result<()> {
    // Child token: an error tears down siblings without flipping the caller's
    // pause token (caller uses it to tell pause from failure). Parent cancel
    // still propagates to children.
    let group = cancel.child_token();

    let mut handles = Vec::with_capacity(segments.len());
    for (i, seg) in segments.iter().enumerate() {
        let client = client.clone();
        let limiter = limiter.clone();
        let url = url.to_string();
        let dest = dest.to_path_buf();
        let done = counters[i].clone();
        let token = group.clone();
        let headers = headers.clone();
        let (start, end, already) = (seg.start_byte, seg.end_byte, seg.downloaded_bytes);
        handles.push(tokio::spawn(async move {
            download_segment(
                &client, &limiter, &url, &dest, start, end, already, &headers, done, token,
            )
            .await
        }));
    }

    let mut first_err: Option<anyhow::Error> = None;
    for h in handles {
        match h.await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                if first_err.is_none() {
                    first_err = Some(e);
                }
                group.cancel(); // siblings only
            }
            Err(join) => {
                if first_err.is_none() {
                    first_err = Some(anyhow::anyhow!("segment task failed: {join}"));
                }
                group.cancel();
            }
        }
    }

    match first_err {
        Some(e) => Err(e),
        None => Ok(()),
    }
}
