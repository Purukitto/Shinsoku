use std::sync::Mutex;
use std::time::Duration;
use tokio::time::Instant;

/// Global byte-rate limiter (0 = unlimited). Leaky bucket: refills at `rate`/s
/// (burst ≤ 1s); `acquire` spends bytes and sleeps off any debt.
pub struct RateLimiter {
    inner: Mutex<Bucket>,
}

struct Bucket {
    rate: u64, // bytes per second; 0 = unlimited
    tokens: f64,
    last: Instant,
}

impl RateLimiter {
    pub fn new(rate_bps: u64) -> Self {
        Self {
            inner: Mutex::new(Bucket {
                rate: rate_bps,
                tokens: rate_bps as f64,
                last: Instant::now(),
            }),
        }
    }

    pub fn set_rate(&self, rate_bps: u64) {
        let mut b = self.inner.lock().unwrap();
        b.rate = rate_bps;
        if rate_bps > 0 {
            b.tokens = b.tokens.min(rate_bps as f64);
        }
    }

    /// Asynchronously waits until `bytes` worth of bandwidth is available.
    pub async fn acquire(&self, bytes: u64) {
        let sleep_for = {
            let mut b = self.inner.lock().unwrap();
            if b.rate == 0 {
                return;
            }
            let now = Instant::now();
            let elapsed = now.duration_since(b.last).as_secs_f64();
            b.last = now;
            // refill, with the positive burst capped at one second of capacity
            b.tokens = (b.tokens + elapsed * b.rate as f64).min(b.rate as f64);
            b.tokens -= bytes as f64; // may go negative (debt)
            if b.tokens >= 0.0 {
                Duration::ZERO
            } else {
                Duration::from_secs_f64(-b.tokens / b.rate as f64)
            }
        };
        if sleep_for > Duration::ZERO {
            tokio::time::sleep(sleep_for).await;
        }
    }
}
