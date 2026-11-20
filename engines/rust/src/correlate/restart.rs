//! correlate.md Restart: before the filter update of a later report, `d²` of
//! the report against the entity's own prediction to its time (no timing
//! variance added); the filter starts again when `d²` is not below the gate.

use crate::model::track::d2;
use crate::model::{obj, Axis, Json};

/// `(d², pass)`: the report position `z` with measurement variance `r`
/// against `prediction`; it passes (no restart) when `d² < gate`.
pub(crate) fn test(prediction: (Axis, Axis), z: (f64, f64), r: (f64, f64), gate: f64) -> (f64, bool) {
    let value = d2(z, (&prediction.0, &prediction.1), r);
    (value, value < gate)
}

/// The trace record `{stage: filter, a, b: null, test: restart, ...}`.
pub(crate) fn record(key: &str, value: f64, gate: f64, pass: bool) -> Json {
    obj(vec![
        ("stage", "filter".into()),
        ("a", key.into()),
        ("b", Json::Null),
        ("test", "restart".into()),
        ("value", value.into()),
        ("limit", gate.into()),
        ("pass", pass.into()),
    ])
}
