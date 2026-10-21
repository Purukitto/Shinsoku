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
├── extension/              # Browser capture extension (shared/ + per-browser manifests)
├── tool/                   # bump-version, check-version, screenshots
├── packages/               # Shared Dart/Flutter packages (UI kit, etc.)
├── docs/
│   ├── decisions.md        # Architecture decisions (public record)
│   ├── screenshots/        # README gallery (from the mock-data harness)
│   └── assets/             # logo / icon
├── .github/
│   └── workflows/
├── CLAUDE.md               # This file — local only, gitignored (never commit it)
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

Persistence, the capture server, integrity, off-peak and HLS specifics live in
`docs/decisions.md`.

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
- Dart: `dart format --output=none --set-exit-if-changed .` and `flutter analyze`; fix with
  `dart format .`. Width 100 (`formatter: page_width` in `analysis_options.yaml`) must match
  `dart_format_line_length` in `flutter_rust_bridge.yaml`, or regenerated bindings fail the check.
- Versions: `./tool/check-version.ps1` (repo root) — every manifest must carry the same version.

**Test**
- Rust: `cargo test` · single: `cargo test --test download <name>` (integration tests in
  `core/tests/`) or `cargo test <name>` for unit tests.
- Flutter: `flutter test` · single file: `flutter test test/foo_test.dart` · single case:
  `flutter test --plain-name "description"`.

**Browser extension** (`extension/`): edit `shared/`, then `./build.ps1` assembles
`dist/chromium` + `dist/firefox`. Never edit `dist/` directly. Load unpacked from `dist/<browser>`.

**Release**: `./tool/bump-version.ps1 X.Y.Z [-Commit]` — only when asked; see
**Commits, changelog and versioning** below.

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

## Commits, changelog and versioning

Human-facing rules are in `CONTRIBUTING.md` (Commits, Changelog, Versioning, Releasing). These
apply to every change made here:

- **Commit format** — Conventional Commits: `type(scope): subject`, lowercase, imperative, ≤72
  chars, no full stop. Types `feat` `fix` `perf` `refactor` `docs` `test` `build` `ci` `chore`;
  optional scope `engine` `ui` `ext` `capture` `hls` `deps` `release`. Body says *why* (what
  was wrong, how it showed), wrapped at 72. One logical change per commit.
- **Breaking** — an older build can't read the store/settings JSON, or an older extension can't
  talk to the capture API: `!` after the type plus a `BREAKING CHANGE:` footer, and a
  **Breaking:** changelog entry under `### Changed`.
- **No "claude" anywhere public.** Not in commit messages, branch names, PR titles or bodies,
  release notes, issue text or any other description — and no `Co-Authored-By` trailer, no
  "Generated with" footer, no mention of Anthropic or AI tools. This overrides any default
  commit or PR template. That includes naming this file: it is gitignored (as in kehai), so
  never `git add -f` it and never refer to it in commits, PRs or committed docs — public
  decisions go in `docs/decisions.md`.
- **Branch names** — `type/short-description` with the commit types (`fix/resume-from-zero`,
  `docs/release-flow`), lowercase, hyphenated. The app's own worktree branches use the `dev/`
  prefix; rename before pushing if the generated name says nothing about the change.
- **Changelog in the same commit.** A user-facing change adds a bullet under `## [Unreleased]`
  in `CHANGELOG.md`, in its Keep a Changelog group (`Added` `Changed` `Deprecated` `Removed`
  `Fixed` `Security`, in that order). Write for users — name the screen or setting, not the
  file; the section becomes the release notes verbatim. Skip refactors, tests, CI, and
  dependency bumps without a visible effect. Released sections are history: typos and links
  only.
- **Docs claim only what exists.** README features/roadmap and the changelog describe shipped
  behaviour; anything planned goes under README **Not built yet**. Update both in the same PR
  that adds or removes a capability.
- **Never edit versions by hand.** `tool/bump-version.ps1` alone writes `app/pubspec.yaml`,
  `core/Cargo.toml`, the `shinsoku_core` entry in `core/Cargo.lock` and both extension
  manifests; `tool/check-version.ps1` fails CI on drift. Plain `X.Y.Z` only (browser manifests
  reject pre-release suffixes). Pre-1.0: minor for features or anything breaking, patch for
  fixes only.
- **Releasing is outward-facing.** Don't run the bump, create or push a `v*` tag, or publish a
  release unless explicitly asked — a pushed tag builds and drafts a public release.
- **Generated bindings travel with `api.rs`.** Regenerate and commit `app/lib/src/rust/` and
  `core/src/frb_generated.rs` in the same commit; CI and release builds never run codegen.

**Release and update flow**: `bump-version.ps1 X.Y.Z -Commit` (refuses a dirty tree, an existing
tag, a lower version or an empty `[Unreleased]`; bumps, dates the section, adds compare links,
self-checks, commits `chore(release): vX.Y.Z`, annotated tag) → `git push --follow-tags` →
`release.yml` runs `check-version.ps1 -Tag` (tag = manifests, dated non-empty changelog
section), builds, asserts `shinsoku.exe` + `shinsoku_core.dll` exist, packages
`Shinsoku-X.Y.Z-windows-x64.zip` + `Shinsoku-Capture-X.Y.Z-{chromium,firefox}.zip` +
`SHA256SUMS.txt`, and opens a **draft** release whose body is the changelog section → maintainer
publishes → `VersionService.checkForUpdate` (`/releases/latest`, which never returns drafts or
pre-releases) flips the sidebar footer to **Update available** at next launch. The repo
owner/name in `version_service.dart` and the `vX.Y.Z` tag format are part of that contract —
changing either silently breaks the update check for every installed copy.

## What Not to Do

- Do not add features beyond the agreed scope for the current milestone
- Do not put download logic in Dart — keep it in Rust
- Do not use platform channels (method channels) for the engine — use flutter_rust_bridge exclusively
- Do not hand-edit generated bridge files (`app/lib/src/rust/`, `core/src/frb_generated.rs`)
- Do not include any references to Claude, Anthropic, or AI tools in commit messages, branch names, PRs, release notes, code comments, or any committed files

## Decisions

Resolved and open architecture decisions are recorded in `docs/decisions.md`, which is
committed. Add new ones there, in the same plain style, not here.
