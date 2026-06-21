//! File integrity hashing. Computed once a download finishes (off the async
//! pool — see the queue manager) and, when the caller supplied an expected
//! digest, checked against it.

use std::fmt::Write as _;
use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

use md5::Md5;
use sha2::{Digest, Sha256};

/// 64 KiB read buffer — large enough to keep syscalls cheap, small enough to
/// stay off a worst-case thread stack; streamed so files never load whole.
const BUF: usize = 1 << 16;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum HashAlgo {
    Sha256,
    Md5,
}

impl HashAlgo {
    /// Pick the algorithm a digest string implies: 32 hex chars is MD5,
    /// anything else (64 = SHA-256) defaults to SHA-256.
    pub fn for_expected(expected: &str) -> Self {
        if expected.trim().len() == 32 {
            HashAlgo::Md5
        } else {
            HashAlgo::Sha256
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            HashAlgo::Sha256 => "sha256",
            HashAlgo::Md5 => "md5",
        }
    }
}

/// Stream `path` through `algo`, returning the lowercase hex digest.
pub fn hash_file(path: &Path, algo: HashAlgo) -> io::Result<String> {
    match algo {
        HashAlgo::Sha256 => hash_with::<Sha256>(path),
        HashAlgo::Md5 => hash_with::<Md5>(path),
    }
}

fn hash_with<D: Digest>(path: &Path) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = D::new();
    let mut buf = vec![0u8; BUF];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex(hasher.finalize().as_slice()))
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(s, "{:02x}", b);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_tmp(tag: &str, bytes: &[u8]) -> std::path::PathBuf {
        let p =
            std::env::temp_dir().join(format!("shinsoku_hash_{tag}_{}.bin", std::process::id()));
        let mut f = File::create(&p).unwrap();
        f.write_all(bytes).unwrap();
        p
    }

    #[test]
    fn sha256_matches_known_vector() {
        let p = write_tmp("sha", b"abc");
        let got = hash_file(&p, HashAlgo::Sha256).unwrap();
        let _ = std::fs::remove_file(&p);
        assert_eq!(
            got,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn md5_matches_known_vector() {
        let p = write_tmp("md5", b"abc");
        let got = hash_file(&p, HashAlgo::Md5).unwrap();
        let _ = std::fs::remove_file(&p);
        assert_eq!(got, "900150983cd24fb0d6963f7d28e17f72");
    }

    #[test]
    fn algo_inferred_from_length() {
        assert!(HashAlgo::for_expected(&"a".repeat(32)) == HashAlgo::Md5);
        assert!(HashAlgo::for_expected(&"a".repeat(64)) == HashAlgo::Sha256);
    }
}
