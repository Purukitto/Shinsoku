use anyhow::Result;
use bytes::Bytes;
use std::path::Path;
use tokio::fs::{File, OpenOptions};
use tokio::io::{AsyncSeekExt, AsyncWriteExt, BufWriter, SeekFrom};

/// Create/truncate and preallocate `total` bytes so segments write at fixed offsets.
pub async fn prepare_destination(path: &Path, total: u64) -> Result<()> {
    let file = File::create(path).await?;
    if total > 0 {
        file.set_len(total).await?;
    }
    Ok(())
}

/// Buffered writer into one segment's range of the preallocated file (opened once).
pub struct SegmentWriter {
    out: BufWriter<File>,
}

impl SegmentWriter {
    /// Open at `start`; writes proceed sequentially in-range.
    pub async fn open(path: &Path, start: u64) -> Result<Self> {
        let mut file = OpenOptions::new().write(true).open(path).await?;
        file.seek(SeekFrom::Start(start)).await?;
        Ok(Self {
            out: BufWriter::with_capacity(256 * 1024, file),
        })
    }

    #[inline]
    pub async fn write(&mut self, data: &Bytes) -> Result<()> {
        self.out.write_all(data).await?;
        Ok(())
    }

    /// Flushes the buffer to disk. Call once the segment is complete.
    pub async fn finish(mut self) -> Result<()> {
        self.out.flush().await?;
        Ok(())
    }
}
