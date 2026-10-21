//! Retry policy for transient network failures, and the one-line reasons the
//! UI shows when a download stops.

use std::future::Future;
use std::io;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::Result;
use reqwest::StatusCode;
use tokio_util::sync::CancellationToken;

/// Failures detected by the engine itself, beyond what `reqwest` reports.
#[derive(Debug, thiserror::Error)]
pub enum FetchError {
    #[error("Connection stalled")]
    Stalled,
    #[error("Connection closed early")]
    Truncated,
    #[error("Server ignored the byte range")]
    RangeIgnored,
    #[error("Server returned the wrong byte range")]
    WrongRange,
    #[error("File changed on the server since the download started")]
    Changed,
}

/// Context marking a failure that outlasted the retry budget.
#[derive(Debug)]
pub struct GaveUp(pub u32);

impl std::fmt::Display for GaveUp {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "gave up after {} attempts", self.0)
    }
}

#[derive(Debug, Clone, Copy)]
pub struct RetryPolicy {
    /// Consecutive failures without progress before giving up; 0 disables retry.
    pub retries: u32,
    /// Delay before the second retry in a row; doubles per failure up to `max_delay`.
    /// The first retry after a failure is immediate.
    pub base_delay: Duration,
    pub max_delay: Duration,
    /// No response headers, or no body bytes, for this long counts as a dropped
    /// connection.
    pub stall_timeout: Duration,
}

impl Default for RetryPolicy {
    /// ~2 minutes of backoff (0, 1, 2, 4, 8, 16, 30, 30, 30 s): rides out a Wi-Fi
    /// reconnect or router restart.
    fn default() -> Self {
        Self {
            retries: 9,
            base_delay: Duration::from_secs(1),
            max_delay: Duration::from_secs(30),
            stall_timeout: Duration::from_secs(30),
        }
    }
}

impl RetryPolicy {
    /// Backoff before retry number `streak` (1-based) of a failure streak, with up
    /// to 25% jitter so parallel segments don't reconnect in lockstep.
    pub fn delay(&self, streak: u32) -> Duration {
        if streak <= 1 {
            return Duration::ZERO;
        }
        let exp = self
            .base_delay
            .saturating_mul(1u32 << (streak - 2).min(16))
            .min(self.max_delay);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.subsec_nanos())
            .unwrap_or(0);
        exp + exp.mul_f64((nanos % 1000) as f64 / 4000.0)
    }
}

/// A run's retry policy plus the counter the UI reads. Clones share the counter.
#[derive(Clone)]
pub struct Retry {
    pub policy: RetryPolicy,
    pub count: Arc<AtomicU32>,
}

impl Retry {
    pub fn new(policy: RetryPolicy) -> Self {
        Self {
            policy,
            count: Arc::new(AtomicU32::new(0)),
        }
    }

    /// Wait out the backoff before retry `streak` and count it. False if `cancel`
    /// fired first.
    pub async fn wait(&self, streak: u32, cancel: &CancellationToken) -> bool {
        self.count.fetch_add(1, Ordering::Relaxed);
        tokio::select! {
            biased;
            _ = cancel.cancelled() => false,
            _ = tokio::time::sleep(self.policy.delay(streak)) => true,
        }
    }

    /// Run `op` until it succeeds, fails permanently, or fails `retries` more
    /// times in a row.
    pub async fn run<T, F, Fut>(&self, cancel: &CancellationToken, mut op: F) -> Result<T>
    where
        F: FnMut() -> Fut,
        Fut: Future<Output = Result<T>>,
    {
        let mut streak = 0;
        loop {
            let e = match op().await {
                Ok(v) => return Ok(v),
                Err(e) => e,
            };
            if !is_transient(&e) || cancel.is_cancelled() || self.policy.retries == 0 {
                return Err(e);
            }
            streak += 1;
            if streak > self.policy.retries {
                return Err(e.context(GaveUp(streak)));
            }
            if !self.wait(streak, cancel).await {
                return Err(e);
            }
        }
    }
}

/// Await `fut`, treating `limit` without completion as a stalled connection.
pub async fn within<F: Future>(limit: Duration, fut: F) -> Result<F::Output> {
    tokio::time::timeout(limit, fut)
        .await
        .map_err(|_| FetchError::Stalled.into())
}

/// Whether retrying could help: dropped/stalled connections and overloaded
/// servers, not missing files, access denials, disk errors or changed content.
pub fn is_transient(e: &anyhow::Error) -> bool {
    for cause in e.chain() {
        if let Some(f) = cause.downcast_ref::<FetchError>() {
            return matches!(f, FetchError::Stalled | FetchError::Truncated);
        }
        if let Some(r) = cause.downcast_ref::<reqwest::Error>() {
            return match r.status() {
                Some(s) => transient_status(s),
                None => !(r.is_builder() || r.is_redirect()),
            };
        }
        if cause.is::<io::Error>() {
            return false;
        }
    }
    false
}

fn transient_status(s: StatusCode) -> bool {
    matches!(s.as_u16(), 408 | 425 | 429)
        || (s.is_server_error() && !matches!(s.as_u16(), 501 | 505 | 511))
}

/// One-line, user-facing reason for a failed download.
pub fn describe(e: &anyhow::Error) -> String {
    // a context only downcasts on the Error itself; in the chain it is link 0
    let gave_up = e.downcast_ref::<GaveUp>();
    let mut causes = e.chain().skip(gave_up.is_some() as usize);
    let reason = causes
        .clone()
        .find_map(reason_of)
        .or_else(|| causes.next().map(|c| c.to_string()))
        .unwrap_or_else(|| e.to_string());
    match gave_up {
        Some(g) => format!("{reason}; {g}"),
        None => reason,
    }
}

fn reason_of(cause: &(dyn std::error::Error + 'static)) -> Option<String> {
    if let Some(f) = cause.downcast_ref::<FetchError>() {
        return Some(f.to_string());
    }
    if let Some(r) = cause.downcast_ref::<reqwest::Error>() {
        return Some(match r.status() {
            Some(s) => status_reason(s),
            None if r.is_timeout() => "Connection timed out".into(),
            None if r.is_connect() => "Couldn't connect to the server".into(),
            None => "Connection lost".into(),
        });
    }
    if let Some(io) = cause.downcast_ref::<io::Error>() {
        return Some(match io.kind() {
            io::ErrorKind::StorageFull => "Disk full".into(),
            io::ErrorKind::PermissionDenied => "No permission to write the file".into(),
            io::ErrorKind::NotFound => "Download folder or file is missing".into(),
            _ => format!("Disk error: {io}"),
        });
    }
    None
}

fn status_reason(s: StatusCode) -> String {
    let c = s.as_u16();
    match c {
        401 | 403 => format!("Access denied (HTTP {c}); the link may have expired"),
        404 | 410 => format!("File not found on the server (HTTP {c})"),
        416 => "Server refused the byte range (HTTP 416)".into(),
        429 => "Server is rate-limiting (HTTP 429)".into(),
        500..=599 => format!("Server error (HTTP {c})"),
        _ => match s.canonical_reason() {
            Some(r) => format!("HTTP {c} {r}"),
            None => format!("HTTP {c}"),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delay_starts_immediate_then_doubles_to_cap() {
        let p = RetryPolicy::default();
        assert_eq!(p.delay(1), Duration::ZERO);
        let within_jitter = |d: Duration, base: u64| {
            d >= Duration::from_secs(base) && d <= Duration::from_secs(base).mul_f64(1.25)
        };
        assert!(within_jitter(p.delay(2), 1));
        assert!(within_jitter(p.delay(3), 2));
        assert!(within_jitter(p.delay(6), 16));
        assert!(within_jitter(p.delay(7), 30));
        assert!(within_jitter(p.delay(40), 30));
    }

    #[test]
    fn engine_errors_classify() {
        assert!(is_transient(&FetchError::Stalled.into()));
        assert!(is_transient(&FetchError::Truncated.into()));
        assert!(!is_transient(&FetchError::RangeIgnored.into()));
        assert!(!is_transient(&FetchError::Changed.into()));
        let disk: anyhow::Error = io::Error::from(io::ErrorKind::StorageFull).into();
        assert!(!is_transient(&disk));
        assert!(!is_transient(&anyhow::anyhow!(
            "live streams are not supported"
        )));
    }

    #[test]
    fn statuses_classify() {
        for c in [408, 425, 429, 500, 502, 503, 504, 520, 522] {
            assert!(transient_status(StatusCode::from_u16(c).unwrap()), "{c}");
        }
        for c in [400, 401, 403, 404, 410, 416, 501, 505, 511] {
            assert!(!transient_status(StatusCode::from_u16(c).unwrap()), "{c}");
        }
    }

    #[test]
    fn describe_reads_like_a_sentence() {
        let e: anyhow::Error = io::Error::from(io::ErrorKind::StorageFull).into();
        assert_eq!(describe(&e), "Disk full");
        let e = anyhow::Error::from(FetchError::Stalled).context(GaveUp(10));
        assert_eq!(
            describe(&e),
            "Connection stalled; gave up after 10 attempts"
        );
        let e = anyhow::anyhow!("live streams are not supported");
        assert_eq!(describe(&e), "live streams are not supported");
    }

    #[tokio::test]
    async fn run_retries_transient_until_success() {
        let retry = Retry::new(RetryPolicy {
            retries: 3,
            base_delay: Duration::from_millis(1),
            max_delay: Duration::from_millis(1),
            stall_timeout: Duration::from_secs(1),
        });
        let mut calls = 0;
        let out = retry
            .run(&CancellationToken::new(), || {
                calls += 1;
                let n = calls;
                async move {
                    if n < 3 {
                        Err(FetchError::Stalled.into())
                    } else {
                        Ok(n)
                    }
                }
            })
            .await
            .unwrap();
        assert_eq!(out, 3);
        assert_eq!(retry.count.load(Ordering::Relaxed), 2);
    }

    #[tokio::test]
    async fn run_stops_on_permanent_and_when_budget_spent() {
        let retry = Retry::new(RetryPolicy {
            retries: 2,
            base_delay: Duration::from_millis(1),
            max_delay: Duration::from_millis(1),
            stall_timeout: Duration::from_secs(1),
        });
        let cancel = CancellationToken::new();

        let mut calls = 0;
        let e = retry
            .run(&cancel, || {
                calls += 1;
                async { Err::<(), _>(FetchError::Changed.into()) }
            })
            .await
            .unwrap_err();
        assert_eq!(calls, 1);
        assert!(e.downcast_ref::<FetchError>().is_some());

        let mut calls = 0;
        let e = retry
            .run(&cancel, || {
                calls += 1;
                async { Err::<(), _>(FetchError::Stalled.into()) }
            })
            .await
            .unwrap_err();
        assert_eq!(calls, 3);
        assert_eq!(describe(&e), "Connection stalled; gave up after 3 attempts");
    }
}
