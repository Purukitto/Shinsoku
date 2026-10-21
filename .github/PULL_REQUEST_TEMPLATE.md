## What this changes

<!-- One or two sentences. If it closes an issue, say "Closes #123".
     Title the PR like a commit: `fix(engine): ...`, `feat(ui): ...` — see CONTRIBUTING.md. -->

## Why

<!-- What was wrong, or what this makes possible. Skip if the what covers it. -->

## Checks

- [ ] `cargo fmt --all -- --check` (in `core/`)
- [ ] `cargo clippy --all-targets -- -D warnings` (in `core/`)
- [ ] `cargo test` (in `core/`)
- [ ] `flutter analyze` and `flutter test` (in `app/`)
- [ ] User-facing? Entry added under `## [Unreleased]` in `CHANGELOG.md`
- [ ] Versions untouched — only `tool/bump-version.ps1` changes them

## If this touches the bridge API

- [ ] Logic lives in `engine/`, `queue/`, `protocols/` or `storage/`; `api.rs` only forwards
- [ ] Regenerated with `flutter_rust_bridge_codegen generate` and committed in the same commit
- [ ] Nothing under `app/lib/src/rust/` or `core/src/frb_generated.rs` edited by hand

## If this touches the UI

- [ ] Checked in a `--release` or `--profile` build, not debug
- [ ] Widgets watch the narrowest slice they need — no broad `watch` on the download list
- [ ] Gallery screenshots recaptured with `tool/screenshots.ps1` if what they show changed

## If this touches the extension or the capture server

- [ ] Edited `extension/shared/` or the manifests, not `dist/`
- [ ] Tested in both Chromium and Firefox
- [ ] Still refuses a request without the pairing token

## Notes for the reviewer

<!-- Anything deliberately left out, or a decision worth a second opinion. -->
