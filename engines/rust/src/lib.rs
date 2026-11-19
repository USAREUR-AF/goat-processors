//! goat-processors rust engine: correlate specification 0.6 (spec/correlate.md)
//! and its method assign 0.4 (spec/correlate-assign.md), selected by the pack's `method`.
//!
//! `load_pack`, then `Engine::new(pack)` with `ingest`, `tick`, `snapshot`.
//!
//! Fuse 0.1 (spec/fuse.md) is the module `fuse`: `fuse::load_pack`, then
//! `fuse::Engine::new(pack)` with the same four operations.
//!
//! The filter function (spec/filter.md 0.1) is `filter_fn`: `filter_fn::load_pack`,
//! then `filter_fn::Engine::new(pack)` with the same four operations.
//!
//! Quality 0.1 (spec/quality.md) is the module `quality`: `quality::load_pack`,
//! then `quality::Engine::new(pack)` with the same four operations.

pub mod engine;
pub mod filter;
pub mod filter_fn;
pub mod fuse;
pub mod json;
pub mod pack;
pub mod quality;
pub mod report;

pub use engine::{Engine, StepResult};
pub use json::Json;
pub use pack::{load_pack, parse_pack, Pack};
