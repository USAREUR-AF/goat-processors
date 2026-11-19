//! goat-correlator, rust engine of correlate specification 0.3 (spec/correlate.md)
//! and its method assign 0.1 (spec/correlate-assign.md), selected by the pack's `method`.
//!
//! `load_pack`, then `Engine::new(pack)` with `ingest`, `tick`, `snapshot`.

pub mod engine;
pub mod filter;
pub mod json;
pub mod pack;

pub use engine::{Engine, StepResult};
pub use json::Json;
pub use pack::{load_pack, parse_pack, Pack};
