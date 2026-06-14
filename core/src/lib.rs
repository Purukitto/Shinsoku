//! libshinsoku — the download engine.
//!
//! The Dart-facing API lives in [`api`] (the only module flutter_rust_bridge
//! scans). Everything under `engine`/`queue`/`protocols`/`storage` is the pure
//! Rust engine and stays independent of the bridge.

mod frb_generated;

pub mod api;
pub mod engine;
pub mod protocols;
pub mod queue;
pub mod storage;
