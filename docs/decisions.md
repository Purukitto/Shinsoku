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
