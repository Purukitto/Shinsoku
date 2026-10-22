//! End-to-end engine tests against a hermetic, range-capable HTTP server (no
//! network). Exercises the orchestrator the same way the queue manager does:
//! probe → preallocate → parallel ranged segments → finalize.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

use shinsoku_core::capture;
use shinsoku_core::engine::download::DownloadStatus;
use shinsoku_core::engine::orchestrator::{fetch_plan, run_segments, Plan};
use shinsoku_core::engine::retry::{describe, FetchError, Retry, RetryPolicy};
use shinsoku_core::engine::throttle::RateLimiter;
use shinsoku_core::protocols::http::{build_client, build_headers};
use shinsoku_core::queue::manager::QueueManager;
use shinsoku_core::storage::assembler::{finalize, temp_path};
use shinsoku_core::storage::partial::prepare_destination;

/// Serves `data` over HTTP/1.1 with `Accept-Ranges: bytes`, honouring `Range`
/// on GET (206) and answering HEAD with the size. One request per connection
/// (`Connection: close`) keeps the parser trivial.
async fn serve(data: Arc<Vec<u8>>) -> SocketAddr {
    serve_faulty(data, Arc::new(|_| Fault::None)).await.0
}

/// How a GET misbehaves.
#[derive(Clone, Copy)]
enum Fault {
    None,
    /// Send the headers and this many body bytes, then hang up.
    DropAfter(usize),
    /// Send the headers and this many body bytes, then go silent.
    StallAfter(usize),
    /// Answer with this status and no body.
    Status(u16),
    /// Answer 200 with the whole file even when a range was asked for.
    IgnoreRange,
    /// Answer the range, but report the file as this many bytes long.
    ClaimTotal(usize),
}

/// Picks a GET's fault from the start of the range it asked for.
type FaultFn = Arc<dyn Fn(usize) -> Fault + Send + Sync>;

/// `(start, end)`, end inclusive, of a request's `Range: bytes=…` header.
fn parse_range(req: &str, total: usize) -> Option<(usize, usize)> {
    let spec = req
        .lines()
        .find(|l| l.to_ascii_lowercase().starts_with("range:"))
        .and_then(|l| l.split('=').nth(1))?;
    let mut parts = spec.trim().split('-');
    let start: usize = parts.next().unwrap_or("0").trim().parse().unwrap_or(0);
    let end_s = parts.next().unwrap_or("").trim();
    let end = if end_s.is_empty() {
        total - 1
    } else {
        end_s.parse::<usize>().unwrap_or(total - 1).min(total - 1)
    };
    Some((start, end))
}

/// Like `serve`, with `fault` choosing how each GET misbehaves (HEAD always
/// answers normally). Also returns a count of GETs received.
async fn serve_faulty(data: Arc<Vec<u8>>, fault: FaultFn) -> (SocketAddr, Arc<AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let gets = Arc::new(AtomicUsize::new(0));
    let counter = gets.clone();
    tokio::spawn(async move {
        loop {
            let (mut sock, _) = match listener.accept().await {
                Ok(c) => c,
                Err(_) => continue,
            };
            let data = data.clone();
            let fault = fault.clone();
            let gets = counter.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                if n == 0 {
                    return;
                }
                let req = String::from_utf8_lossy(&buf[..n]);
                let is_head = req.starts_with("HEAD");
                let total = data.len();
                let range = parse_range(&req, total);
                let fault = if is_head {
                    Fault::None
                } else {
                    gets.fetch_add(1, Ordering::SeqCst);
                    fault(range.map_or(0, |r| r.0))
                };

                if let Fault::Status(code) = fault {
                    let head = format!(
                        "HTTP/1.1 {code} Fault\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    );
                    let _ = sock.write_all(head.as_bytes()).await;
                    return;
                }
                let (header, body): (String, &[u8]) = match range {
                    Some((start, end)) if !matches!(fault, Fault::IgnoreRange) => {
                        let claimed = match fault {
                            Fault::ClaimTotal(t) => t,
                            _ => total,
                        };
                        (
                            format!(
                                "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\n\
                                 Content-Range: bytes {start}-{end}/{claimed}\r\n\
                                 Accept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                                end - start + 1
                            ),
                            &data[start..=end],
                        )
                    }
                    _ => (
                        format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {total}\r\nAccept-Ranges: bytes\r\n\
                             Content-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
                        ),
                        &data[..],
                    ),
                };

                let _ = sock.write_all(header.as_bytes()).await;
                if is_head {
                    let _ = sock.flush().await;
                    return;
                }
                match fault {
                    Fault::DropAfter(k) => {
                        let _ = sock.write_all(&body[..k.min(body.len())]).await;
                    }
                    Fault::StallAfter(k) => {
                        let _ = sock.write_all(&body[..k.min(body.len())]).await;
                        let _ = sock.flush().await;
                        tokio::time::sleep(Duration::from_secs(30)).await;
                    }
                    _ => {
                        let _ = sock.write_all(body).await;
                    }
                }
                let _ = sock.flush().await;
            });
        }
    });
    (addr, gets)
}

/// Serves at most `cap` GET bodies at once, each streamed slowly in slices; a
/// GET over the cap gets 503, like a host that limits connections per client.
async fn serve_capped(data: Arc<Vec<u8>>, cap: usize) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let busy = Arc::new(AtomicUsize::new(0));
    tokio::spawn(async move {
        loop {
            let (mut sock, _) = match listener.accept().await {
                Ok(c) => c,
                Err(_) => continue,
            };
            // each slice goes out as written, not held back by Nagle
            let _ = sock.set_nodelay(true);
            let data = data.clone();
            let busy = busy.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                if n == 0 {
                    return;
                }
                let req = String::from_utf8_lossy(&buf[..n]);
                let total = data.len();
                if req.starts_with("HEAD") {
                    let head = format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {total}\r\nAccept-Ranges: bytes\r\n\
                         Connection: close\r\n\r\n"
                    );
                    let _ = sock.write_all(head.as_bytes()).await;
                    return;
                }
                if busy.fetch_add(1, Ordering::SeqCst) >= cap {
                    busy.fetch_sub(1, Ordering::SeqCst);
                    let _ = sock
                        .write_all(
                            b"HTTP/1.1 503 Busy\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        )
                        .await;
                    return;
                }
                let (start, end) = parse_range(&req, total).unwrap_or((0, total - 1));
                let body = &data[start..=end];
                let head = format!(
                    "HTTP/1.1 206 Partial Content\r\nContent-Length: {}\r\n\
                     Content-Range: bytes {start}-{end}/{total}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = sock.write_all(head.as_bytes()).await;
                for slice in body.chunks(body.len().div_ceil(20).max(1)) {
                    let _ = sock.write_all(slice).await;
                    let _ = sock.flush().await;
                    tokio::time::sleep(Duration::from_millis(30)).await;
                }
                busy.fetch_sub(1, Ordering::SeqCst);
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
    let plan = fetch_plan(&client, &url, 8, &build_headers(&[]))
        .await
        .unwrap();
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
        &build_headers(&[]),
        CancellationToken::new(),
        &Retry::new(RetryPolicy::default()),
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
    let mut plan = fetch_plan(&client, &url, 4, &build_headers(&[]))
        .await
        .unwrap();

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
        &build_headers(&[]),
        CancellationToken::new(),
        &Retry::new(RetryPolicy::default()),
    )
    .await
    .unwrap();
    finalize(&temp, &dest).await.unwrap();

    let written = tokio::fs::read(&dest).await.unwrap();
    assert!(written == *data, "resumed download differs from source");

    let _ = tokio::fs::remove_file(&dest).await;
}

/// Per-download headers reach the wire: a server that 403s unless the segment
/// GET carries `Cookie: session=secret` still produces a byte-perfect file.
#[tokio::test]
async fn forwards_custom_headers() {
    let data = Arc::new(make_data(300_000));
    let addr = serve_requiring_cookie(data.clone(), "session=secret").await;
    let url = format!("http://{addr}/blob.bin");

    let client = build_client();
    let headers = build_headers(&[("Cookie".into(), "session=secret".into())]);
    let plan = fetch_plan(&client, &url, 4, &headers).await.unwrap();
    assert_eq!(plan.total, data.len() as u64);

    let dest = tmp_dest("headers");
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
        &headers,
        CancellationToken::new(),
        &Retry::new(RetryPolicy::default()),
    )
    .await
    .unwrap();
    finalize(&temp, &dest).await.unwrap();

    let written = tokio::fs::read(&dest).await.unwrap();
    assert!(
        written == *data,
        "header-gated download differs from source"
    );

    let _ = tokio::fs::remove_file(&dest).await;
}

// ── HLS pipeline ────────────────────────────────────────────────────────────

/// Serves a fixed path→bytes map (200 + Content-Length, one request per
/// connection). Used to stand up an HLS playlist + its segments/key.
/// `delay_ms` stalls each response so a download can be paused mid-stream;
/// paths in `fail_once` answer 503 the first time they are requested.
async fn serve_map(
    routes: HashMap<String, Vec<u8>>,
    delay_ms: u64,
    fail_once: &[&str],
) -> SocketAddr {
    let routes = Arc::new(routes);
    let failing: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(
        fail_once.iter().map(|p| p.to_string()).collect(),
    ));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let (mut sock, _) = match listener.accept().await {
                Ok(c) => c,
                Err(_) => continue,
            };
            let routes = routes.clone();
            let failing = failing.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                if n == 0 {
                    return;
                }
                let req = String::from_utf8_lossy(&buf[..n]);
                let is_head = req.starts_with("HEAD");
                let path = req
                    .lines()
                    .next()
                    .and_then(|l| l.split_whitespace().nth(1))
                    .map(|p| p.split('?').next().unwrap_or(p))
                    .unwrap_or("/")
                    .to_string();
                if delay_ms > 0 {
                    tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
                }
                let fail = {
                    let mut f = failing.lock().unwrap();
                    let hit = f.iter().position(|p| *p == path);
                    hit.map(|i| f.remove(i)).is_some()
                };
                if fail {
                    let _ = sock
                        .write_all(
                            b"HTTP/1.1 503 Busy\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        )
                        .await;
                    return;
                }
                match routes.get(&path) {
                    Some(body) => {
                        let header = format!(
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        );
                        let _ = sock.write_all(header.as_bytes()).await;
                        if !is_head {
                            let _ = sock.write_all(body).await;
                        }
                    }
                    None => {
                        let _ = sock
                            .write_all(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                            .await;
                    }
                }
                let _ = sock.flush().await;
            });
        }
    });
    addr
}

fn tmp_dir(tag: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let d = std::env::temp_dir().join(format!("shinsoku_hls_{tag}_{nanos}"));
    std::fs::create_dir_all(&d).unwrap();
    d
}

async fn wait_done(manager: &QueueManager, id: &str) -> DownloadStatus {
    for _ in 0..200 {
        if let Some(it) = manager.get(id) {
            if matches!(it.status, DownloadStatus::Completed | DownloadStatus::Error) {
                return it.status;
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    panic!("download did not finish in time");
}

#[tokio::test]
async fn hls_plaintext_concatenates_segments() {
    let seg0 = make_data(40_000);
    let seg1 = make_data(50_000);
    let seg2 = make_data(12_345);
    let playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n\
        #EXTINF:4.0,\nseg0.ts\n#EXTINF:4.0,\nseg1.ts\n#EXTINF:1.2,\nseg2.ts\n#EXT-X-ENDLIST\n";

    let mut routes = HashMap::new();
    routes.insert("/playlist.m3u8".to_string(), playlist.as_bytes().to_vec());
    routes.insert("/seg0.ts".to_string(), seg0.clone());
    routes.insert("/seg1.ts".to_string(), seg1.clone());
    routes.insert("/seg2.ts".to_string(), seg2.clone());
    let addr = serve_map(routes, 0, &[]).await;

    let manager = QueueManager::new();
    manager.set_categorize(false); // keep the output path predictable
    let dir = tmp_dir("plain");
    let id = manager.add_hls(
        format!("http://{addr}/playlist.m3u8"),
        dir.to_string_lossy().to_string(),
        vec![],
        None,
    );
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Completed);

    let it = manager.get(&id).unwrap();
    assert_eq!(it.segment_total, 3);
    assert_eq!(it.segment_done, 3);

    let written = tokio::fs::read(&it.dest_path).await.unwrap();
    let mut expected = seg0;
    expected.extend_from_slice(&seg1);
    expected.extend_from_slice(&seg2);
    assert!(
        written == expected,
        "concatenated segments differ from source"
    );

    let _ = tokio::fs::remove_dir_all(&dir).await;
}

#[tokio::test]
async fn hls_aes128_decrypts_segments() {
    use aes::Aes128;
    use cbc::cipher::{block_padding::Pkcs7, BlockModeEncrypt, KeyIvInit};
    type Enc = cbc::Encryptor<Aes128>;

    let key = [0x42u8; 16];
    let mut iv = [0u8; 16];
    iv[15] = 0x10;
    let encrypt = |plain: &[u8]| -> Vec<u8> {
        let mut buf = plain.to_vec();
        buf.resize(buf.len() + (16 - buf.len() % 16), 0); // room for PKCS7
        let n = Enc::new(&key.into(), &iv.into())
            .encrypt_padded::<Pkcs7>(&mut buf, plain.len())
            .unwrap()
            .len();
        buf.truncate(n);
        buf
    };

    let plain0 = make_data(8_000);
    let plain1 = make_data(9_001);
    let iv_hex: String = iv.iter().map(|b| format!("{b:02x}")).collect();
    let playlist = format!(
        "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n\
         #EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x{iv_hex}\n\
         #EXTINF:4.0,\nseg0.ts\n#EXTINF:4.0,\nseg1.ts\n#EXT-X-ENDLIST\n"
    );

    let mut routes = HashMap::new();
    routes.insert("/enc.m3u8".to_string(), playlist.into_bytes());
    routes.insert("/key.bin".to_string(), key.to_vec());
    routes.insert("/seg0.ts".to_string(), encrypt(&plain0));
    routes.insert("/seg1.ts".to_string(), encrypt(&plain1));
    let addr = serve_map(routes, 0, &[]).await;

    let manager = QueueManager::new();
    manager.set_categorize(false);
    let dir = tmp_dir("aes");
    let id = manager.add_hls(
        format!("http://{addr}/enc.m3u8"),
        dir.to_string_lossy().to_string(),
        vec![],
        Some("Movie".to_string()),
    );
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Completed);

    let it = manager.get(&id).unwrap();
    let written = tokio::fs::read(&it.dest_path).await.unwrap();
    let mut expected = plain0;
    expected.extend_from_slice(&plain1);
    assert!(written == expected, "decrypted segments differ from source");

    let _ = tokio::fs::remove_dir_all(&dir).await;
}

/// Pause mid-stream, then resume: the engine keeps the committed segment prefix,
/// restarts at `segment_done`, and finishes byte-identical to a clean run.
#[tokio::test]
async fn hls_resumes_after_pause() {
    let segs: Vec<Vec<u8>> = (0..6).map(|i| make_data(10_000 + i * 1_000)).collect();
    let mut playlist = String::from(
        "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n",
    );
    let mut routes = HashMap::new();
    for (i, s) in segs.iter().enumerate() {
        playlist.push_str(&format!("#EXTINF:4.0,\nseg{i}.ts\n"));
        routes.insert(format!("/seg{i}.ts"), s.clone());
    }
    playlist.push_str("#EXT-X-ENDLIST\n");
    routes.insert("/v.m3u8".to_string(), playlist.into_bytes());
    let addr = serve_map(routes, 120, &[]).await; // stall each response so pause lands mid-stream

    let manager = QueueManager::new();
    manager.set_categorize(false);
    manager.set_max_connections(1); // strictly sequential → deterministic pause point
    let dir = tmp_dir("resume");
    let id = manager.add_hls(
        format!("http://{addr}/v.m3u8"),
        dir.to_string_lossy().to_string(),
        vec![],
        None,
    );

    // wait until a couple of segments have committed, then pause
    let mut paused = false;
    for _ in 0..200 {
        if let Some(it) = manager.get(&id) {
            assert_ne!(
                it.status,
                DownloadStatus::Completed,
                "finished before pause"
            );
            if it.segment_done >= 2 {
                paused = true;
                break;
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert!(paused, "no segments committed before pause");
    manager.pause(&id);

    // let the in-flight loop observe the cancel and fully unwind (no new commits)
    let mut done = manager.get(&id).unwrap().segment_done;
    loop {
        tokio::time::sleep(std::time::Duration::from_millis(150)).await;
        let now = manager.get(&id).unwrap().segment_done;
        if now == done {
            break;
        }
        done = now;
    }

    // pause is exact: the temp prefix equals the committed byte count, mid-stream
    let it = manager.get(&id).unwrap();
    assert!(
        it.segment_done >= 2 && it.segment_done < 6,
        "paused at a bad point"
    );
    let temp = temp_path(&PathBuf::from(&it.dest_path));
    let temp_len = tokio::fs::metadata(&temp).await.unwrap().len();
    assert_eq!(
        temp_len, it.downloaded_bytes,
        "temp prefix != committed bytes"
    );

    manager.resume(&id);
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Completed);

    let it = manager.get(&id).unwrap();
    assert_eq!(it.segment_done, 6);
    assert_eq!(it.segment_total, 6);
    let written = tokio::fs::read(&it.dest_path).await.unwrap();
    let expected: Vec<u8> = segs.into_iter().flatten().collect();
    assert!(
        written == expected,
        "resumed stream differs from a clean download"
    );

    let _ = tokio::fs::remove_dir_all(&dir).await;
}

/// Like `serve`, but answers 403 to any request lacking the exact `Cookie:`
/// line — proves per-download headers are sent on probe and every segment.
async fn serve_requiring_cookie(data: Arc<Vec<u8>>, cookie: &'static str) -> SocketAddr {
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
                let has_cookie = req
                    .lines()
                    .any(|l| l.to_ascii_lowercase() == format!("cookie: {cookie}"));
                if !has_cookie {
                    let _ = sock
                        .write_all(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                        .await;
                    let _ = sock.flush().await;
                    return;
                }
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

// ── failures and retry ──────────────────────────────────────────────────────

/// Retry with short delays so tests finish quickly.
fn fast_retry(retries: u32) -> Retry {
    Retry::new(RetryPolicy {
        retries,
        base_delay: Duration::from_millis(10),
        max_delay: Duration::from_millis(50),
        stall_timeout: Duration::from_millis(300),
    })
}

/// A probed, preallocated download, run the way the queue manager runs one.
struct Job {
    url: String,
    plan: Plan,
    dest: PathBuf,
    temp: PathBuf,
    counters: Vec<Arc<AtomicU64>>,
}

impl Job {
    async fn new(addr: SocketAddr, connections: u8, tag: &str) -> Self {
        let url = format!("http://{addr}/blob.bin");
        let plan = fetch_plan(&build_client(), &url, connections, &build_headers(&[]))
            .await
            .unwrap();
        let dest = tmp_dest(tag);
        let temp = temp_path(&dest);
        prepare_destination(&temp, plan.total).await.unwrap();
        let counters = plan
            .segments
            .iter()
            .map(|_| Arc::new(AtomicU64::new(0)))
            .collect();
        Self {
            url,
            plan,
            dest,
            temp,
            counters,
        }
    }

    /// Run every segment on from its counter, until done or failed.
    async fn run(&self, retry: &Retry) -> anyhow::Result<()> {
        run_segments(
            &build_client(),
            Arc::new(RateLimiter::new(0)),
            &self.url,
            &self.temp,
            &self.plan.segments,
            &self.counters,
            &build_headers(&[]),
            CancellationToken::new(),
            retry,
        )
        .await
    }

    async fn assert_matches(self, data: &[u8]) {
        finalize(&self.temp, &self.dest).await.unwrap();
        let written = tokio::fs::read(&self.dest).await.unwrap();
        let _ = tokio::fs::remove_file(&self.dest).await;
        assert_eq!(written.len(), data.len());
        assert!(written == data, "downloaded bytes differ from source");
    }

    async fn discard(self) {
        let _ = tokio::fs::remove_file(&self.temp).await;
    }
}

/// Regression: a segment whose connection drops must not count bytes it never
/// wrote, or resuming from its offset leaves a hole of zeros in the file.
#[tokio::test]
async fn dropped_connection_resumes_without_holes() {
    let data = Arc::new(make_data(1_000_000));
    let faulty = Arc::new(AtomicBool::new(true));
    let flag = faulty.clone();
    let (addr, _) = serve_faulty(
        data.clone(),
        Arc::new(move |_| match flag.load(Ordering::SeqCst) {
            true => Fault::DropAfter(60_000),
            false => Fault::None,
        }),
    )
    .await;
    let job = Job::new(addr, 8, "drop").await;

    // retry off: the run fails, as a download stopped with an error does
    assert!(job.run(&fast_retry(0)).await.is_err());
    assert!(
        job.counters.iter().any(|c| c.load(Ordering::Relaxed) > 0),
        "no progress kept"
    );

    faulty.store(false, Ordering::SeqCst);
    job.run(&fast_retry(0)).await.unwrap();
    job.assert_matches(&data).await;
}

/// Connections that keep dropping mid-body reconnect from where they stopped.
#[tokio::test]
async fn dropped_connections_reconnect_and_finish() {
    let data = Arc::new(make_data(1_000_003));
    let (addr, _) = serve_faulty(data.clone(), Arc::new(|_| Fault::DropAfter(40_000))).await;
    let job = Job::new(addr, 8, "reconnect").await;
    let retry = fast_retry(3);
    job.run(&retry).await.unwrap();
    assert!(
        retry.count.load(Ordering::Relaxed) >= 8,
        "every segment reconnected"
    );
    job.assert_matches(&data).await;
}

#[tokio::test]
async fn server_errors_are_retried() {
    let data = Arc::new(make_data(400_000));
    let seen = Mutex::new(HashMap::<usize, u32>::new());
    let (addr, gets) = serve_faulty(
        data.clone(),
        Arc::new(move |start| {
            let mut seen = seen.lock().unwrap();
            let n = seen.entry(start).or_insert(0);
            *n += 1;
            if *n <= 2 {
                Fault::Status(503)
            } else {
                Fault::None
            }
        }),
    )
    .await;
    let job = Job::new(addr, 4, "503").await;
    let retry = fast_retry(3);
    job.run(&retry).await.unwrap();
    assert_eq!(gets.load(Ordering::SeqCst), 12);
    assert_eq!(retry.count.load(Ordering::Relaxed), 8);
    job.assert_matches(&data).await;
}

/// A connection that goes silent is abandoned after the stall timeout and the
/// segment resumes on a fresh one.
#[tokio::test]
async fn stalled_connection_is_retried() {
    let data = Arc::new(make_data(400_000));
    // only each segment's first request (at its original start) stalls
    let (addr, _) = serve_faulty(
        data.clone(),
        Arc::new(|start| match start % 100_000 {
            0 => Fault::StallAfter(10_000),
            _ => Fault::None,
        }),
    )
    .await;
    let job = Job::new(addr, 4, "stall").await;
    let retry = fast_retry(3);
    job.run(&retry).await.unwrap();
    assert_eq!(retry.count.load(Ordering::Relaxed), 4);
    job.assert_matches(&data).await;
}

/// An error retrying can't fix stops the download at once, with a readable reason.
#[tokio::test]
async fn not_found_is_not_retried() {
    let data = Arc::new(make_data(100_000));
    let (addr, _) = serve_faulty(data, Arc::new(|_| Fault::Status(404))).await;
    let manager = QueueManager::new();
    manager.set_categorize(false);
    manager.set_retry_policy(fast_retry(3).policy);
    let dir = tmp_dir("404");
    let id = manager.add(
        format!("http://{addr}/blob.bin"),
        dir.to_string_lossy().to_string(),
        4,
        vec![],
        None,
    );
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Error);
    let it = manager.get(&id).unwrap();
    assert_eq!(
        it.error.as_deref(),
        Some("File not found on the server (HTTP 404)")
    );
    assert_eq!(it.retry_count, 0);
    let _ = tokio::fs::remove_dir_all(&dir).await;
}

/// A server that ignores `Range` must not get its whole body written into every
/// segment's slot.
#[tokio::test]
async fn ignored_range_fails_instead_of_corrupting() {
    let data = Arc::new(make_data(400_000));
    let (addr, _) = serve_faulty(data.clone(), Arc::new(|_| Fault::IgnoreRange)).await;
    let job = Job::new(addr, 4, "norange").await;
    let retry = fast_retry(3);
    let err = job.run(&retry).await.unwrap_err();
    assert!(matches!(
        err.downcast_ref::<FetchError>(),
        Some(FetchError::RangeIgnored)
    ));
    assert_eq!(retry.count.load(Ordering::Relaxed), 0);
    let len = tokio::fs::metadata(&job.temp).await.unwrap().len();
    assert_eq!(len, data.len() as u64, "a segment wrote past its slot");
    job.discard().await;
}

#[tokio::test]
async fn size_change_is_detected() {
    let data = Arc::new(make_data(400_000));
    let (addr, _) = serve_faulty(data, Arc::new(|_| Fault::ClaimTotal(500_000))).await;
    let job = Job::new(addr, 4, "changed").await;
    let err = job.run(&fast_retry(3)).await.unwrap_err();
    assert_eq!(
        describe(&err),
        "File changed on the server since the download started"
    );
    job.discard().await;
}

#[tokio::test]
async fn gives_up_when_nothing_moves() {
    let data = Arc::new(make_data(100_000));
    let (addr, _) = serve_faulty(data, Arc::new(|_| Fault::Status(503))).await;
    let job = Job::new(addr, 2, "giveup").await;
    let err = job.run(&fast_retry(2)).await.unwrap_err();
    assert_eq!(
        describe(&err),
        "Server error (HTTP 503); gave up after 3 attempts"
    );
    job.discard().await;
}

/// A host that caps connections: the segments over the cap keep waiting while
/// the others make progress, rather than failing the download.
#[tokio::test]
async fn connection_cap_does_not_fail_a_moving_download() {
    let data = Arc::new(make_data(400_000));
    let addr = serve_capped(data.clone(), 2).await;
    let job = Job::new(addr, 4, "cap").await;
    // three failures in a row would end a segment that counted only its own
    let retry = Retry::new(RetryPolicy {
        retries: 2,
        base_delay: Duration::from_millis(200),
        max_delay: Duration::from_millis(300),
        stall_timeout: Duration::from_secs(5),
    });
    job.run(&retry).await.unwrap();
    assert!(retry.count.load(Ordering::Relaxed) > 0);
    job.assert_matches(&data).await;
}

/// A playlist and a media segment that each fail once are fetched again; the
/// stream still completes byte-identical.
#[tokio::test]
async fn hls_retries_failed_fetches() {
    let segs: Vec<Vec<u8>> = (0..3).map(|i| make_data(20_000 + i * 1_000)).collect();
    let mut playlist = String::from(
        "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n",
    );
    let mut routes = HashMap::new();
    for (i, s) in segs.iter().enumerate() {
        playlist.push_str(&format!("#EXTINF:4.0,\nseg{i}.ts\n"));
        routes.insert(format!("/seg{i}.ts"), s.clone());
    }
    playlist.push_str("#EXT-X-ENDLIST\n");
    routes.insert("/v.m3u8".to_string(), playlist.into_bytes());
    let addr = serve_map(routes, 0, &["/v.m3u8", "/seg1.ts"]).await;

    let manager = QueueManager::new();
    manager.set_categorize(false);
    manager.set_retry_policy(fast_retry(3).policy);
    let dir = tmp_dir("retry");
    let id = manager.add_hls(
        format!("http://{addr}/v.m3u8"),
        dir.to_string_lossy().to_string(),
        vec![],
        None,
    );
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Completed);

    let it = manager.get(&id).unwrap();
    assert_eq!(it.retry_count, 2);
    let written = tokio::fs::read(&it.dest_path).await.unwrap();
    let expected: Vec<u8> = segs.into_iter().flatten().collect();
    assert!(written == expected, "stream with retried fetches differs");
    let _ = tokio::fs::remove_dir_all(&dir).await;
}

// ── link refresh ────────────────────────────────────────────────────────────

/// Manager that fails fast, writing into a fresh folder without categories.
fn refresh_manager(tag: &str) -> (QueueManager, PathBuf) {
    let manager = QueueManager::new();
    manager.set_categorize(false);
    manager.set_retry_policy(fast_retry(0).policy);
    (manager, tmp_dir(tag))
}

/// A download whose link died partway, on a server whose every GET drops.
async fn stopped_partway(manager: &QueueManager, dir: &Path, data: Arc<Vec<u8>>) -> String {
    let (old, _) = serve_faulty(data, Arc::new(|_| Fault::DropAfter(50_000))).await;
    let id = manager.add(
        format!("http://{old}/blob.bin"),
        dir.to_string_lossy().to_string(),
        1,
        vec![],
        None,
    );
    assert_eq!(wait_done(manager, &id).await, DownloadStatus::Error);
    assert!(
        manager.get(&id).unwrap().downloaded_bytes > 0,
        "nothing written"
    );
    id
}

/// A download whose link was refused before a byte arrived.
async fn refused_at_once(manager: &QueueManager, dir: &Path) -> String {
    let (old, _) = serve_faulty(Arc::new(make_data(1_000)), Arc::new(|_| Fault::Status(403))).await;
    let id = manager.add(
        format!("http://{old}/blob.bin"),
        dir.to_string_lossy().to_string(),
        4,
        vec![],
        None,
    );
    assert_eq!(wait_done(manager, &id).await, DownloadStatus::Error);
    id
}

#[tokio::test]
async fn refreshed_link_resumes_where_it_stopped() {
    let data = Arc::new(make_data(300_000));
    let starts = Arc::new(Mutex::new(Vec::new()));
    let seen = starts.clone();
    let (new, _) = serve_faulty(
        data.clone(),
        Arc::new(move |start| {
            seen.lock().unwrap().push(start);
            Fault::None
        }),
    )
    .await;
    let (manager, dir) = refresh_manager("resume");
    let id = stopped_partway(&manager, &dir, data.clone()).await;
    let stopped = manager.get(&id).unwrap().downloaded_bytes as usize;

    let url = format!("http://{new}/blob.bin");
    manager.refresh_url(&id, url.clone(), None).await.unwrap();
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Completed);

    let it = manager.get(&id).unwrap();
    assert_eq!(it.url, url);
    // a one-byte probe, then the rest from the byte it reached
    assert_eq!(*starts.lock().unwrap(), vec![0, stopped]);
    assert!(tokio::fs::read(&it.dest_path).await.unwrap() == *data);
    let _ = tokio::fs::remove_dir_all(&dir).await;
}

#[tokio::test]
async fn refresh_refuses_a_different_file() {
    let other = serve(Arc::new(make_data(123_456))).await;
    let (manager, dir) = refresh_manager("other");
    let id = stopped_partway(&manager, &dir, Arc::new(make_data(300_000))).await;
    let before = manager.get(&id).unwrap();

    let err = manager
        .refresh_url(&id, format!("http://{other}/blob.bin"), None)
        .await
        .unwrap_err();
    assert_eq!(
        describe(&err),
        "That link is a different file (120.6 KB; this download is 293.0 KB)"
    );
    let it = manager.get(&id).unwrap();
    assert_eq!(it.url, before.url);
    assert_eq!(it.status, DownloadStatus::Error);
    let _ = tokio::fs::remove_dir_all(&dir).await;
}

/// With nothing written, the old plan (often sized from an error page) is
/// dropped and the new link probed afresh, whatever its size.
#[tokio::test]
async fn refresh_before_any_bytes_starts_over() {
    let data = Arc::new(make_data(250_000));
    let new = serve(data.clone()).await;
    let (manager, dir) = refresh_manager("fresh");
    let id = refused_at_once(&manager, &dir).await;
    assert_eq!(
        manager.get(&id).unwrap().error.as_deref(),
        Some("Access denied (HTTP 403); the link may have expired")
    );

    manager
        .refresh_url(&id, format!("http://{new}/blob.bin"), None)
        .await
        .unwrap();
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Completed);
    let it = manager.get(&id).unwrap();
    assert_eq!(it.total_bytes, data.len() as u64);
    assert_eq!(PathBuf::from(&it.dest_path), dir.join("blob.bin"));
    assert!(tokio::fs::read(&it.dest_path).await.unwrap() == *data);
    let _ = tokio::fs::remove_dir_all(&dir).await;
}

/// Regression: a failure before the first byte removes the temp file, and
/// Retry then found no file to resume into.
#[tokio::test]
async fn retry_after_failing_before_any_bytes() {
    let data = Arc::new(make_data(200_000));
    let refuse = Arc::new(AtomicBool::new(true));
    let flag = refuse.clone();
    let (addr, _) = serve_faulty(
        data.clone(),
        Arc::new(move |_| match flag.load(Ordering::SeqCst) {
            true => Fault::Status(503),
            false => Fault::None,
        }),
    )
    .await;
    let (manager, dir) = refresh_manager("retry0");
    let id = manager.add(
        format!("http://{addr}/blob.bin"),
        dir.to_string_lossy().to_string(),
        4,
        vec![],
        None,
    );
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Error);

    refuse.store(false, Ordering::SeqCst);
    manager.resume(&id);
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Completed);
    let it = manager.get(&id).unwrap();
    assert!(tokio::fs::read(&it.dest_path).await.unwrap() == *data);
    let _ = tokio::fs::remove_dir_all(&dir).await;
}

/// Resuming after the partial file was deleted starts it over instead of
/// failing on the missing file.
#[tokio::test]
async fn resume_recreates_a_deleted_partial_file() {
    let data = Arc::new(make_data(300_000));
    let faulty = Arc::new(AtomicBool::new(true));
    let flag = faulty.clone();
    let (addr, _) = serve_faulty(
        data.clone(),
        Arc::new(move |_| match flag.load(Ordering::SeqCst) {
            true => Fault::DropAfter(50_000),
            false => Fault::None,
        }),
    )
    .await;
    let (manager, dir) = refresh_manager("deleted");
    let id = manager.add(
        format!("http://{addr}/blob.bin"),
        dir.to_string_lossy().to_string(),
        1,
        vec![],
        None,
    );
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Error);
    let it = manager.get(&id).unwrap();
    assert!(it.downloaded_bytes > 0);
    tokio::fs::remove_file(temp_path(Path::new(&it.dest_path)))
        .await
        .unwrap();

    faulty.store(false, Ordering::SeqCst);
    manager.resume(&id);
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Completed);
    let it = manager.get(&id).unwrap();
    assert!(tokio::fs::read(&it.dest_path).await.unwrap() == *data);
    let _ = tokio::fs::remove_dir_all(&dir).await;
}

async fn capture_post(port: u16, url: &str) -> reqwest::Response {
    reqwest::Client::new()
        .post(format!("http://127.0.0.1:{port}/api/add"))
        .header("X-Shinsoku-Token", "t")
        .json(&serde_json::json!({ "url": url, "cookie": "sid=fresh" }))
        .send()
        .await
        .unwrap()
}

#[tokio::test]
async fn captured_link_goes_to_the_waiting_download() {
    let data = Arc::new(make_data(200_000));
    let new = serve(data.clone()).await;
    let (manager, dir) = refresh_manager("capture");
    let id = refused_at_once(&manager, &dir).await;
    let server = capture::start(
        manager.clone(),
        dir.to_string_lossy().to_string(),
        0,
        "t".into(),
    )
    .unwrap();

    manager.await_link(Some(id.clone()));
    let resp = capture_post(server.port, &format!("http://{new}/blob.bin")).await;
    assert_eq!(resp.status(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body["id"], id.as_str());
    assert_eq!(body["refreshed"], true);
    assert!(manager.refresh_target().is_none(), "still waiting");
    assert_eq!(manager.snapshot().len(), 1, "added a new download");

    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Completed);
    let it = manager.get(&id).unwrap();
    assert!(it.headers.contains(&("Cookie".into(), "sid=fresh".into())));
    assert!(tokio::fs::read(&it.dest_path).await.unwrap() == *data);
    let _ = tokio::fs::remove_dir_all(&dir).await;
}

#[tokio::test]
async fn waiting_download_refuses_a_different_file() {
    let other = serve(Arc::new(make_data(5_000))).await;
    let (manager, dir) = refresh_manager("capture_other");
    let id = stopped_partway(&manager, &dir, Arc::new(make_data(300_000))).await;
    let server = capture::start(
        manager.clone(),
        dir.to_string_lossy().to_string(),
        0,
        "t".into(),
    )
    .unwrap();
    let other = format!("http://{other}/blob.bin");

    manager.await_link(Some(id.clone()));
    let resp = capture_post(server.port, &other).await;
    assert_eq!(resp.status(), 409);
    let body: serde_json::Value = resp.json().await.unwrap();
    let reason = "That link is a different file (4.9 KB; this download is 293.0 KB)";
    assert_eq!(body["error"], reason);
    let target = manager.refresh_target().expect("stopped waiting");
    assert_eq!(target.id, id);
    assert_eq!(target.error.as_deref(), Some(reason));
    assert_eq!(manager.snapshot().len(), 1);

    // nothing waiting: a capture adds a download, as before
    manager.await_link(None);
    let resp = capture_post(server.port, &other).await;
    assert_eq!(resp.status(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert!(body.get("refreshed").is_none());
    assert_eq!(manager.snapshot().len(), 2);
    let _ = tokio::fs::remove_dir_all(&dir).await;
}

#[tokio::test]
async fn refreshed_playlist_continues_the_stream() {
    let segs: Vec<Vec<u8>> = (0..4).map(|i| make_data(15_000 + i * 1_000)).collect();
    let playlist = |n: usize| {
        let mut p = String::from(
            "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n",
        );
        for i in 0..n {
            p.push_str(&format!("#EXTINF:4.0,\nseg{i}.ts\n"));
        }
        p.push_str("#EXT-X-ENDLIST\n");
        p.into_bytes()
    };
    // the old host's link dies after two segments
    let mut old = HashMap::from([("/v.m3u8".to_string(), playlist(4))]);
    let mut new = HashMap::from([("/v.m3u8".to_string(), playlist(4))]);
    for (i, s) in segs.iter().enumerate() {
        if i < 2 {
            old.insert(format!("/seg{i}.ts"), s.clone());
        }
        new.insert(format!("/seg{i}.ts"), s.clone());
    }
    let short = HashMap::from([("/v.m3u8".to_string(), playlist(3))]);
    let old = serve_map(old, 0, &[]).await;
    let new = serve_map(new, 0, &[]).await;
    let short = serve_map(short, 0, &[]).await;

    let (manager, dir) = refresh_manager("hls_refresh");
    manager.set_max_connections(1);
    let id = manager.add_hls(
        format!("http://{old}/v.m3u8"),
        dir.to_string_lossy().to_string(),
        vec![],
        None,
    );
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Error);
    assert_eq!(manager.get(&id).unwrap().segment_done, 2);

    let err = manager
        .refresh_url(&id, format!("http://{short}/v.m3u8"), None)
        .await
        .unwrap_err();
    assert_eq!(
        describe(&err),
        "That playlist has 3 segments; this download has 4"
    );

    manager
        .refresh_url(&id, format!("http://{new}/v.m3u8"), None)
        .await
        .unwrap();
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Completed);
    let it = manager.get(&id).unwrap();
    let expected: Vec<u8> = segs.into_iter().flatten().collect();
    assert!(tokio::fs::read(&it.dest_path).await.unwrap() == expected);
    let _ = tokio::fs::remove_dir_all(&dir).await;
}
