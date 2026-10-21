//! On-disk persistence of the download list so the queue and completed history
//! survive restarts. One JSON file, written atomically (sibling temp + rename)
//! so a crash mid-write can't truncate the existing store.

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::engine::download::DownloadItem;

const VERSION: u32 = 1;

#[derive(Deserialize)]
struct Store {
    #[allow(dead_code)]
    version: u32,
    downloads: Vec<DownloadItem>,
}

#[derive(Serialize)]
struct StoreRef<'a> {
    version: u32,
    downloads: &'a [DownloadItem],
}

/// Read the persisted list. A missing, unreadable, or corrupt file yields an
/// empty list — the app starts fresh rather than failing to launch.
pub fn load(path: &Path) -> Vec<DownloadItem> {
    let Ok(bytes) = std::fs::read(path) else {
        return Vec::new();
    };
    serde_json::from_slice::<Store>(&bytes)
        .map(|s| s.downloads)
        .unwrap_or_default()
}

/// Atomically persist `items` to `path`.
pub fn save(path: &Path, items: &[DownloadItem]) -> std::io::Result<()> {
    let data = serde_json::to_vec(&StoreRef {
        version: VERSION,
        downloads: items,
    })
    .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, &data)?;
    std::fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::download::DownloadStatus;

    fn item(id: &str, status: DownloadStatus) -> DownloadItem {
        DownloadItem {
            id: id.into(),
            url: "https://example.com/f.bin".into(),
            filename: "f.bin".into(),
            dest_path: "/tmp/f.bin".into(),
            total_bytes: 100,
            downloaded_bytes: 40,
            speed_bps: 0,
            peak_bps: 10,
            status,
            connections: 4,
            segments: vec![],
            speed_history: vec![0; 4],
            added_at_ms: 1,
            mime_type: None,
            resumable: true,
            host: "example.com".into(),
            file_type: "app".into(),
            error: None,
            completed_at_ms: None,
            headers: vec![("Cookie".into(), "x=1".into())],
            expected_checksum: None,
            checksum: None,
            checksum_algo: None,
            checksum_verified: None,
            kind: crate::engine::download::DownloadKind::Http,
            segment_total: 0,
            segment_done: 0,
            retry_count: 0,
        }
    }

    #[test]
    fn missing_file_is_empty() {
        let p = std::env::temp_dir().join("shinsoku_no_such_store.json");
        let _ = std::fs::remove_file(&p);
        assert!(load(&p).is_empty());
    }

    #[test]
    fn round_trips() {
        let p = std::env::temp_dir().join(format!("shinsoku_store_{}.json", std::process::id()));
        let items = vec![
            item("a", DownloadStatus::Completed),
            item("b", DownloadStatus::Paused),
        ];
        save(&p, &items).unwrap();
        let loaded = load(&p);
        let _ = std::fs::remove_file(&p);
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].id, "a");
        assert_eq!(loaded[0].headers, vec![("Cookie".into(), "x=1".into())]);
        assert_eq!(loaded[1].status, DownloadStatus::Paused);
    }
}
