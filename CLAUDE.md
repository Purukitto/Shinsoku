# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Shinsoku — Download Manager

Cross-platform download manager targeting Windows (primary), Android, then Linux. Priority is speed and functionality.

## Tech Stack Decision

**Flutter + Rust via `flutter_rust_bridge` v2**

- **Rust** (`core/`) — download engine: chunking, multi-segment parallel downloads, queue management, resume logic, protocol handling. Compiled as a native library.
- **Flutter** (`app/`) — all UI across Windows, Android, Linux from a single codebase.
- **`flutter_rust_bridge` v2** — generates type-safe async Dart bindings from Rust. Production-ready as of 2025.

Alternatives considered and rejected:
- Tauri v2: Android support still experimental; web UI less familiar to the developer.
- Flutter-only: Dart's async I/O is fine for v1 but can't match Rust's true thread-level parallelism for a high-performance engine.

## Monorepo Structure

```
Shinsoku/
├── app/                    # Flutter app — Windows, Android, Linux
│   ├── android/
│   ├── windows/
│   ├── linux/
│   ├── lib/
│   │   ├── src/
│   │   │   ├── rust/       # Auto-generated flutter_rust_bridge bindings (do not edit)
│   │   │   ├── ui/         # Screens and widgets
│   │   │   ├── providers/  # State management
│   │   │   └── models/     # Dart-side data models
│   │   └── main.dart
│   ├── rust/               # Symlink or path reference → ../core
│   └── pubspec.yaml
├── core/                   # Rust download engine (libshinsoku)
│   ├── src/
│   │   ├── lib.rs          # flutter_rust_bridge API surface
│   │   ├── engine/         # Multi-segment download logic
│   │   ├── queue/          # Download queue and scheduler
│   │   ├── protocols/      # HTTP/HTTPS (+ future: FTP, magnet)
│   │   └── storage/        # File assembly and partial files
│   └── Cargo.toml
├── packages/               # Shared Dart/Flutter packages (UI kit, etc.)
├── docs/
│   ├── screenshots/        # README gallery (from the mock-data harness)
│   └── assets/             # logo / icon
├── .github/
│   └── workflows/
├── CLAUDE.md               # This file
└── README.md
```

## Architecture — state flow across the bridge

The engine runs entirely in Rust and **owns all download state**; Flutter is a thin reactive
view. One progress round-trip explains most of the codebase:

1. **API surface** (`core/src/api.rs`) is the *only* module flutter_rust_bridge scans
   (`rust_input: crate::api`; see `app/flutter_rust_bridge.yaml`). Keep it thin: an opaque
   `ShinsokuEngine` wrapping a `QueueManager`, `#[frb(sync)]` control fns (add/pause/resume/
   remove, settings setters, capture server) and one `subscribe_progress` stream sink.
   Everything under `engine/`/`queue/`/`protocols/`/`storage/` is bridge-independent.
2. **Engine core** is `QueueManager` + `Shared` state behind `Arc` (`core/src/queue/manager.rs`):
   an items map under `RwLock`, a shared `reqwest::Client`, a `RateLimiter`, per-download
   cancel tokens, and a single Tokio `Runtime`. A ~250 ms aggregator tick reads per-segment
   atomics, derives speed (60-sample history), re-evaluates the off-peak window, checkpoints
   to disk, and pushes a `DownloadProgress` to the sink. `fetch_plan` (`engine/orchestrator.rs`)
   probes + splits into byte-range segments; `download_segment` (`engine/worker.rs`) streams
   each range into its slot of a preallocated file (rate-limited, resumable); `storage/`
   assembles + hashes. HLS uses a separate `run_hls` path in the manager.
3. **Dart mapping layer** (`app/lib/src/providers/downloads_provider.dart`) is where Rust → UI
   happens. `subscribeProgress` feeds `DownloadsNotifier`; light ticks patch the existing list
   item in place, and only *structural* changes (status flip, size first known) trigger a full
   `getDownloads` refetch. Rust types map to Dart view models in `models/`.
4. **Narrow watching is the performance contract.** The list watches only an ordered *id list*
   (`visibleDownloadIdsProvider`), so it rebuilds on structural change — not every tick; each
   row watches its own item via `downloadItemProvider(id).select`; the detail screen polls a
   per-id `liveDownloadProvider`; the throughput sparkline owns its timer. Preserve this shape —
   a broad `watch` on the whole list reintroduces per-tick whole-screen rebuilds.

Persistence, the capture server, integrity, off-peak and HLS specifics live in **Resolved
Decisions** below.

## Platform Priority

1. **Windows** — primary target; ship first
2. **Android** — second target
3. **Linux** — third target (Flutter Linux is mature; low incremental cost)

macOS and iOS are out of scope unless explicitly added later.

## Core Engine Capabilities (planned)

- Multi-segment parallel downloading (configurable segments, default 8–16)
- HTTP/HTTPS with connection reuse and keep-alive
- Pause / resume (byte-range requests)
- Download queue with priority levels
- Bandwidth throttling (global and per-download)
- Auto-retry on failure
- File integrity check (MD5/SHA256)
- Browser extension integration (future)

## State Management

**Riverpod** (`flutter_riverpod`). Engine/download state lives in Rust and is surfaced through providers; the UI watches narrow slices (per-row, id-list, derived counts) so rebuilds stay tight per the performance rules.

## UI

Designer assets will be provided. Build from provided designs — do not invent layout.

## Key Libraries (planned)

| Package | Purpose |
|---|---|
| `flutter_rust_bridge` | Rust ↔ Dart FFI bridge |
| `riverpod` | State management |
| `dio` or native Rust `reqwest` | HTTP (engine side: Rust `reqwest`) |
| `hive` or `drift` | Local persistence for download history |

Rust side: `reqwest` (async HTTP), `tokio` (async runtime), `sha2`/`md-5` (integrity).

## Commands

Flutter commands run in `app/`; Rust commands in `core/`.

**Run**
- `flutter run -d windows --release` — primary target. Use `--release`/`--profile` to judge
  performance; debug rendering and throughput are not representative.
- `flutter run -d windows -t lib/main_screenshots.dart` — screenshot harness: the real app with
  deterministic mock data and one-key PNG capture (F1–F6). Wrapped by `tool/screenshots.ps1`.

**Regenerate the bridge** — required after any change to `core/src/api.rs`:
- `flutter_rust_bridge_codegen generate` (run in `app/`). Rewrites `app/lib/src/rust/` and
  `core/src/frb_generated.rs` — never hand-edit those.

**Lint / format** (CI gates on these — `.github/workflows/ci.yml`):
- Rust: `cargo fmt --all -- --check` and `cargo clippy --all-targets -- -D warnings`
- Dart: `dart format .` and `flutter analyze`

**Test**
- Rust: `cargo test` · single: `cargo test --test download <name>` (integration tests in
  `core/tests/`) or `cargo test <name>` for unit tests.
- Flutter: `flutter test` · single file: `flutter test test/foo_test.dart` · single case:
  `flutter test --plain-name "description"`.

**Browser extension** (`extension/`): edit `shared/`, then `./build.ps1` assembles
`dist/chromium` + `dist/firefox`. Never edit `dist/` directly. Load unpacked from `dist/<browser>`.

**Release / versioning**: SemVer + Keep a Changelog. `tool/bump-version.ps1 X.Y.Z` bumps
`app/pubspec.yaml`, `core/Cargo.toml` and both extension manifests in lockstep and rolls
`CHANGELOG.md`; the Windows `.exe` version flows from pubspec via CMake. Pushing a `vX.Y.Z` tag
triggers the Windows build + GitHub Release (`.github/workflows/release.yml`); the app checks
that release feed for updates. Add an `[Unreleased]` changelog entry for user-facing changes.

## Performance

Performance is a first-class requirement, not an afterthought. When choosing between approaches — data structures, algorithms, libraries, widget trees, async patterns, allocations — prefer the option with the best runtime performance and lowest resource use, as long as it does not meaningfully hurt correctness or maintainability. Default to the fast path; justify any choice that trades speed away.

Apply this everywhere:
- **Engine (Rust):** avoid needless allocations and copies; stream rather than buffer whole files; reuse connections/clients; keep hot paths lock-free or finely locked; prefer zero-copy (`bytes`) and back-pressure-aware async.
- **UI (Flutter):** keep rebuild scope tight (no app-wide `setState`/provider invalidation for localized updates); isolate frequently-repainting or animated widgets with `RepaintBoundary`; use stable keys in lists; prefer `const` widgets; avoid expensive effects (blur, large shadows) on hot paths; bundle fonts/assets instead of fetching at runtime; judge real performance in `--profile`/`--release`, never debug.
- **General:** measure before and after non-trivial perf work; avoid O(n²) and repeated work in loops/builds; cache derived values that are recomputed often.

## Code Comments

- Add a comment only when the code can't speak for itself (a non-obvious decision, constraint, or gotcha). Don't narrate what the code already says.
- Keep them short and technical. No full-paragraph explanations, no rationale prose, no friendly/AI-sounding tone.
- Prefer a terse note over a sentence; drop the comment if it's obvious.

## What Not to Do

- Do not add features beyond the agreed scope for the current milestone
- Do not put download logic in Dart — keep it in Rust
- Do not use platform channels (method channels) for the engine — use flutter_rust_bridge exclusively
- Do not commit generated bridge files to main if they can be regenerated (TBD)
- Do not include any references to Claude, Anthropic, or AI tools in commit messages, code comments, or any committed files

## Resolved Decisions

- [x] **State management** — Riverpod (`flutter_riverpod`).
- [x] **Persistence layer** — engine-side, *not* Hive/Drift. The download list + completed history serialise to a single atomic JSON file written by `core/src/storage/store.rs` (sibling temp + rename). Keeps download state in Rust per the engine boundary.
- [x] **Browser extension approach** — token-protected loopback HTTP server hosted in the Rust core (`core/src/capture/`), *not* native messaging (fewer IPC hops, no per-browser registry/manifest install). Extensions live in `extension/` (Chromium + Firefox MV3); single pairing-code handshake.
- [x] **File integrity (MD5/SHA256)** — streaming hash computed after completion in `core/src/storage/integrity.rs`; an optional expected digest (manual Add dialog or capture payload) is verified, with algorithm inferred from the digest length.
- [x] **App settings persistence** — app-side JSON (`app/lib/src/services/settings_service.dart`, `settings.json` beside the download store), surfaced via `settingsProvider`. Engine-applied values (connections, simultaneous, download limit, categorize, off-peak) are pushed into the core on load and on change; disk writes are debounced so slider drags don't thrash.
- [x] **Off-peak acceleration** — engine feature, not UI-only: the limiter's effective rate is `0` (unthrottled) inside the configured window and the user's download limit outside it. The window is re-evaluated ~1×/s in the aggregator so crossing its boundary flips the rate automatically (`core/src/queue/manager.rs`). Window wraps past midnight; `start == end` is inert. Note: "Cap upload / seeding" has no engine counterpart yet (no upload/seeding path) — the toggle persists but is inert until torrent support lands.
- [x] **HLS stream capture (M3U8)** — engine path, not a separate manager: `DownloadItem.kind` discriminates `Http`/`Hls`; `run_hls` (`core/src/queue/manager.rs`) parses the playlist (`core/src/protocols/hls.rs`), picks the highest-bitrate variant, downloads segments with `buffered(N)` (bounded concurrency, ordered append), AES-128-decrypts (`aes`/`cbc`), and concatenates to one file (`.ts`, or `.mp4` with an fMP4 init map). VOD only (no `#EXT-X-ENDLIST` ⇒ rejected); `SAMPLE-AES`/DASH/ffmpeg-remux out of scope. Progress is segment-count based, surfaced through reused byte fields: `downloaded_bytes` = committed bytes (exact resume anchor; resume truncates the temp to it), `total_bytes` = self-refining size estimate. Detection is a `webRequest` sniffer in the extension (`extension/shared/background.js`) feeding a toolbar popup that POSTs `/api/add-stream`; pasting an `.m3u8` URL into Add works too (`probe_url` flags it → `add_stream`).

## Open Decisions

- [ ] CI/CD setup (GitHub Actions target platforms)
- [ ] Theming system once UI assets are provided
- [ ] Whether to commit generated bridge files to main (currently regenerated, not committed)
