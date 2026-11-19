//! goat-correlator, rust engine of correlate specification 0.3 (spec/correlate.md)
//! and its method assign 0.1 (spec/correlate-assign.md), selected by the pack's `method`.
//!
//! `load_pack`, then `Engine::new(pack)` with `ingest`, `tick`, `snapshot`.
//!
//! Fuse 0.1 (spec/fuse.md) is the module `fuse`: `fuse::load_pack`, then
//! `fuse::Engine::new(pack)` with the same four operations.

pub mod engine;
pub mod filter;
pub mod fuse;
pub mod json;
pub mod pack;

pub use engine::{Engine, StepResult};
pub use json::Json;
pub use pack::{load_pack, parse_pack, Pack};
