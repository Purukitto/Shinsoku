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
- **Automatic retry.** A connection that drops, stalls for 30 seconds or meets a busy
  server (HTTP 429 or 5xx) reconnects on its own and carries on from the byte it
  reached, while the other segments keep going. A download stops only on an error a
  retry can't fix (a missing file, denied access, an expired link) or after about two
  minutes with no progress at all. The detail screen counts the reconnects.
- **Failure reasons.** A download that stops says why, in the list and on its detail
  screen, and offers **Retry**.
- **Refresh link.** When a link expires, give the stopped download a new one and it
  carries on from the bytes it kept. Paste the link into **Refresh link** on the
  download, or, with the extension paired, start the download again on its page while
  the dialog is open and Shinsoku takes the browser's new link and cookies instead of
  adding a download. A link to a different file (another size, or a stream with
  another number of segments) is refused and the download keeps its old one.
- **Resume safety.** A server that ignores the requested byte range, or a file whose
  size changed on the server, stops the download with an error instead of leaving a
  corrupt file.
- **Queue** with a limit on how many downloads run at once (3 by default); the rest
  wait and start in turn.
- **Global speed limit**, and **Full speed off-peak**, which lifts it during off-peak
  hours (23:00–07:00 every day by default, wrapping past midnight). The hours are
  re-checked every second, so crossing their edge changes the speed with no action.
- **Scheduled downloads.** Turn on **Schedule for off-peak** in the Add dialog, or press
  **Schedule** on a download's detail screen, and it waits for off-peak hours, starts
  when they begin and stops when they end, carrying on from the bytes it has the next
  time. Pick the days in **Settings → Scheduling**. **Start now** runs a waiting
  download at once, and one cut off by quitting waits for the next off-peak hours
  instead of coming back paused.
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
