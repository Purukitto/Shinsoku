use anyhow::Result;
use std::path::{Path, PathBuf};
use tokio::fs;

/// In-flight temp path; renamed to `dest` on success.
pub fn temp_path(dest: &Path) -> PathBuf {
    let name = dest
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("download");
    let parent = dest.parent().unwrap_or(Path::new("."));
    parent.join(format!(".{}.shinsoku", name))
}

/// Rename the temp file into place (atomic on the same volume).
pub async fn finalize(temp: &Path, dest: &Path) -> Result<()> {
    fs::rename(temp, dest).await?;
    Ok(())
}
