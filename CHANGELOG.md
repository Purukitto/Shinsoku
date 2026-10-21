# Changelog

All notable changes to Shinsoku are documented here. Each version's section is also its
GitHub release notes.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Before
1.0.0, a minor version may change the download store, the settings file or the
browser-capture API in a way an older build or extension cannot read; when it does,
the entry is marked **Breaking** under **Changed**.

## [Unreleased]

### Added

- **Multi-segment download engine** in Rust. Each HTTP/HTTPS download is split into up
  to 16 parallel byte-range segments (8 by default), each streamed straight into its
  slot of a preallocated file over one shared, keep-alive connection pool.
- **Exact pause and resume.** Segments resume from the byte they reached, across app
  restarts. A download that was running when the app closed comes back paused.
- **Queue** with a limit on how many downloads run at once (3 by default); the rest
  wait and start in turn.
- **Global speed limit**, and an **off-peak window** that lifts it between two times
  you choose (23:00–07:00 by default, wrapping past midnight). The window is
  re-checked every second, so crossing its edge changes the speed with no action.
- **Checksums.** Every finished file is hashed in the background. Give an expected
  MD5 or SHA-256 digest in the Add dialog and the detail screen shows **VERIFIED** or
  **MISMATCH**.
- **Custom request headers** per download, under **Advanced** in the Add dialog, for
  hosts that want a referrer or a token.
- **HLS stream capture.** Paste an `.m3u8` link, or send one from the extension:
  Shinsoku picks the highest-bitrate variant, downloads segments with bounded
  concurrency, decrypts AES-128 and joins them in order into one `.ts`, or `.mp4` for
  fragmented-MP4 streams. Resumes from the last whole segment.
- **Browser extension** for Chromium browsers and Firefox. It hands downloads to the
  app with the site's cookies, referrer and User-Agent, and cancels the browser's own
  download only once the app has accepted it. Its toolbar popup lists HLS streams on
  the page with quality, estimated size and name, folding per-quality playlists into
  their master.
- **Single-code pairing** between app and extension over a token-protected loopback
  server, with a live connection status in Settings. Off until you turn it on.
- **Clipboard monitor** that offers to download a copied link.
- **Categorize** finished files into `Videos`, `Images`, `Documents`, `Music`,
  `Programs`, `Compressed` and `Other` folders. A name already taken saves as
  `file (2).ext` rather than overwriting.
- **History.** The download list and the 500 most recent finished downloads survive
  restarts, along with every setting.
- **Update notice.** At launch the app checks for a newer release and the sidebar's
  version line becomes **Update available**, linking to the release page.
- **Desktop app** for Windows: active, completed, detail and settings screens, live
  throughput graph and per-segment progress, minimise to tray, custom frameless
  window, bundled fonts.

### Known limitations

- Windows only. Android and Linux builds are not wired yet.
- Portable zip only, no installer. The binaries are unsigned, so SmartScreen warns on
  first launch.
- A failed download stops with its error. There is no automatic retry yet.
- No queue priorities and no per-download speed limit.
- HLS is video on demand only: live streams, DASH and `SAMPLE-AES` are refused, and
  nothing is remuxed.
- `blob:` and `data:` downloads cannot be captured; the browser saves those itself.
- The Firefox extension is unsigned and loads as a temporary add-on, which Firefox
  forgets on restart.
- **Cap upload / seeding** in Settings is saved but has no effect: there is no upload
  path until torrent support exists.
- Request headers attached to a download, including forwarded cookies, are stored in
  plain text in the app's data folder.

[Unreleased]: https://github.com/Purukitto/Shinsoku/commits/main
