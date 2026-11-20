//! goat-processors, rust engine: the four functions of spec/, each behind
//! the one entry-point shape of `function::Function` (load the pack, ingest
//! one report, tick, trace records out, snapshot).
//!
//! | Module | What |
//! |---|---|
//! | `model` | JSON values, reports, frame, track estimate, two-model filter, shared pack values |
//! | `correlate` | spec/correlate.md 0.8: the engine, the `confirm` method, tests, restart |
//! | `assign` | spec/correlate-assign.md 0.6: the `assign` method of correlate |
//! | `filter` | spec/filter.md 0.1 |
//! | `fuse` | spec/fuse.md 0.2 |
//! | `quality` | spec/quality.md 0.2 |
//! | `trace` | `StepResult` and the shared event and trace record builders |
//! | `snapshot` | the shared JSON forms of every Snapshot |
//! | `io` | the steps file, the events file and the runner contract |
//! | `function` | the `Function` trait |
//!
//! README.md maps every spec section to its file.

pub mod function;
pub mod model;
pub mod snapshot;
pub mod trace;

pub mod assign;
pub mod correlate;
pub mod filter;
pub mod fuse;
pub mod quality;

pub mod io;

pub use function::Function;
pub use model::json;
pub use model::Json;
pub use trace::StepResult;

// The crate's public names from before the refactor, kept so programs built
// on them (runner/) keep compiling: the correlate engine and its pack, and
// the filter function's module under its earlier name.
pub use correlate::pack::{load_pack, parse_pack, Pack};
pub use correlate::Engine;
pub use filter as filter_fn;
