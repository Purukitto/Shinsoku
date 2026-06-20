use anyhow::Result;
use futures::StreamExt;
use reqwest::header::HeaderMap;
use reqwest::Client;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio_util::sync::CancellationToken;

use crate::engine::throttle::RateLimiter;
use crate::storage::partial::SegmentWriter;

/// Download one byte range into its slot of the preallocated file. Resumes from
/// `start + already`, rate-limited, bumps `done`. Returns Ok early on `cancel`
/// (partial stays on disk).
#[allow(clippy::too_many_arguments)]
pub async fn download_segment(
    client: &Client,
    limiter: &RateLimiter,
    url: &str,
    dest: &Path,
    start: u64,
    end: u64,
    already: u64,
    headers: &HeaderMap,
    done: Arc<AtomicU64>,
    cancel: CancellationToken,
) -> Result<()> {
    let from = start + already;
    if end != 0 && from >= end {
        return Ok(()); // segment already complete
    }

    let mut writer = SegmentWriter::open(dest, from).await?;

    let mut req = client.get(url).headers(headers.clone());
    // end == 0: unknown length, fetch open-ended
    if end != 0 {
        req = req.header("Range", format!("bytes={}-{}", from, end - 1));
    } else if from > 0 {
        req = req.header("Range", format!("bytes={}-", from));
    }
    let resp = req.send().await?.error_for_status()?;

    let mut stream = resp.bytes_stream();
    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => break,
            next = stream.next() => match next {
                Some(chunk) => {
                    let chunk = chunk?;
                    limiter.acquire(chunk.len() as u64).await;
                    writer.write(&chunk).await?;
                    done.fetch_add(chunk.len() as u64, Ordering::Relaxed);
                }
                None => break,
            },
        }
    }

    writer.finish().await?;
    Ok(())
}
