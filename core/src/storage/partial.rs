use anyhow::Result;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::fs::{File, OpenOptions};
use tokio::io::{AsyncSeekExt, AsyncWriteExt, BufWriter, SeekFrom};

const BUF_BYTES: usize = 256 * 1024;
/// Upper bound on how long received bytes sit unflushed, so `done` (and the
/// progress built on it) keeps moving on slow links.
const FLUSH_INTERVAL: Duration = Duration::from_millis(50);

/// Create/truncate and preallocate `total` bytes so segments write at fixed offsets.
pub async fn prepare_destination(path: &Path, total: u64) -> Result<()> {
    let file = File::create(path).await?;
    if total > 0 {
        file.set_len(total).await?;
    }
    Ok(())
}

/// Buffered writer into one segment's range of the preallocated file (opened once).
/// `done` advances only after a flush, so a checkpoint, error or crash never
/// records an offset past what reached the OS — resume can't skip unwritten bytes.
pub struct SegmentWriter<'a> {
    out: BufWriter<File>,
    done: &'a AtomicU64,
    pending: u64,
    last_flush: Instant,
}

impl<'a> SegmentWriter<'a> {
    /// Open at `start`; writes proceed sequentially in-range.
    pub async fn open(path: &Path, start: u64, done: &'a AtomicU64) -> Result<Self> {
        let mut file = OpenOptions::new().write(true).open(path).await?;
        file.seek(SeekFrom::Start(start)).await?;
        Ok(Self {
            out: BufWriter::with_capacity(BUF_BYTES, file),
            done,
            pending: 0,
            last_flush: Instant::now(),
        })
    }

    pub async fn write(&mut self, data: &[u8]) -> Result<()> {
        self.out.write_all(data).await?;
        self.pending += data.len() as u64;
        if self.pending >= BUF_BYTES as u64 || self.last_flush.elapsed() >= FLUSH_INTERVAL {
            self.flush().await?;
        }
        Ok(())
    }

    /// Flushes the remainder. Call on every exit path, including errors.
    pub async fn finish(mut self) -> Result<()> {
        self.flush().await
    }

    async fn flush(&mut self) -> Result<()> {
        self.out.flush().await?;
        self.done.fetch_add(self.pending, Ordering::Relaxed);
        self.pending = 0;
        self.last_flush = Instant::now();
        Ok(())
    }
}
