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
  simultaneous downloads, download limit, categorize, off-peak) are pushed into the
  core on load and on change; disk writes are debounced so slider drags do not thrash
  the file.
- **Off-peak acceleration** — an engine feature, not UI-only. The limiter's effective
  rate is unthrottled inside the configured window and the user's download limit
  outside it. The aggregator re-evaluates the window about once a second, so crossing
  its edge flips the rate on its own (`core/src/queue/manager.rs`). The window wraps
  past midnight; `start == end` is inert. **Cap upload / seeding** has no engine
  counterpart — there is no upload path — so the setting persists but does nothing
  until torrent support lands.
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
- **CI/CD** — GitHub Actions. `ci.yml`: version check (Ubuntu), Rust fmt, clippy and
  tests (Ubuntu), Flutter format check, analyze and tests (Windows). `release.yml`: a
  `v*` tag or a manual dispatch builds Windows, packages the extensions and checksums,
  and opens a draft GitHub Release. Android and Linux release jobs arrive with their
  native build wiring.

## Open

- **Theming system**, once design assets for it are provided.
- **Committing generated bridge files.** They are committed today: CI and release
  builds use them and never run codegen, so they must be regenerated and committed in
  the same commit as any change to `core/src/api.rs`.
