//! The one entry-point shape every function has (correlate, filter, fuse,
//! quality): load the pack, then ingest one report at a time, tick with the
//! input's clock, read the events and trace records out of each call, and
//! take a snapshot. The runner (`crate::io`) and the vector tests drive every
//! function through this trait only.

use std::path::Path;

use crate::model::Json;
use crate::trace::StepResult;

pub trait Function: Sized {
    /// The function's name as the runner's `--function` gives it.
    const NAME: &'static str;
    /// The loaded pack.
    type Pack;

    /// `parse_pack(text)`: the pack, or the first load error.
    fn parse_pack(text: &str) -> Result<Self::Pack, String>;

    /// `load_pack(dir)`: reads and parses `<dir>/pack.def`.
    fn load_pack(dir: &Path) -> Result<Self::Pack, String> {
        Self::parse_pack(&crate::model::pack::read_pack_def(dir)?)
    }

    /// A new engine with no state.
    fn new(pack: Self::Pack) -> Self;

    /// One report.
    fn ingest(&mut self, report: &Json) -> StepResult;

    /// One tick at `now_ms`.
    fn tick(&mut self, now_ms: i64) -> StepResult;

    /// The engine's state as JSON.
    fn snapshot(&self) -> Json;
}

/// Implements `Function` for an engine type with inherent `new`, `ingest`,
/// `tick`, `snapshot` and a module-level `parse_pack`.
macro_rules! function {
    ($engine:ty, $name:literal, $pack:ty, $parse:path) => {
        impl $crate::function::Function for $engine {
            const NAME: &'static str = $name;
            type Pack = $pack;
            fn parse_pack(text: &str) -> Result<$pack, String> {
                $parse(text)
            }
            fn new(pack: $pack) -> Self {
                <$engine>::new(pack)
            }
            fn ingest(&mut self, report: &$crate::model::Json) -> $crate::trace::StepResult {
                <$engine>::ingest(self, report)
            }
            fn tick(&mut self, now_ms: i64) -> $crate::trace::StepResult {
                <$engine>::tick(self, now_ms)
            }
            fn snapshot(&self) -> $crate::model::Json {
                <$engine>::snapshot(self)
            }
        }
    };
}
pub(crate) use function;
