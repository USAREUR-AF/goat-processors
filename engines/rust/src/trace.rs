//! What every function's `ingest` and `tick` return, and the builders of the
//! event and trace record shapes the specs share (correlate.md Events and
//! Trace; the other functions' records are built where their spec section
//! lives).

use crate::model::json::{obj, Json};

/// What `ingest` and `tick` return: the events, then the trace records.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct StepResult {
    pub events: Vec<Json>,
    pub trace: Vec<Json>,
}

/// correlate.md Trace: one record `{stage, a, b, test, value, limit, pass}`,
/// with `"skipped": true` when the test was skipped.
#[allow(clippy::too_many_arguments)]
pub fn record(stage: &str, a: &str, b: &str, test: &str, value: Json, limit: Json, pass: bool, skipped: bool) -> Json {
    let mut pairs = vec![
        ("stage", Json::from(stage)),
        ("a", a.into()),
        ("b", b.into()),
        ("test", test.into()),
        ("value", value),
        ("limit", limit),
        ("pass", pass.into()),
    ];
    if skipped {
        pairs.push(("skipped", true.into()));
    }
    obj(pairs)
}

/// An event `{"ev": <ev>, ...pairs}`.
pub fn event(ev: &str, pairs: Vec<(&str, Json)>) -> Json {
    let mut all = vec![("ev", Json::from(ev))];
    all.extend(pairs);
    obj(all)
}

/// Adds integer keys (correlate-assign.md Trace: `h`, `r`) to a trace record.
pub fn tagged(mut rec: Json, tags: &[(&str, usize)]) -> Json {
    if let Json::Obj(m) = &mut rec {
        for (k, v) in tags {
            m.insert(k.to_string(), Json::Int(*v as i64));
        }
    }
    rec
}
