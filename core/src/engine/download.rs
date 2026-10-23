use serde::{Deserialize, Serialize};

/// Download source. `Http` is the byte-range multi-segment path; `Hls` fetches an
/// M3U8 playlist and concatenates its media segments. Defaulted so items persisted
/// before this field load as `Http`.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub enum DownloadKind {
    #[default]
    Http,
    Hls,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadItem {
    pub id: String,
    pub url: String,
    pub filename: String,
    pub dest_path: String,
    pub total_bytes: u64,
    pub downloaded_bytes: u64,
    pub speed_bps: u64,
    pub peak_bps: u64,
    pub status: DownloadStatus,
    pub connections: u8,
    pub segments: Vec<SegmentInfo>,
    pub speed_history: Vec<u64>,
    pub added_at_ms: i64,
    pub mime_type: Option<String>,
    pub resumable: bool,
    pub host: String,
    pub file_type: String,
    pub error: Option<String>,
    /// Epoch ms when the download finished; `None` until completed. Persisted so
    /// the history shows the real completion time after a restart.
    pub completed_at_ms: Option<i64>,
    /// Per-download request headers (Cookie/Referer/User-Agent from browser
    /// capture). Applied to every probe/segment request; UA overrides the client default.
    pub headers: Vec<(String, String)>,
    /// Digest to verify the finished file against, if the user/extension gave one.
    /// Algorithm is inferred from its length (32 hex = MD5, else SHA-256).
    pub expected_checksum: Option<String>,
    /// Computed digest of the finished file (lowercase hex); `None` until completed.
    pub checksum: Option<String>,
    /// Algorithm used for `checksum` ("sha256"/"md5").
    pub checksum_algo: Option<String>,
    /// Result of checking `checksum` against `expected_checksum`; `None` when no
    /// expected digest was supplied (so nothing to verify).
    pub checksum_verified: Option<bool>,
    /// Download source. Defaulted for items persisted before this field existed.
    #[serde(default)]
    pub kind: DownloadKind,
    /// HLS only: total media segments in the playlist (0 for HTTP).
    #[serde(default)]
    pub segment_total: u32,
    /// HLS only: media segments already concatenated into the file. With HLS,
    /// `downloaded_bytes` is the committed byte length (resume anchor) and
    /// `total_bytes` is a running size estimate.
    #[serde(default)]
    pub segment_done: u32,
    /// Reconnects after transient failures during the latest run; reset when a
    /// run starts.
    #[serde(default)]
    pub retry_count: u32,
    /// Folder the download was added to; category subfolders go under it. Empty
    /// for items persisted before this field, which fall back to `dest_path`'s parent.
    #[serde(default)]
    pub dest_dir: String,
    /// Runs only during off-peak hours: waits queued until they begin, and goes
    /// back to waiting when they end.
    #[serde(default)]
    pub scheduled: bool,
}

impl DownloadItem {
    pub fn progress(&self) -> f64 {
        if self.total_bytes == 0 {
            return 0.0;
        }
        self.downloaded_bytes as f64 / self.total_bytes as f64
    }

    pub fn eta_seconds(&self) -> Option<u64> {
        if self.speed_bps == 0 || self.status != DownloadStatus::Downloading {
            return None;
        }
        let remaining = self.total_bytes.saturating_sub(self.downloaded_bytes);
        Some(remaining / self.speed_bps)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum DownloadStatus {
    Queued,
    Downloading,
    Paused,
    Completed,
    Error,
}

/// Compact per-tick delta; avoids cloning segments/history. Full items fetched
/// for detail.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DownloadProgress {
    pub id: String,
    pub downloaded_bytes: u64,
    pub total_bytes: u64,
    pub speed_bps: u64,
    pub status: DownloadStatus,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SegmentInfo {
    pub index: u8,
    pub start_byte: u64,
    pub end_byte: u64,
    pub downloaded_bytes: u64,
    pub active: bool,
}

impl SegmentInfo {
    pub fn progress(&self) -> f64 {
        let range = self.end_byte.saturating_sub(self.start_byte);
        if range == 0 {
            return 0.0;
        }
        self.downloaded_bytes as f64 / range as f64
    }
}

/// Probe result for the Add dialog preview.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProbeResult {
    pub filename: String,
    pub total_bytes: u64,
    pub resumable: bool,
    pub mime_type: Option<String>,
    pub host: String,
    pub file_type: String,
}

/// Coarse file-type bucket derived from extension (then mime as a fallback),
/// mirrored by the Dart `FileType` enum so the UI picks the right icon/colour.
pub fn classify(filename: &str, mime: Option<&str>) -> String {
    let ext = filename
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase();
    let by_ext = match ext.as_str() {
        "mkv" | "mp4" | "avi" | "mov" | "webm" | "flv" | "m4v" | "wmv" | "mpg" | "mpeg" | "ts" => {
            "video"
        }
        "zip" | "rar" | "7z" | "tar" | "gz" | "bz2" | "xz" | "zst" | "tgz" => "archive",
        "exe" | "msi" | "dmg" | "pkg" | "apk" | "deb" | "rpm" | "appimage" => "app",
        "mp3" | "flac" | "wav" | "aac" | "ogg" | "m4a" | "opus" | "wma" => "audio",
        "jpg" | "jpeg" | "png" | "gif" | "webp" | "bmp" | "svg" | "heic" | "tiff" => "image",
        "pdf" | "doc" | "docx" | "xls" | "xlsx" | "ppt" | "pptx" | "txt" | "epub" | "csv" => "doc",
        "iso" | "img" | "vhd" | "vmdk" => "iso",
        _ => "",
    };
    if !by_ext.is_empty() {
        return by_ext.to_string();
    }
    if let Some(m) = mime {
        let m = m.to_ascii_lowercase();
        if m.starts_with("video/") {
            return "video".into();
        }
        if m.starts_with("audio/") {
            return "audio".into();
        }
        if m.starts_with("image/") {
            return "image".into();
        }
        if m.contains("zip") || m.contains("compressed") || m.contains("tar") {
            return "archive".into();
        }
        if m.contains("pdf") || m.starts_with("text/") {
            return "doc".into();
        }
    }
    "unknown".into()
}
