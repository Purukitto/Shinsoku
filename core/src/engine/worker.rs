use anyhow::Result;
use futures::StreamExt;
use reqwest::header::{HeaderMap, CONTENT_RANGE, RANGE};
use reqwest::{Client, Response, StatusCode};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio_util::sync::CancellationToken;

use crate::engine::retry::{within, FetchError};
use crate::engine::throttle::RateLimiter;
use crate::storage::partial::SegmentWriter;

/// One segment's slot: `[start, end)` of a file `total` bytes long. `end == 0`
/// is a single open-ended stream of unknown length; `total == 0` is unknown.
#[derive(Debug, Clone, Copy)]
pub struct Span {
    pub start: u64,
    pub end: u64,
    pub total: u64,
}

/// Download one byte range into its slot of the preallocated file, continuing
/// from `start + done`. Rate-limited; never writes past `end`; `done` counts
/// only flushed bytes. Returns Ok early on `cancel` (partial stays on disk).
#[allow(clippy::too_many_arguments)]
pub async fn download_segment(
    client: &Client,
    limiter: &RateLimiter,
    url: &str,
    dest: &Path,
    span: Span,
    headers: &HeaderMap,
    done: &AtomicU64,
    cancel: &CancellationToken,
    stall: Duration,
) -> Result<()> {
    let Span { start, end, total } = span;
    let from = start + done.load(Ordering::Relaxed);
    if end != 0 && from >= end {
        return Ok(()); // segment already complete
    }

    let mut req = client.get(url).headers(headers.clone());
    // end == 0: unknown length, fetch open-ended
    if end != 0 {
        req = req.header(RANGE, format!("bytes={}-{}", from, end - 1));
    } else if from > 0 {
        req = req.header(RANGE, format!("bytes={}-", from));
    }
    let resp = tokio::select! {
        biased;
        _ = cancel.cancelled() => return Ok(()),
        r = within(stall, req.send()) => r??.error_for_status()?,
    };

    let mut pos = from;
    if end != 0 || from > 0 {
        if resp.status() == StatusCode::PARTIAL_CONTENT {
            check_content_range(&resp, from, total)?;
        } else if start == 0 {
            // whole body instead of the range: usable from byte 0, so restart there
            if total != 0 && resp.content_length().is_some_and(|n| n != total) {
                return Err(FetchError::Changed.into());
            }
            pos = 0;
            done.store(0, Ordering::Relaxed);
        } else {
            return Err(FetchError::RangeIgnored.into());
        }
    }

    let mut writer = SegmentWriter::open(dest, pos, done).await?;
    let mut stream = resp.bytes_stream();
    let streamed: Result<()> = async {
        loop {
            let next = tokio::select! {
                biased;
                _ = cancel.cancelled() => return Ok(()),
                n = within(stall, stream.next()) => n?,
            };
            let Some(chunk) = next else {
                if end != 0 && pos < end {
                    return Err(FetchError::Truncated.into());
                }
                return Ok(());
            };
            let chunk = chunk?;
            let take = match end {
                0 => chunk.len(),
                _ => chunk
                    .len()
                    .min(usize::try_from(end - pos).unwrap_or(usize::MAX)),
            };
            limiter.acquire(take as u64).await;
            writer.write(&chunk[..take]).await?;
            pos += take as u64;
            if end != 0 && pos >= end {
                return Ok(());
            }
        }
    }
    .await;

    // flush what arrived even when the stream failed, so `done` matches the disk
    writer.finish().await?;
    streamed
}

/// A 206 must start where it was asked to and, when it states a size, match the
/// size the download was planned for.
fn check_content_range(resp: &Response, from: u64, total: u64) -> Result<()> {
    let Some(v) = resp
        .headers()
        .get(CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
    else {
        return Ok(());
    };
    // "bytes 100-199/1000"; size may be "*"
    let spec = v.trim().trim_start_matches("bytes").trim();
    let (range, size) = spec.split_once('/').unwrap_or((spec, "*"));
    let first = range
        .split('-')
        .next()
        .and_then(|s| s.trim().parse::<u64>().ok());
    if first.is_some_and(|f| f != from) {
        return Err(FetchError::WrongRange.into());
    }
    if let Ok(size) = size.trim().parse::<u64>() {
        if total != 0 && size != total {
            return Err(FetchError::Changed.into());
        }
    }
    Ok(())
}
