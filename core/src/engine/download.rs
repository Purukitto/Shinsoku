use serde::{Deserialize, Serialize};

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
        "mkv" | "mp4" | "avi" | "mov" | "webm" | "flv" | "m4v" | "wmv" | "mpg" | "mpeg" | "ts" => "video",
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
