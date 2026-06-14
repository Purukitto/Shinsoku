//! End-to-end engine tests against a hermetic, range-capable HTTP server (no
//! network). Exercises the orchestrator the same way the queue manager does:
//! probe → preallocate → parallel ranged segments → finalize.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

use shinsoku_core::engine::orchestrator::{fetch_plan, run_segments};
use shinsoku_core::engine::throttle::RateLimiter;
use shinsoku_core::protocols::http::build_client;
use shinsoku_core::storage::assembler::{finalize, temp_path};
use shinsoku_core::storage::partial::prepare_destination;

/// Serves `data` over HTTP/1.1 with `Accept-Ranges: bytes`, honouring `Range`
/// on GET (206) and answering HEAD with the size. One request per connection
/// (`Connection: close`) keeps the parser trivial.
async fn serve(data: Arc<Vec<u8>>) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let (mut sock, _) = match listener.accept().await {
                Ok(c) => c,
                Err(_) => continue,
            };
            let data = data.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                if n == 0 {
                    return;
                }
                let req = String::from_utf8_lossy(&buf[..n]);
                let is_head = req.starts_with("HEAD");
                let total = data.len();

                let range = req
                    .lines()
                    .find(|l| l.to_ascii_lowercase().starts_with("range:"))
                    .and_then(|l| l.split('=').nth(1))
                    .map(|s| s.trim().to_string());

                let (header, body): (String, &[u8]) = if let Some(spec) = range {
                    let mut parts = spec.split('-');
                    let start: usize = parts.next().unwrap_or("0").trim().parse().unwrap_or(0);
                    let end_s = parts.next().unwrap_or("").trim();
                    let end = if end_s.is_empty() {
                        total - 1
                    } else {
                        end_s.parse::<usize>().unwrap_or(total - 1).min(total - 1)
                    };
                    let slice = &data[start..=end];
                    (
                        format!(
                            "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\n\
                             Content-Range: bytes {}-{}/{}\r\nAccept-Ranges: bytes\r\n\
                             Connection: close\r\n\r\n",
                            slice.len(),
                            start,
                            end,
                            total
                        ),
                        slice,
                    )
                } else {
                    (
                        format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\n\
                             Content-Type: application/octet-stream\r\nConnection: close\r\n\r\n",
                            total
                        ),
                        &data[..],
                    )
                };

                let _ = sock.write_all(header.as_bytes()).await;
                if !is_head {
                    let _ = sock.write_all(body).await;
                }
                let _ = sock.flush().await;
            });
        }
    });
    addr
}

fn make_data(len: usize) -> Vec<u8> {
    (0..len).map(|i| (i % 256) as u8).collect()
}

fn tmp_dest(tag: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("shinsoku_test_{tag}_{nanos}.bin"))
}

#[tokio::test]
async fn multi_segment_download_matches_source() {
    let data = Arc::new(make_data(1_000_003)); // not divisible by segment count
    let addr = serve(data.clone()).await;
    let url = format!("http://{addr}/blob.bin");

    let client = build_client();
    let plan = fetch_plan(&client, &url, 8).await.unwrap();
    assert_eq!(plan.total, data.len() as u64);
    assert!(plan.resumable, "server advertises byte ranges");
    assert_eq!(plan.segments.len(), 8);
    // segments must tile [0, total) contiguously with no gaps/overlaps
    assert_eq!(plan.segments[0].start_byte, 0);
    assert_eq!(plan.segments.last().unwrap().end_byte, plan.total);
    for w in plan.segments.windows(2) {
        assert_eq!(w[0].end_byte, w[1].start_byte);
    }

    let dest = tmp_dest("multi");
    let temp = temp_path(&dest);
    prepare_destination(&temp, plan.total).await.unwrap();

    let counters: Vec<Arc<AtomicU64>> = plan
        .segments
        .iter()
        .map(|_| Arc::new(AtomicU64::new(0)))
        .collect();
    let limiter = Arc::new(RateLimiter::new(0));
    run_segments(
        &client,
        limiter,
        &url,
        &temp,
        &plan.segments,
        &counters,
        CancellationToken::new(),
    )
    .await
    .unwrap();
    finalize(&temp, &dest).await.unwrap();

    let written = tokio::fs::read(&dest).await.unwrap();
    assert_eq!(written.len(), data.len());
    assert!(written == *data, "downloaded bytes differ from source");

    let _ = tokio::fs::remove_file(&dest).await;
}

#[tokio::test]
async fn resume_from_partial_completes_correctly() {
    let data = Arc::new(make_data(500_000));
    let addr = serve(data.clone()).await;
    let url = format!("http://{addr}/blob.bin");

    let client = build_client();
    let mut plan = fetch_plan(&client, &url, 4).await.unwrap();

    let dest = tmp_dest("resume");
    let temp = temp_path(&dest);
    prepare_destination(&temp, plan.total).await.unwrap();

    // Simulate a download that was paused after each segment got partway:
    // write the first half of every segment to disk and record the offset.
    use std::io::{Seek, SeekFrom, Write};
    let mut f = std::fs::OpenOptions::new().write(true).open(&temp).unwrap();
    let mut counters = Vec::new();
    for seg in &mut plan.segments {
        let range = (seg.end_byte - seg.start_byte) as usize;
        let half = range / 2;
        let start = seg.start_byte as usize;
        f.seek(SeekFrom::Start(seg.start_byte)).unwrap();
        f.write_all(&data[start..start + half]).unwrap();
        seg.downloaded_bytes = half as u64;
        counters.push(Arc::new(AtomicU64::new(half as u64)));
    }
    drop(f);

    let limiter = Arc::new(RateLimiter::new(0));
    run_segments(
        &client,
        limiter,
        &url,
        &temp,
        &plan.segments,
        &counters,
        CancellationToken::new(),
    )
    .await
    .unwrap();
    finalize(&temp, &dest).await.unwrap();

    let written = tokio::fs::read(&dest).await.unwrap();
    assert!(written == *data, "resumed download differs from source");

    let _ = tokio::fs::remove_file(&dest).await;
}
