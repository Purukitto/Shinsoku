# Contributing to Shinsoku

Thanks for your interest in improving Shinsoku! ⚡ This guide covers how to set up the
project, the conventions we follow, and how to get your change merged.

By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- 🐛 **Report bugs** and 💡 **request features** via [Issues](https://github.com/purukitto/Shinsoku/issues).
- 📸 **Add screenshots** — see [`docs/screenshots/`](docs/screenshots/) (a great first PR).
- 🧩 **Code** — engine (Rust), UI (Flutter), or the browser extension.
- 📖 **Docs** — fix typos, clarify setup, write ADRs.

## Project layout

Shinsoku is a monorepo. The two halves you'll most likely touch:

- [`core/`](core/) — the **Rust** download engine. All download logic lives here.
- [`app/`](app/) — the **Flutter** UI. It must not re-implement engine behavior.

See the [Architecture section of the README](README.md#-architecture) for the full tree.

## Development setup

You'll need the [prerequisites listed in the README](README.md#prerequisites): the Flutter
SDK, the Rust toolchain, `flutter_rust_bridge_codegen` 2.9.0, and (on Windows) Visual
Studio 2022 with the C++ desktop workload.

```bash
git clone https://github.com/purukitto/Shinsoku.git
cd Shinsoku/app
flutter pub get
flutter run -d windows --release
```

## Workflow

1. **Fork** the repo and create a branch from `main`:
   `git checkout -b feat/short-description` (or `fix/…`, `docs/…`).
2. Make your change with focused commits.
3. **Test and lint** before pushing (see below).
4. Open a **Pull Request** against `main`, filling in the PR template. Link any related
   issue (e.g. `Closes #12`). Include before/after screenshots for UI changes.

## Code conventions

### Rust (`core/`)

- Format and lint before committing:
  ```bash
  cd core
  cargo fmt --all
  cargo clippy --all-targets -- -D warnings
  cargo test
  ```
- **Performance is a first-class requirement.** Avoid needless allocations/copies, stream
  rather than buffer whole files, reuse clients/connections, and keep hot paths finely
  locked. Justify any choice that trades speed away.
- Keep all download logic in the engine — never in Dart.

### Flutter / Dart (`app/`)

- Format and analyze:
  ```bash
  cd app
  dart format .
  flutter analyze
  flutter test
  ```
- Keep rebuild scope tight: watch narrow Riverpod slices, use `const` widgets, stable list
  keys, and `RepaintBoundary` around frequently-repainting widgets. Judge performance in
  `--profile`/`--release`, never debug.

### Bridge code is generated

Files under `app/lib/src/rust/` and `core/src/frb_generated.rs` are produced by
`flutter_rust_bridge_codegen generate`. **Do not hand-edit them** — change the Rust API in
`core/src/` and regenerate.

### Comments

Add a comment only when the code can't speak for itself (a non-obvious decision,
constraint, or gotcha). Keep them short and technical — no narration, no prose.

### Commit & PR messages

- Write clear, imperative commit subjects ("Add per-download speed cap"), not "fixed
  stuff".
- **Do not** reference AI tools or assistants in commit messages, code comments, or any
  committed file.

## Versioning & changelog

Shinsoku follows [Semantic Versioning](https://semver.org) (`MAJOR.MINOR.PATCH`) and keeps
a [Keep a Changelog](https://keepachangelog.com)–style [`CHANGELOG.md`](CHANGELOG.md).

- **Every user-facing change** adds a bullet under the `## [Unreleased]` heading in
  `CHANGELOG.md`, in the right group (`Added` / `Changed` / `Fixed` / `Removed`). Internal
  refactors with no observable effect can skip it.
- **One version across the workspace** — `app/pubspec.yaml`, `core/Cargo.toml`, and both
  `extension/*/manifest.json` files stay in lockstep. Don't bump them by hand.
- **Cutting a release** (maintainers):
  ```powershell
  ./tool/bump-version.ps1 0.2.0     # bumps all four + rolls the changelog
  ./extension/build.ps1             # rebuild dist/ so its manifests match
  # review, then:
  git add -A; git commit -m "Release v0.2.0"; git tag -a v0.2.0 -m "v0.2.0"
  git push; git push origin v0.2.0
  ```
  (`bump-version.ps1 0.2.0 -Commit` does the commit + tag for you.)

## Architecture decisions

Significant, resolved architecture decisions are documented under **Resolved Decisions** in
[`CLAUDE.md`](CLAUDE.md). If your change introduces a notable architectural choice, note it
there with a short rationale.

## Reporting security issues

Please **do not** open a public issue for security vulnerabilities — follow the
[Security Policy](SECURITY.md) instead.

---

Happy hacking! If anything here is unclear, open a [discussion or issue](https://github.com/purukitto/Shinsoku/issues)
and we'll improve the docs.
