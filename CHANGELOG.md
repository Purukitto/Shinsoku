# Changelog

All notable changes to Shinsoku are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Multi-segment parallel HTTP/HTTPS download engine (Rust) with pause, resume and auto-retry.
- Download queue with priorities, simultaneous-download limit, and global/per-download throttling.
- Off-peak acceleration window (engine-side; wraps past midnight).
- File integrity verification (streaming SHA-256 / MD5) with optional expected-digest check.
- HLS (`.m3u8`) video capture: highest-bitrate variant, bounded-concurrency segment download,
  AES-128 decryption, concatenation to a single `.ts`/`.mp4` (VOD).
- Browser extension (Chromium + Firefox MV3) with token-protected loopback capture,
  forwarding cookies, referrer and User-Agent; toolbar HLS stream detection.
- Extension popup labels each detected stream with quality, an estimated size and the
  playlist filename, and collapses per-quality variant playlists into their master.
- Clipboard link monitoring and auto-categorization of completed files.
- Desktop UI (Flutter): active/completed/detail/settings screens, system tray, custom
  frameless window, dark "voltage" theme.
- In-app version display in the sidebar and a GitHub-release update checker that opens the
  release page when a newer version is available.
- Engine-owned atomic JSON persistence for the download list and history; app-side settings JSON.

### Project / repo
- Open-source repository scaffolding: README, GPL-3.0 license, contributing guide,
  security policy, issue/PR templates, and CI.
- Screenshot harness (`flutter run -t lib/main_screenshots.dart`) with deterministic mock
  data and one-key PNG capture, plus `tool/` capture helpers.
- `tool/bump-version.ps1` to bump the app, core and extension versions in lockstep and roll
  the changelog; versioning + changelog policy documented in the contributing guide.
- Release workflow (`.github/workflows/release.yml`): pushing a `vX.Y.Z` tag builds the Windows
  app and the browser extension and publishes a GitHub Release that the in-app updater reads.

[Unreleased]: https://github.com/purukitto/Shinsoku/commits/main
