# ADR 001 — Tech Stack: Flutter + Rust

**Date:** 2026-06-14  
**Status:** Accepted

## Context

Shinsoku is a cross-platform download manager. Speed and functionality are the primary goals. Target platforms: Windows (primary), Android, Linux.

## Decision

Use **Flutter** for UI and **Rust** for the download engine, connected via **`flutter_rust_bridge` v2**.

## Rationale

A download manager's performance is determined by the download engine, not the UI layer. Rust provides:
- True OS-level thread parallelism via `tokio`
- Zero-copy I/O and fine-grained memory control
- `reqwest` for production-grade async HTTP

Flutter provides:
- Single UI codebase across Windows, Android, Linux
- Developer already has Flutter experience (lower ramp-up cost)
- Mature desktop support on Windows and Linux
- `flutter_rust_bridge` v2 handles the FFI boundary with generated type-safe async Dart bindings

## Alternatives Rejected

**Tauri v2 (Rust + Web UI):**  
Android support is experimental in Tauri v2. Desktop is excellent but the mobile gap breaks the cross-platform requirement cleanly.

**Flutter-only (Dart engine):**  
Dart isolates don't map to OS threads the same way. For a v1 it works, but it prevents reaching top-tier speeds for large parallel downloads. Swapping later would require API redesign.

## Consequences

- All download logic lives in `core/` (Rust). Dart/Flutter must not re-implement it.
- Bridge code is auto-generated; do not hand-edit generated files.
- Contributors touching the engine need Rust toolchain; UI contributors only need Flutter.
