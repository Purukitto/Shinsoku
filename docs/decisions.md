# Decisions

Why Shinsoku is built the way it is. Each entry is a choice that was made on purpose and
would be expensive to reverse; the code is the specification for everything else.

## Tech stack — Flutter + Rust via `flutter_rust_bridge` v2

- **Rust** (`core/`) is the download engine: chunking, multi-segment parallel
  downloads, queueing, resume, protocol handling. Compiled as a native library.
- **Flutter** (`app/`) is all of the UI, for Windows, Android and Linux from one
  codebase.
- **`flutter_rust_bridge` v2** generates type-safe async Dart bindings from Rust.

Considered and rejected:

- **Tauri v2** — Android support was still experimental, and a web UI was the less
  familiar stack.
- **Flutter only** — Dart's async I/O is fine for a first version but cannot match
  Rust's thread-level parallelism for a high-throughput engine.

Platform priority: Windows first, then Android, then Linux. macOS and iOS are out of
scope unless added later.

## Scope of 1.0

1.0 is a complete download manager with the same features on Android and on desktop.
[roadmap.md](roadmap.md) lists them and tracks what is built.

## Resolved

- **State management** — Riverpod (`flutter_riverpod`). Engine state is surfaced
  through providers, and widgets watch narrow slices (per row, the id list, derived
  counts) so a progress tick never rebuilds a whole screen.
- **Persistence** — engine-side, not Hive or Drift. The download list and completed
  history serialise to one JSON file written atomically by `core/src/storage/store.rs`
  (sibling temp file, then rename). Keeps download state in Rust, where it is owned.
- **Browser extension channel** — a token-protected loopback HTTP server in the Rust
  core (`core/src/capture/`), not native messaging: one fewer IPC hop, and no
  per-browser registry or manifest install. The extensions live in `extension/`
  (Chromium and Firefox MV3) and pair with a single code.
- **File integrity (MD5 / SHA-256)** — a streaming hash after completion in
  `core/src/storage/integrity.rs`. An optional expected digest, from the Add dialog or
  a capture payload, is verified; the algorithm is inferred from the digest length.
- **App settings persistence** — app-side JSON
  (`app/lib/src/services/settings_service.dart`, `settings.json` beside the download
  store), surfaced through `settingsProvider`. Values the engine applies (connections,
  simultaneous downloads, download limit, categorize, off-peak hours) are pushed into the
  core on load and on change; disk writes are debounced so slider drags do not thrash
  the file.
- **Off-peak hours and the scheduler** — one window in the engine, with two uses. A
  scheduled download (`DownloadItem.scheduled`) waits in the queue until off-peak hours
  open, and when they close it goes back to waiting, keeping its bytes, rather than
  pausing; with **Full speed off-peak** on, the limiter also runs unthrottled inside
  them. One window rather than a scheduler with its own times, because both answer the
  same question — when the connection is free or cheap — and a second pair of times
  would only have to be kept in step with the first. The hours are minutes since local
  midnight plus a day mask (bit 0 = Monday); hours that wrap past midnight belong to
  the day they begin on, and `start == end` never opens. The aggregator re-evaluates
  them about once a second (`core/src/queue/manager.rs`), so crossing an edge starts or
  stops scheduled downloads and flips the rate on its own. A scheduled download cut off
  by quitting comes back waiting, not paused, since it runs unattended.
  **Cap upload / seeding** has no engine counterpart — there is no upload path — so the
  setting persists but does nothing until torrent support lands.
- **HLS stream capture (M3U8)** — an engine path, not a separate manager.
  `DownloadItem.kind` discriminates `Http` and `Hls`; `run_hls` in
  `core/src/queue/manager.rs` parses the playlist (`core/src/protocols/hls.rs`), picks
  the highest-bitrate variant, downloads segments with `buffered(N)` (bounded
  concurrency, ordered append), decrypts AES-128 (`aes`, `cbc`) and concatenates to one
  file — `.ts`, or `.mp4` when there is an fMP4 init map. Video on demand only: a
  playlist without `#EXT-X-ENDLIST` is rejected; `SAMPLE-AES`, DASH and remuxing are out
  of scope. Progress is segment-count based but travels in the byte fields:
  `downloaded_bytes` is committed bytes (the exact resume anchor — resume truncates the
  temp file to it) and `total_bytes` a self-refining estimate. Detection is a
  `webRequest` sniffer in `extension/shared/background.js` feeding the toolbar popup,
  which posts to `/api/add-stream`; pasting an `.m3u8` URL into Add also works, because
  `probe_url` flags it and the app calls `add_stream`.
- **Retry and failure handling** — in the engine, per segment.
  `run_segments` (`core/src/engine/orchestrator.rs`) gives each segment its own retry
  loop, so one bad connection reconnects from its own offset while the others keep
  going; only a permanent failure, or one that outlasts the budget, cancels the rest.
  `core/src/engine/retry.rs` decides what is worth retrying: dropped or stalled
  connections, timeouts, 408, 425, 429 and most 5xx. Missing files, denied access,
  416, disk errors and a changed file are not. Backoff is 0, 1, 2, 4… up to 30 s
  with jitter. A segment gives up after 9 retries in a row during which the
  **download as a whole** made no progress: a host that caps connections per client
  answers the extra segments with 503, and those segments must wait for a slot, not
  fail a download that is still moving. Stalls are a 30 s timeout on response
  headers and on each body read; connecting has its own 15 s timeout.
- **Segment offsets count flushed bytes only.** `SegmentWriter`
  (`core/src/storage/partial.rs`) advances the segment counter after a flush, never on
  a buffered write, and every exit path flushes. The counter is the resume anchor that
  the aggregator checkpoints, so counting buffered bytes let an error, a crash or
  **Quit** record an offset past the data on disk, and resume left a hole of zeros.
  Flushes happen every 256 KiB or 50 ms, so progress still moves on slow links.
- **Range responses are checked, not trusted.** A ranged request must come back
  `206` with a `Content-Range` that starts at the requested byte and, when it states
  a size, matches the planned one. A `200` is accepted only for a segment that starts
  at byte 0, which restarts from there, and writes never pass the segment's end.
  Change detection is the size check, not `If-Range`: CDN edges that disagree on an
  `ETag`, or a `Last-Modified` stamped per request, would turn working downloads
  into hard failures.
- **Refreshing a link** — in the engine. `QueueManager::refresh_url`
  (`core/src/queue/manager.rs`) swaps a stopped download's link only after checking
  that the new one serves the same file: the same size, read from a one-byte ranged
  `GET` (`probe_range` in `core/src/protocols/http.rs`, because some hosts answer
  `HEAD` differently from `GET`), or for HLS the same number of segments. Then the
  download resumes from the bytes it kept. A download that wrote nothing has no file to
  match, and its old plan may be sized from an error page, so it is probed again from
  scratch. The Refresh link dialog also arms `await_link`: while it is open, the next
  link the extension sends goes to that download, with the browser's fresh cookies,
  instead of becoming a new one. A refused link gets `409` and the reason, so the
  extension leaves the browser's own download alone. Each item records the folder it
  was added to (`dest_dir`), so a second plan puts the file under that folder rather
  than inside the first plan's category subfolder.
- **Starting at sign-in, and one copy at a time** — app-side, with the operating system
  as the source of truth: `app/lib/src/services/autostart_service.dart` writes the
  per-user `Run` key on Windows (an XDG autostart entry on Linux) and reads it back,
  rather than keeping a flag in `settings.json` that Task Manager could contradict;
  Task Manager's **Disable** mark in `StartupApproved\Run` counts as off. The entry
  launches with `--autostart`, which the Windows runner reads to skip showing the
  window, so the app starts in the tray. Starting with the system makes a second copy
  likely — opened from the Start menu while the first sits in the tray — and two copies
  would run two engines over the same download files, so the runner holds a per-session
  mutex (`windows/runner/main.cpp`): a second launch finds the first copy's window by a
  window property and posts it a message, which reaches Dart over the
  `shinsoku/instance` channel and shows the window, then exits. `launch_at_startup`
  was not used: it pins an older `win32` than `package_info_plus` needs. Android is
  not done: starting on boot needs only the normal `RECEIVE_BOOT_COMPLETED`
  permission, but Android 15 no longer lets a boot receiver start a `dataSync`
  service, so it needs another way to resume downloads.
- **The Android build** — a Gradle task, `buildRustEngine` in
  `app/android/app/build.gradle.kts`, runs `cargo ndk` before every build and packages
  `libshinsoku_core.so` for each ABI, the way the Windows CMake target bundles the DLL;
  not cargokit, so both platforms build the engine the same plain way. It builds only
  the ABIs Flutter asks for, so `flutter run` on a phone compiles one. The minimum is
  Android 11 (API 30): from there an app can create files in the shared Download folder
  by path without a storage permission, which the engine needs because it writes by
  path. `MainActivity` hands Dart that folder's path over `shinsoku/storage`, and
  downloads go to `Download/Shinsoku`, where people's file managers show them.
  Supporting Android 10 and older would mean the system file picker or MediaStore
  copies instead. Phones get their own shell (`app/lib/src/ui/mobile/`): tabs along the
  bottom, a compact download row, and each download's page pushed as a route so the
  back gesture works. The detail, add, settings and completed screens are shared with
  desktop and stack into one column below 600 logical pixels (`isCompact`). Window,
  tray, autostart and the extension's capture server stay desktop only (`isDesktop`).
- **Downloading in the background on Android, and progress outside the window** — a
  foreground service of type `dataSync` (`DownloadService.kt`) holds the process in
  the foreground while anything is downloading or queued to start; without it Android
  freezes the app the moment it leaves the screen. Its notification is the progress
  view: a low-importance channel, so it sits in the shade and status bar without sound
  or a pop-up. The engine lives in Dart's isolate, so the Flutter engine is started by
  `ShinsokuApplication` and cached rather than created by the activity: closing the
  window leaves Dart and the downloads running. Dart decides when the service runs and
  what it says (`progressReporterProvider`, from a `ProgressSummary` of the list),
  pushing about once a second and at once when a download starts or stops; the same
  summary is the tray's hover text on Windows and a line atop its menu on Linux, which
  has no hover text. Android only lets an app start the service while it is on screen,
  so a download that starts later — an off-peak one, say — runs only once the app is
  opened. Android 15 caps `dataSync` at six hours a day, after which the service stops
  and downloads carry on only while the app is open; user-initiated data transfer jobs
  (Android 14 and later) have no such cap and are the way past it if that proves too
  tight. Asking for the notification permission waits for the first download.
- **CI/CD** — GitHub Actions. `ci.yml`: version check (Ubuntu), Rust fmt, clippy and
  tests (Ubuntu), Flutter format check, analyze and tests (Windows), a Linux build
  that launches under Xvfb (Ubuntu), and debug APKs of both Android flavors, checking
  the foss one carries no Google code (Ubuntu). `release.yml`: a `v*` tag or a manual
  dispatch builds Windows, packages the extensions and checksums, and opens a draft
  GitHub Release; then it builds the foss APKs, signed with the release key from the
  repository secrets, adds them to the draft, and keeps the Play bundle as an
  artifact; then it adds a Linux x64 tarball. The Linux build, in CI and in the
  release, runs on a pinned Ubuntu 24.04 image rather than `ubuntu-latest`: the
  image's glibc is the oldest one the build runs on, and the release notes name it.
  A distribution package (AppImage, Flatpak or `.deb`) is still to choose.
- **Store builds** — two Android flavors from one codebase. `foss` is what GitHub
  releases, F-Droid and source builds ship: no Google code at all, which F-Droid
  requires, and CI checks the APK for it. `play` is the Google Play build. It skips
  the GitHub update check, since Play updates the app and its rules forbid pointing
  anywhere else for updates, and it is the only place Play Billing will go. Play
  rejects donation links unless they go to a validated tax-exempt organisation, so
  supporting the project from the Play build has to go through Play Billing. Its code
  will be our own Kotlin in `src/play/`, not the `in_app_purchase` plugin: a Flutter
  plugin can't be limited to one flavor, so the plugin would put the billing library
  in the foss build too. The Dart side reads the flavor through `appFlavor`
  (`app/lib/src/store.dart`). Desktop builds have no flavor and count as foss. Android
  builds always name the flavor. `default-flavor` in `pubspec.yaml` would spare that,
  but it applies to desktop builds too, and newer Flutter versions then move their
  output under a flavor directory. The play code stays in this repository, and the
  README's licence section adds a GPLv3 section 7 permission to link with the Play
  Billing Library.

## Open

- **Theming system**, once design assets for it are provided.
- **Committing generated bridge files.** They are committed today: CI and release
  builds use them and never run codegen, so they must be regenerated and committed in
  the same commit as any change to `core/src/api.rs`.
