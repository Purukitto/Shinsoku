# app

The Flutter UI for Shinsoku — Windows today, Android and Linux to follow. It is a thin
view over the Rust engine in [`../core`](../core); no download logic lives here.

| Path | What |
| --- | --- |
| `lib/main.dart` | Entry point: resolves the data folder, creates the engine, starts settings and capture |
| `lib/main_screenshots.dart` | The same app on deterministic mock data, for the README gallery |
| `lib/src/rust/` | Generated `flutter_rust_bridge` bindings — regenerate, never edit |
| `lib/src/providers/` | Riverpod state: downloads, settings, capture, version |
| `lib/src/services/` | Settings and capture JSON, tray, update check |
| `lib/src/ui/` | Desktop shell, screens and shared widgets |
| `tool/gen_icons.py` | Regenerates the app and tray icons |

Setup, commands and conventions are in the [root README](../README.md#building-from-source)
and [CONTRIBUTING.md](../CONTRIBUTING.md).
