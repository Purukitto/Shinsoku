<!-- Thanks for contributing to Shinsoku! Please fill this in. -->

## Summary

<!-- What does this PR do, and why? -->

## Related issue

<!-- e.g. Closes #12 -->

## Type of change

- [ ] 🐛 Bug fix
- [ ] ✨ New feature
- [ ] ♻️ Refactor / performance
- [ ] 📖 Documentation
- [ ] 🧩 Browser extension
- [ ] 🧪 Tests / tooling

## Area

- [ ] Download engine (`core/` — Rust)
- [ ] UI (`app/` — Flutter)
- [ ] Browser extension (`extension/`)
- [ ] Docs / repo

## Checklist

- [ ] Rust: `cargo fmt`, `cargo clippy --all-targets -- -D warnings`, and `cargo test` pass
- [ ] Flutter: `dart format .`, `flutter analyze`, and `flutter test` pass
- [ ] I did **not** hand-edit generated bridge files (`app/lib/src/rust/`, `core/src/frb_generated.rs`)
- [ ] Download logic stays in the Rust engine (not re-implemented in Dart)
- [ ] I considered the performance impact (see perf rules in `CLAUDE.md`)
- [ ] Updated `CHANGELOG.md` (under `[Unreleased]`) for any user-facing change
- [ ] No references to AI tools in commits, comments, or committed files

## Screenshots

<!-- For UI changes, include before/after screenshots or a short clip. -->
