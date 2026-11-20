//! correlate.md Pack, `method`: **the registration point of a correlate
//! method.** A method is one `MethodKind`: its name on the `method` line,
//! the directives it refuses, how it completes the pack, and its three hooks
//! into the engine (after each accepted report, on each tick, the snapshot).
//! `BUILTIN_METHODS` holds `confirm` (correlate.md Association) and `assign`
//! (correlate-assign.md); adding one is one entry here and its module.

use std::fmt;

use super::pack::{finish_assign, finish_confirm, Draft, Pack};
use super::Engine;
use crate::model::Json;
use crate::trace::StepResult;

#[derive(Clone, Copy)]
pub struct MethodKind {
    /// The name on the `method` line.
    pub name: &'static str,
    /// Directives a pack with this method may not hold.
    pub refuses: &'static [&'static str],
    /// Checks the pack's values for this method and completes the pack.
    pub(crate) finish: fn(Draft) -> Result<Pack, String>,
    /// After the filter update of an accepted report: the entity's key, and
    /// whether its filter restarted (correlate.md Restart).
    pub(crate) ingested: fn(&mut Engine, String, bool, &mut StepResult),
    /// On each tick.
    pub(crate) tick: fn(&mut Engine, i64) -> StepResult,
    /// The snapshot.
    pub(crate) snapshot: fn(&Engine) -> Json,
}

impl fmt::Debug for MethodKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "MethodKind({})", self.name)
    }
}

/// `confirm`: gate, confirm, hold and groups (correlate.md Association).
pub const CONFIRM: MethodKind = MethodKind {
    name: "confirm",
    refuses: &["new_cost", "keep_bonus", "window", "hypotheses", "margin", "bias", "time_offset"],
    finish: finish_confirm,
    ingested: |engine, key, _restarted, out| {
        if engine.entities[&key].group.is_some() {
            engine.hold(&key, out);
        } else {
            engine.associate(&key, out);
        }
    },
    tick: Engine::tick_confirm,
    snapshot: Engine::snapshot_confirm,
};

/// `assign`: system tracks by ranked assignment at each tick
/// (correlate-assign.md). Assignment waits for the next tick.
pub const ASSIGN: MethodKind = MethodKind {
    name: "assign",
    refuses: &["confirm", "hold", "confirm_count", "hold_failures", "same_source", "output", "priority"],
    finish: finish_assign,
    ingested: |engine, key, restarted, _out| {
        // The entity is restarted until the next tick.
        if restarted {
            engine.restarted.insert(key.clone());
        }
        engine.reported.insert(key);
    },
    tick: Engine::tick_assign,
    snapshot: Engine::snapshot_assign,
};

/// The spec's methods.
pub const BUILTIN_METHODS: &[MethodKind] = &[CONFIRM, ASSIGN];
