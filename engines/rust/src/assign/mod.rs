//! `method assign` (spec/correlate-assign.md 0.6): system tracks, ranked
//! per-source assignments at each tick, a window of histories (with an
//! optional margin), sensor bias with an optional clock offset, and the
//! inverse-variance fused estimate. The engine state it reads and writes is
//! the correlate engine's (`crate::correlate::Engine`).
//!
//! | File | Section |
//! |---|---|
//! | `membership.rs` | Memberships; Events (membership events) |
//! | `cost.rs` | Assignment of one source (columns, entries, Cost); fused estimate |
//! | `ranking.rs` | Ranking |
//! | `bias.rs` | Sensor bias (with Time offset) |
//! | `window.rs` | Window; Events; Trace |
//! | `snapshot.rs` | Snapshot |

use std::collections::BTreeSet;

use crate::model::Json;

mod bias;
mod cost;
mod membership;
mod ranking;
mod snapshot;
mod window;

pub use bias::PairBias;
pub(crate) use membership::{History, Membership};
pub(crate) use ranking::Choice;

pub(crate) fn system_name(n: u64) -> String {
    format!("s{}", n)
}

pub(crate) fn names(members: &BTreeSet<String>) -> Json {
    Json::Arr(members.iter().map(|m| m.as_str().into()).collect())
}
