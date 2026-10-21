//! Minimal HLS (M3U8) playlist parser + AES-128 segment decryption. Covers the
//! VOD subset Shinsoku downloads: master variant selection, media segment lists,
//! `#EXT-X-KEY` (AES-128 / NONE / SAMPLE-AES), `#EXT-X-MAP` (fMP4 init), and
//! `#EXT-X-ENDLIST`. Live playlists (no ENDLIST) and SAMPLE-AES are handled by
//! the caller. The format is line-based, so a hand-rolled parser avoids a dep;
//! `url::Url::join` resolves relative/scheme-relative/absolute segment URIs.

use anyhow::{anyhow, Result};
use url::Url;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum KeyMethod {
    None,
    Aes128,
    SampleAes,
}

#[derive(Debug, Clone)]
pub struct KeyInfo {
    pub method: KeyMethod,
    /// Key location; `None` for `METHOD=NONE`.
    pub uri: Option<Url>,
    /// Explicit IV if the tag carried one; otherwise derive from the sequence number.
    pub iv: Option<[u8; 16]>,
}

#[derive(Debug, Clone)]
pub struct MediaSegment {
    pub url: Url,
    /// Encryption in force for this segment; `None` when unencrypted.
    pub key: Option<KeyInfo>,
    /// Media sequence number (for sequence-derived IVs).
    pub seq: u64,
}

#[derive(Debug, Clone)]
pub struct MediaPlaylist {
    pub segments: Vec<MediaSegment>,
    /// `#EXT-X-MAP` init segment (fMP4 streams); present → output is `.mp4`.
    pub init: Option<Url>,
    /// `#EXT-X-ENDLIST` seen → VOD (finite). False ⇒ live, which we refuse.
    pub endlist: bool,
}

#[derive(Debug, Clone)]
pub struct Variant {
    pub url: Url,
    pub bandwidth: u64,
    pub resolution: Option<String>,
}

#[derive(Debug, Clone)]
pub enum Playlist {
    Master(Vec<Variant>),
    Media(MediaPlaylist),
}

/// Parse a playlist, resolving URIs against `base` (the playlist's own URL).
pub fn parse(text: &str, base: &Url) -> Result<Playlist> {
    if !text.contains("#EXTM3U") {
        return Err(anyhow!("not an M3U8 playlist"));
    }
    if text.contains("#EXT-X-STREAM-INF") {
        Ok(Playlist::Master(parse_master(text, base)))
    } else {
        Ok(Playlist::Media(parse_media(text, base)?))
    }
}

/// Highest-bitrate variant.
pub fn pick_best(variants: &[Variant]) -> Option<&Variant> {
    variants.iter().max_by_key(|v| v.bandwidth)
}

fn parse_master(text: &str, base: &Url) -> Vec<Variant> {
    let mut variants = Vec::new();
    let mut pending: Option<(u64, Option<String>)> = None;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("#EXT-X-STREAM-INF:") {
            let attrs = parse_attrs(rest);
            let bw = attr(&attrs, "BANDWIDTH")
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            let res = attr(&attrs, "RESOLUTION").map(|s| s.to_string());
            pending = Some((bw, res));
        } else if line.starts_with('#') {
            continue;
        } else if let Some((bandwidth, resolution)) = pending.take() {
            if let Ok(url) = base.join(line) {
                variants.push(Variant {
                    url,
                    bandwidth,
                    resolution,
                });
            }
        }
    }
    variants
}

fn parse_media(text: &str, base: &Url) -> Result<MediaPlaylist> {
    let mut segments = Vec::new();
    let mut init = None;
    let mut endlist = false;
    let mut media_seq: u64 = 0;
    let mut cur_key: Option<KeyInfo> = None;
    let mut next_is_segment = false;
    let mut idx: u64 = 0;

    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("#EXT-X-MEDIA-SEQUENCE:") {
            media_seq = rest.trim().parse().unwrap_or(0);
        } else if let Some(rest) = line.strip_prefix("#EXT-X-KEY:") {
            cur_key = Some(parse_key(rest, base));
        } else if let Some(rest) = line.strip_prefix("#EXT-X-MAP:") {
            if init.is_none() {
                let attrs = parse_attrs(rest);
                init = attr(&attrs, "URI").and_then(|u| base.join(u).ok());
            }
        } else if line.starts_with("#EXTINF") {
            next_is_segment = true;
        } else if line == "#EXT-X-ENDLIST" {
            endlist = true;
        } else if line.starts_with('#') {
            continue;
        } else if next_is_segment {
            next_is_segment = false;
            let url = base
                .join(line)
                .map_err(|e| anyhow!("bad segment url {line:?}: {e}"))?;
            // METHOD=NONE means "encryption turned off" → treat as plaintext.
            let key = match &cur_key {
                Some(k) if k.method == KeyMethod::None => None,
                other => other.clone(),
            };
            segments.push(MediaSegment {
                url,
                key,
                seq: media_seq + idx,
            });
            idx += 1;
        }
    }
    Ok(MediaPlaylist {
        segments,
        init,
        endlist,
    })
}

fn parse_key(rest: &str, base: &Url) -> KeyInfo {
    let attrs = parse_attrs(rest);
    let method = match attr(&attrs, "METHOD") {
        Some(m) if m.eq_ignore_ascii_case("AES-128") => KeyMethod::Aes128,
        Some(m) if m.eq_ignore_ascii_case("SAMPLE-AES") => KeyMethod::SampleAes,
        _ => KeyMethod::None,
    };
    let uri = if method == KeyMethod::None {
        None
    } else {
        attr(&attrs, "URI").and_then(|u| base.join(u).ok())
    };
    let iv = attr(&attrs, "IV").and_then(parse_hex_iv);
    KeyInfo { method, uri, iv }
}

/// IV for AES-128 when the key tag omits one: the segment's media sequence number
/// as a big-endian 128-bit value (RFC 8216 §5.2).
pub fn derive_iv(seq: u64) -> [u8; 16] {
    let mut iv = [0u8; 16];
    iv[8..].copy_from_slice(&seq.to_be_bytes());
    iv
}

/// Decrypt one AES-128-CBC segment in place (PKCS7-padded), returning the
/// plaintext. `data` is consumed to avoid a copy.
pub fn decrypt_segment(mut data: Vec<u8>, key: &[u8; 16], iv: &[u8; 16]) -> Result<Vec<u8>> {
    use aes::Aes128;
    use cbc::cipher::{block_padding::Pkcs7, BlockModeDecrypt, KeyIvInit};
    type Dec = cbc::Decryptor<Aes128>;

    let len = {
        let pt = Dec::new(key.into(), iv.into())
            .decrypt_padded::<Pkcs7>(&mut data)
            .map_err(|_| anyhow!("AES-128 decrypt failed (bad key or padding)"))?;
        pt.len()
    };
    data.truncate(len);
    Ok(data)
}

// ── attribute-list parsing ──────────────────────────────────────────────────

/// Split an HLS attribute list (`A=1,B="x,y",C=3`) into pairs, honouring quotes.
fn parse_attrs(s: &str) -> Vec<(String, String)> {
    let b = s.as_bytes();
    let n = b.len();
    let mut out = Vec::new();
    let mut i = 0;
    while i < n {
        let key_start = i;
        while i < n && b[i] != b'=' {
            i += 1;
        }
        if i >= n {
            break;
        }
        let key = s[key_start..i].trim().to_string();
        i += 1; // '='
        let value = if i < n && b[i] == b'"' {
            i += 1;
            let vs = i;
            while i < n && b[i] != b'"' {
                i += 1;
            }
            let v = s[vs..i].to_string();
            while i < n && b[i] != b',' {
                i += 1; // past closing quote to the comma
            }
            v
        } else {
            let vs = i;
            while i < n && b[i] != b',' {
                i += 1;
            }
            s[vs..i].trim().to_string()
        };
        out.push((key, value));
        if i < n && b[i] == b',' {
            i += 1;
        }
    }
    out
}

fn attr<'a>(attrs: &'a [(String, String)], name: &str) -> Option<&'a str> {
    attrs
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v.as_str())
}

fn parse_hex_iv(s: &str) -> Option<[u8; 16]> {
    let h = s.trim();
    let h = h
        .strip_prefix("0x")
        .or_else(|| h.strip_prefix("0X"))
        .unwrap_or(h);
    if h.len() != 32 {
        return None;
    }
    let mut iv = [0u8; 16];
    for (i, slot) in iv.iter_mut().enumerate() {
        *slot = u8::from_str_radix(&h[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(iv)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> Url {
        Url::parse("https://cdn.example.com/v/playlist.m3u8").unwrap()
    }

    #[test]
    fn master_picks_highest_bitrate() {
        let text = "#EXTM3U\n\
            #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n\
            low/index.m3u8\n\
            #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS=\"avc1,mp4a\"\n\
            hi/index.m3u8\n";
        let Playlist::Master(vs) = parse(text, &base()).unwrap() else {
            panic!("expected master");
        };
        assert_eq!(vs.len(), 2);
        let best = pick_best(&vs).unwrap();
        assert_eq!(best.bandwidth, 2_500_000);
        assert_eq!(best.url.as_str(), "https://cdn.example.com/v/hi/index.m3u8");
        assert_eq!(best.resolution.as_deref(), Some("1280x720"));
    }

    #[test]
    fn media_segments_and_endlist() {
        let text = "#EXTM3U\n\
            #EXT-X-VERSION:3\n\
            #EXT-X-TARGETDURATION:10\n\
            #EXT-X-MEDIA-SEQUENCE:0\n\
            #EXTINF:9.0,\n\
            seg0.ts\n\
            #EXTINF:9.0,\n\
            https://other.example.com/seg1.ts\n\
            #EXTINF:3.0,\n\
            seg2.ts\n\
            #EXT-X-ENDLIST\n";
        let Playlist::Media(m) = parse(text, &base()).unwrap() else {
            panic!("expected media");
        };
        assert!(m.endlist);
        assert!(m.init.is_none());
        assert_eq!(m.segments.len(), 3);
        // relative resolves against the playlist dir; absolute is kept as-is
        assert_eq!(
            m.segments[0].url.as_str(),
            "https://cdn.example.com/v/seg0.ts"
        );
        assert_eq!(
            m.segments[1].url.as_str(),
            "https://other.example.com/seg1.ts"
        );
        assert!(m.segments.iter().all(|s| s.key.is_none()));
        assert_eq!(m.segments[2].seq, 2);
    }

    #[test]
    fn live_playlist_has_no_endlist() {
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg.ts\n";
        let Playlist::Media(m) = parse(text, &base()).unwrap() else {
            panic!("expected media");
        };
        assert!(!m.endlist);
    }

    #[test]
    fn encrypted_with_map_and_explicit_iv() {
        let text = "#EXTM3U\n\
            #EXT-X-MAP:URI=\"init.mp4\"\n\
            #EXT-X-KEY:METHOD=AES-128,URI=\"https://k.example.com/key.bin\",IV=0x000102030405060708090a0b0c0d0e0f\n\
            #EXTINF:4.0,\n\
            seg0.m4s\n\
            #EXTINF:4.0,\n\
            seg1.m4s\n\
            #EXT-X-ENDLIST\n";
        let Playlist::Media(m) = parse(text, &base()).unwrap() else {
            panic!("expected media");
        };
        assert_eq!(
            m.init.as_ref().unwrap().as_str(),
            "https://cdn.example.com/v/init.mp4"
        );
        let k = m.segments[0].key.as_ref().unwrap();
        assert_eq!(k.method, KeyMethod::Aes128);
        assert_eq!(
            k.uri.as_ref().unwrap().as_str(),
            "https://k.example.com/key.bin"
        );
        assert_eq!(k.iv.unwrap()[15], 0x0f);
    }

    #[test]
    fn method_none_clears_encryption() {
        let text = "#EXTM3U\n\
            #EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n\
            #EXTINF:1,\na.ts\n\
            #EXT-X-KEY:METHOD=NONE\n\
            #EXTINF:1,\nb.ts\n#EXT-X-ENDLIST\n";
        let Playlist::Media(m) = parse(text, &base()).unwrap() else {
            panic!("expected media");
        };
        assert!(m.segments[0].key.is_some());
        assert!(m.segments[1].key.is_none());
    }

    #[test]
    fn derive_iv_from_sequence() {
        assert_eq!(derive_iv(1)[15], 1);
        assert_eq!(derive_iv(1)[..8], [0u8; 8]);
        assert_eq!(derive_iv(0x0102), derive_iv(258));
    }

    #[test]
    fn aes128_round_trip() {
        use aes::Aes128;
        use cbc::cipher::{block_padding::Pkcs7, BlockModeEncrypt, KeyIvInit};
        type Enc = cbc::Encryptor<Aes128>;

        let key = [0x11u8; 16];
        let iv = derive_iv(42);
        let plain = b"the quick brown fox jumps over 13 lazy dogs!!".to_vec();

        let mut buf = plain.clone();
        let pad_len = 16 - (buf.len() % 16);
        buf.resize(buf.len() + pad_len, 0); // room for PKCS7 padding
        let ct_len = Enc::new(&key.into(), &iv.into())
            .encrypt_padded::<Pkcs7>(&mut buf, plain.len())
            .unwrap()
            .len();
        buf.truncate(ct_len);

        let decrypted = decrypt_segment(buf, &key, &iv).unwrap();
        assert_eq!(decrypted, plain);
    }
}
