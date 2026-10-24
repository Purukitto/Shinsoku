# Contributing

Thanks for looking. Shinsoku has two hard rules — download logic lives in Rust, and
performance is a requirement rather than a nice-to-have — and the fastest way to get a
change merged is to match what is already there.

## Getting set up

You need the [tools listed in the README](README.md#building-from-source): the Flutter
SDK, a Rust toolchain, and on Windows Visual Studio 2022 with the C++ desktop workload.
`flutter_rust_bridge_codegen` 2.9.0 is only needed if you change the bridge API.

```bash
cd app && flutter pub get
```

```bash
flutter run -d windows --release
```

The Windows build compiles the engine in `core/` and bundles its DLL, so there is no
separate Rust step. The Android build does the same through `cargo-ndk` (see the
README for the Rust targets it needs), and runs on Android 11 or later. For UI work that needs realistic data without real downloads,
`./tool/screenshots.ps1` runs the real app on deterministic mock data.

## Before you open a pull request

These are what CI runs, and they are the whole gate:

```bash
cd core && cargo fmt --all -- --check
```

```bash
cd core && cargo clippy --all-targets -- -D warnings
```

```bash
cd core && cargo test
```

```bash
cd app && dart format --output=none --set-exit-if-changed .
```

```bash
cd app && flutter analyze
```

```bash
cd app && flutter test
```

```bash
./tool/check-version.ps1
```

Clippy is enforced at `-D warnings`. The format check fails on any Dart file that
`dart format` would change, generated bindings included; run `dart format .` in `app/`
to fix it. The page width (100) lives in `app/analysis_options.yaml`, so editors pick it
up too.

Keep pull requests to one thing. An engine change and the UI that exposes it are one
thing; a refactor bundled with a feature is two.

## How the pieces fit

Read the [architecture section of the README](README.md#architecture) first. The short
version: the Rust engine owns all download state and pushes one progress event roughly
every 250 ms; the Flutter side maps it into view models and lets each widget watch only
the slice it draws.

### Changing the bridge API

1. Change `core/src/api.rs` — it is the only module `flutter_rust_bridge` scans. Keep
   it thin: the logic belongs in `engine/`, `queue/`, `protocols/` or `storage/`, which
   know nothing about the bridge.
2. Run `flutter_rust_bridge_codegen generate` in `app/`.
3. Commit the regenerated `app/lib/src/rust/` and `core/src/frb_generated.rs` **in the
   same commit** as the `api.rs` change. CI and the release build use the committed
   copies and never run codegen.
4. Stop the running app and do a full rebuild. Hot reload cannot swap the DLL, and a
   stale one fails at the first call whose signature changed.

### Adding a setting the engine applies

1. An atomic on `Shared` and a setter on `QueueManager` in
   `core/src/queue/manager.rs`, then a `#[frb(sync)]` function in `api.rs`.
2. A field with its default in `AppSettings`
   (`app/lib/src/services/settings_service.dart`), read and written in its JSON.
3. Push it in `SettingsNotifier._applyAll` (startup) **and** in its own setter (on
   change) in `app/lib/src/providers/settings_provider.dart`. Setters go through
   `_set`, which debounces the disk write so a slider drag does not rewrite the file
   every frame.
4. The control in `settings_screen.dart`, watching `settingsProvider`.

### Changing the extension

Edit `extension/shared/` and the two manifests, then `./extension/build.ps1` to
assemble `dist/`. Never edit `dist/` — it is rebuilt from scratch every time.

## House style

- **Download logic stays in Rust.** Dart never retries, splits, hashes or schedules.
  No platform channels for the engine; `flutter_rust_bridge` only.
- **Narrow watching is the performance contract.** The list watches an ordered id list
  and each row its own item via `select`. A broad `watch` on the whole list rebuilds
  every row on every tick.
- **Measure in `--profile` or `--release`.** Debug frame times are meaningless.
- **Stream, don't buffer.** No reading a whole file or response into memory; reuse the
  shared `reqwest::Client`; keep locks off the per-chunk path.
- **Comments say why, not what.** Short and technical. If a line needs a comment to say
  what it does, rename something instead.
- **UI follows the designs.** Layout comes from the provided design assets, not from
  invention. If a change alters what a gallery screenshot shows, recapture it with
  `./tool/screenshots.ps1`.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), lowercase and
imperative:

```
fix(engine): stop a paused segment reopening its connection on resume

The worker kept its range request alive across a pause, so resuming started a
second request for the same bytes and the first one raced it to the file. ...
```

| Type | For |
| --- | --- |
| `feat` | Something a user can do that they could not before |
| `fix` | Something that behaved wrongly and now does not |
| `perf` | Faster or lighter, same behaviour |
| `refactor` | Restructuring with no observable change |
| `docs` | README, CONTRIBUTING, comments-only changes |
| `test` | Tests only |
| `build` | CMake, Cargo, pubspec, `tool/` scripts |
| `ci` | `.github/workflows/` |
| `chore` | Everything else; `chore(deps)` for dependency bumps, `chore(release)` for releases |

- **Scope is optional** and names the area: `engine`, `ui`, `ext`, `capture`, `hls`,
  `deps`, `release`.
- **The subject says what changed**, in at most 72 characters, no trailing full stop.
  "fix: handle error" says nothing; "fix(hls): refuse a playlist with no segments
  instead of finishing empty" says everything.
- **The body says why**, if the subject does not: what was wrong, how it showed up,
  why this fix and not the obvious one. Wrap at 72.
- **Breaking changes** — anything an older build or an older extension can no longer
  read or talk to — get a `!` after the type (`feat(capture)!:`) and a
  `BREAKING CHANGE:` footer saying what breaks.
- **One logical change per commit.** Generated bridge files go in with the `api.rs`
  change that produced them; a changelog entry goes in with the change it describes.
- **No tool attribution.** No `Co-Authored-By` trailers, and no names of the editor,
  assistant or other tooling used — not in commit messages, branch names, pull request
  titles or descriptions, release notes, comments or committed files.

If a pull request is squash-merged, its title becomes the commit subject, so title it
the same way.

### Branches

Name a branch after the change, with the same types as commits:
`fix/resume-restarts-from-zero`, `feat/per-download-limit`, `docs/release-flow`.
Lowercase, hyphenated, no tool or personal prefixes.

Editor and agent tooling — settings folders, local instruction files — belongs to your
machine, not the project, and `.gitignore` keeps it out. Never force-add it.

## Changelog

[CHANGELOG.md](CHANGELOG.md) follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
**Every user-facing change adds an entry under `## [Unreleased]` in the same pull
request.** At release that section becomes the GitHub release notes word for word, so
it is written for someone using Shinsoku, not someone reading the diff.

- Group entries under `### Added`, `### Changed`, `### Deprecated`, `### Removed`,
  `### Fixed` or `### Security`, in that order. Create the heading if it is not there.
- Say what the user notices, naming the screen or setting: "**Off-peak** now shows the
  window it is using", not "refactor `_windowBands`". Lead with a bold phrase when the
  entry is a feature people will look for.
- A breaking change goes under `### Changed` and starts with **Breaking:**, saying what
  the user has to do.
- Skip refactors, tests, CI and dependency bumps — unless they change behaviour or fix
  a vulnerability, in which case say what changed for the user.
- Released sections are history. Fix a typo or a link; never rewrite what shipped.

## Versioning

[Semantic Versioning](https://semver.org/spec/v2.0.0.html), with **one version for the
whole repository**: `app/pubspec.yaml`, `core/Cargo.toml` (and its entry in
`core/Cargo.lock`) and both `extension/*/manifest.json` always agree, because the app
and the extension ship and are tested together. CI fails if they drift. Never edit them
by hand — `tool/bump-version.ps1` moves all of them at once.

Before 1.0.0:

- **Minor** (`0.2.0`) for new features, and for anything breaking: a download store or
  settings file an older build cannot read, or a capture API change that needs the
  extension updated with it.
- **Patch** (`0.1.1`) for fixes only.

From 1.0.0, breaking changes need a major version.

Versions are plain `X.Y.Z`. Browser manifests accept only dotted integers, so there are
no `-beta` or `-rc` tags. The `+N` build number in `pubspec.yaml` only ever increases —
Android requires it — and the bump script handles it.

## Releasing

For maintainers. The tag is the single source of truth: the release workflow refuses
to build when it disagrees with the manifests or the changelog.

1. **Read `## [Unreleased]` as release notes.** It ships verbatim. Add a
   `### Known limitations` group if there is something people will hit.
2. **Bump, commit and tag:**

   ```powershell
   ./tool/bump-version.ps1 0.2.0 -Commit
   ```

   It refuses to run on a dirty tree, an existing tag, a version lower than the
   current one, or an empty `[Unreleased]`. Then it bumps every manifest, dates the
   changelog section, adds its compare link, runs `tool/check-version.ps1` against the
   new tag, commits `chore(release): v0.2.0` and makes an annotated tag. Leave off
   `-Commit` to review the diff first; the script prints the commands to finish.
3. **Push:**

   ```bash
   git push --follow-tags
   ```

   The `v0.2.0` tag starts [`release.yml`](.github/workflows/release.yml): verify,
   build, check the outputs exist, package the app and both extensions, write
   `SHA256SUMS.txt`, and open a **draft** release whose notes are the changelog
   section. The Android job then adds the signed foss APKs and their checksums to the
   draft, and keeps the Google Play bundle as the run's `shinsoku-play-bundle`
   artifact. Last, the Linux job adds the x64 tarball and its checksum.
4. **Publish the draft** from the Releases tab after reading it over. Until then the
   in-app update check cannot see it; from then on every running copy shows **Update
   available** at its next launch.
5. **Upload the Play bundle** (`Shinsoku-0.2.0-play.aab`, from the run's artifacts) in
   the Play Console when the release should reach Google Play too.

### The Android signing key

The Android job refuses to build without the release key: an APK signed with the debug
key can never be updated by one signed with the real key. It reads four repository
secrets (**Settings → Secrets and variables → Actions**):

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | The keystore file, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | The keystore's password |
| `ANDROID_KEY_ALIAS` | The key's alias in it |
| `ANDROID_KEY_PASSWORD` | The key's password |

The same key signs the GitHub APKs and, as the upload key, the Play bundle; Google
Play re-signs with its own app signing key. Make one once, and back it up outside the
repository, since losing it means GitHub installs can't be updated:

```bash
keytool -genkeypair -v -keystore shinsoku-release.jks -alias shinsoku -keyalg RSA -keysize 4096 -validity 10000
```

```bash
base64 -w0 shinsoku-release.jks
```

To sign a local release build with it, point `app/android/key.properties` at it.
That file and any `*.jks` are gitignored.

If the build fails for a reason outside the code, fix the workflow and rerun it from
**Actions → Release → Run workflow** with the same tag. If the code was wrong, ship a
patch. Never move or reuse a tag once its release is published.

## Reporting things

Bugs and feature requests go through the
[issue templates](https://github.com/Purukitto/Shinsoku/issues/new/choose). For anything
security-sensitive, read [SECURITY.md](SECURITY.md) first and do not open a public
issue.
