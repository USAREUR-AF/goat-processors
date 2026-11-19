//! goat-correlator, rust engine of correlator specification 0.1.
//!
//! `load_pack`, then `Engine::new(pack)` with `ingest`, `tick`, `snapshot`.

pub mod engine;
pub mod filter;
pub mod json;
pub mod pack;

pub use engine::{Engine, StepResult};
pub use json::Json;
pub use pack::{load_pack, parse_pack, Pack};
