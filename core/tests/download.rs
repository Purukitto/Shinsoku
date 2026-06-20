//! End-to-end engine tests against a hermetic, range-capable HTTP server (no
//! network). Exercises the orchestrator the same way the queue manager does:
//! probe → preallocate → parallel ranged segments → finalize.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::AtomicU64;
use std::sync::Arc;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

use shinsoku_core::engine::download::DownloadStatus;
use shinsoku_core::engine::orchestrator::{fetch_plan, run_segments};
use shinsoku_core::engine::throttle::RateLimiter;
use shinsoku_core::protocols::http::{build_client, build_headers};
use shinsoku_core::queue::manager::QueueManager;
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
    let plan = fetch_plan(&client, &url, 8, &build_headers(&[])).await.unwrap();
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
    let mut plan = fetch_plan(&client, &url, 4, &build_headers(&[])).await.unwrap();

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
    )
    .await
    .unwrap();
    finalize(&temp, &dest).await.unwrap();

    let written = tokio::fs::read(&dest).await.unwrap();
    assert!(written == *data, "header-gated download differs from source");

    let _ = tokio::fs::remove_file(&dest).await;
}

// ── HLS pipeline ────────────────────────────────────────────────────────────

/// Serves a fixed path→bytes map (200 + Content-Length, one request per
/// connection). Used to stand up an HLS playlist + its segments/key.
/// `delay_ms` stalls each response so a download can be paused mid-stream.
async fn serve_map(routes: HashMap<String, Vec<u8>>, delay_ms: u64) -> SocketAddr {
    let routes = Arc::new(routes);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let (mut sock, _) = match listener.accept().await {
                Ok(c) => c,
                Err(_) => continue,
            };
            let routes = routes.clone();
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
    let addr = serve_map(routes, 0).await;

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
    assert!(written == expected, "concatenated segments differ from source");

    let _ = tokio::fs::remove_dir_all(&dir).await;
}

#[tokio::test]
async fn hls_aes128_decrypts_segments() {
    use aes::Aes128;
    use cbc::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
    type Enc = cbc::Encryptor<Aes128>;

    let key = [0x42u8; 16];
    let mut iv = [0u8; 16];
    iv[15] = 0x10;
    let encrypt = |plain: &[u8]| -> Vec<u8> {
        let mut buf = plain.to_vec();
        buf.resize(buf.len() + (16 - buf.len() % 16), 0); // room for PKCS7
        let n = Enc::new(&key.into(), &iv.into())
            .encrypt_padded_mut::<Pkcs7>(&mut buf, plain.len())
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
    let addr = serve_map(routes, 0).await;

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
    let mut playlist =
        String::from("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n");
    let mut routes = HashMap::new();
    for (i, s) in segs.iter().enumerate() {
        playlist.push_str(&format!("#EXTINF:4.0,\nseg{i}.ts\n"));
        routes.insert(format!("/seg{i}.ts"), s.clone());
    }
    playlist.push_str("#EXT-X-ENDLIST\n");
    routes.insert("/v.m3u8".to_string(), playlist.into_bytes());
    let addr = serve_map(routes, 120).await; // stall each response so pause lands mid-stream

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
            assert_ne!(it.status, DownloadStatus::Completed, "finished before pause");
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
    assert!(it.segment_done >= 2 && it.segment_done < 6, "paused at a bad point");
    let temp = temp_path(&PathBuf::from(&it.dest_path));
    let temp_len = tokio::fs::metadata(&temp).await.unwrap().len();
    assert_eq!(temp_len, it.downloaded_bytes, "temp prefix != committed bytes");

    manager.resume(&id);
    assert_eq!(wait_done(&manager, &id).await, DownloadStatus::Completed);

    let it = manager.get(&id).unwrap();
    assert_eq!(it.segment_done, 6);
    assert_eq!(it.segment_total, 6);
    let written = tokio::fs::read(&it.dest_path).await.unwrap();
    let expected: Vec<u8> = segs.into_iter().flatten().collect();
    assert!(written == expected, "resumed stream differs from a clean download");

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
