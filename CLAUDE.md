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
│   └── decisions/          # Architecture decision records (ADRs)
├── .github/
│   └── workflows/
├── CLAUDE.md               # This file
└── README.md
```

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

To be decided once Flutter app scaffold is created. Leading candidates: **Riverpod** (preferred given existing Flutter experience) or Bloc.

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

## Development Workflow

- Edit Rust in `core/`, run `flutter_rust_bridge_codegen generate` to regenerate Dart bindings
- Run app: `flutter run -d windows` (or `-d android`, `-d linux`)
- Rust tests: `cargo test` inside `core/`
- Flutter tests: `flutter test` inside `app/`

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

## Open Decisions

- [ ] State management library (Riverpod vs Bloc)
- [ ] Persistence layer (Hive vs Drift)
- [ ] Browser extension approach (native messaging vs separate tool)
- [ ] CI/CD setup (GitHub Actions target platforms)
- [ ] Theming system once UI assets are provided
