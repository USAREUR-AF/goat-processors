//! goat-processors, rust engine of two functions:
//!
//! - correlate, specification 0.4 (spec/correlate.md) and its method assign
//!   0.2 (spec/correlate-assign.md), selected by the pack's `method`:
//!   `load_pack`, then `Engine::new(pack)` with `ingest`, `tick`, `snapshot`.
//! - quality, specification 0.1 (spec/quality.md), in module `quality`:
//!   `quality::load_pack`, then `quality::Engine::new(pack)`, same operations.

pub mod engine;
pub mod filter;
pub mod json;
pub mod pack;
pub mod quality;

pub use engine::{Engine, StepResult};
pub use json::Json;
pub use pack::{load_pack, parse_pack, Pack};
