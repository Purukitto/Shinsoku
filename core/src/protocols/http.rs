use anyhow::Result;
use reqwest::header::HeaderMap;
use reqwest::Client;

/// Shared HTTP client; cloning shares the connection pool (keep-alive reused
/// across segments).
pub fn build_client() -> Client {
    Client::builder()
        .use_rustls_tls()
        .pool_max_idle_per_host(16)
        // a silent server otherwise hangs a connect forever; stalls after
        // connecting are caught per request by the retry policy
        .connect_timeout(std::time::Duration::from_secs(15))
        // many CDNs reject requests with no User-Agent
        .user_agent(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
             (KHTML, like Gecko) Chrome/126.0 Safari/537.36 Shinsoku/1.0",
        )
        .build()
        .expect("failed to build HTTP client")
}

/// Build a `HeaderMap` from stored name/value pairs, skipping any that don't
/// parse as valid header name/value.
pub fn build_headers(pairs: &[(String, String)]) -> HeaderMap {
    use reqwest::header::{HeaderName, HeaderValue};
    let mut map = HeaderMap::with_capacity(pairs.len());
    for (k, v) in pairs {
        if let (Ok(name), Ok(val)) = (
            HeaderName::from_bytes(k.as_bytes()),
            HeaderValue::from_str(v),
        ) {
            map.insert(name, val);
        }
    }
    map
}

#[derive(Debug)]
pub struct FileInfo {
    pub total_bytes: u64,
    pub resumable: bool,
    pub mime_type: Option<String>,
    pub filename: Option<String>,
}

pub async fn probe(client: &Client, url: &str, headers: &HeaderMap) -> Result<FileInfo> {
    let resp = client.head(url).headers(headers.clone()).send().await?;
    let total_bytes = resp
        .headers()
        .get("content-length")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0);
    let resumable = resp
        .headers()
        .get("accept-ranges")
        .map(|v| v.to_str().unwrap_or("") == "bytes")
        .unwrap_or(false);
    let mime_type = resp
        .headers()
        .get("content-type")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.split(';').next().unwrap_or(s).trim().to_string());
    let filename = resp
        .headers()
        .get("content-disposition")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| {
            v.split(';')
                .find(|p| p.trim().starts_with("filename"))
                .and_then(|p| p.split('=').nth(1))
                .map(|s| s.trim_matches('"').to_string())
        });
    Ok(FileInfo {
        total_bytes,
        resumable,
        mime_type,
        filename,
    })
}

/// Probe with a one-byte ranged GET, the request segments actually make: fails
/// on an error status (unlike [`probe`], whose HEAD some hosts answer
/// differently), and reads the size from `Content-Range`.
pub async fn probe_range(client: &Client, url: &str, headers: &HeaderMap) -> Result<FileInfo> {
    let resp = client
        .get(url)
        .headers(headers.clone())
        .header(reqwest::header::RANGE, "bytes=0-0")
        .send()
        .await?
        .error_for_status()?;
    let header = |name: &str| {
        resp.headers()
            .get(name)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string)
    };
    let partial = resp.status() == reqwest::StatusCode::PARTIAL_CONTENT;
    // "bytes 0-0/1234"; the size may be "*"
    let total_bytes = if partial {
        header("content-range")
            .and_then(|v| v.rsplit('/').next().and_then(|s| s.trim().parse().ok()))
            .unwrap_or(0)
    } else {
        resp.content_length().unwrap_or(0)
    };
    Ok(FileInfo {
        total_bytes,
        resumable: partial,
        mime_type: header("content-type").map(|s| s.split(';').next().unwrap_or(&s).trim().into()),
        filename: None,
    })
}
