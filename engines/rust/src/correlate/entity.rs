//! correlate.md Track estimate, per entity: the entity's stored filter, last
//! report and variances, and its prediction to a time (never changing it).

use std::collections::BTreeMap;

use super::pack::Pack;
use crate::model::report;
use crate::model::{Axis, Json, TwoModel};

#[derive(Debug, Clone)]
pub(crate) struct Entity {
    pub(crate) source: String,
    pub(crate) last_time_ms: i64,
    pub(crate) group: Option<u64>,
    /// `method assign`: the entity's system track in the committed membership.
    pub(crate) system: Option<u64>,
    pub(crate) hold_failures: u64,
    /// The entity's filter; with two models, their combination.
    pub(crate) east: Axis,
    pub(crate) north: Axis,
    /// With the pack's `maneuver` directive: the two models and `mu`.
    pub(crate) imm: Option<TwoModel>,
    /// The entity's last accepted report.
    pub(crate) report: BTreeMap<String, Json>,
    /// That report's measurement variance `(r_east, r_north)` (Track
    /// estimate, Measurement variance).
    pub(crate) r: (f64, f64),
    /// That report's timing variance `((v_e*ts)², (v_n*ts)²)`; `None` when its
    /// time error was 0, which reads as 0 and 0.
    pub(crate) time_var: Option<(f64, f64)>,
}

impl Entity {
    pub(crate) fn num(&self, key: &str) -> Option<f64> {
        self.report.get(key).and_then(Json::as_f64)
    }

    /// Last `ce`, or the pack's `default_ce_m`.
    pub(crate) fn ce(&self, default_ce_m: f64) -> f64 {
        report_ce(&self.report).unwrap_or(default_ce_m)
    }

    /// `@env`: the third `-`-separated element of `type`; absent when `type`
    /// is absent or has fewer than three elements.
    pub(crate) fn env(&self) -> Option<Json> {
        let t = self.report.get("type")?.as_str()?;
        t.split('-').nth(2).map(Json::from)
    }

    /// Value for a `same` test.
    pub(crate) fn same_value(&self, key: &str) -> Option<Json> {
        if key == "@env" {
            self.env()
        } else {
            self.report.get(key).filter(|v| **v != Json::Null).cloned()
        }
    }

    /// The timing variance per axis, 0 and 0 when the last report's time
    /// error was 0.
    pub(crate) fn timing_variance(&self) -> (f64, f64) {
        self.time_var.unwrap_or((0.0, 0.0))
    }

    /// Prediction to time `t` for a comparison with another entity: the
    /// prediction with this entity's timing variance added to `pp` on each
    /// axis (Track estimate, Measurement variance).
    pub(crate) fn predict_for_comparison(&self, t: i64, pack: &Pack) -> (Axis, Axis) {
        let (pe, pn) = self.predict(t, pack);
        let (var_e, var_n) = self.timing_variance();
        (Axis { pp: pe.pp + var_e, ..pe }, Axis { pp: pn.pp + var_n, ..pn })
    }

    /// Prediction to time `t` (spec: Track estimate, Prediction; Two-model
    /// filter, Prediction). Never changes the entity.
    pub(crate) fn predict(&self, t: i64, pack: &Pack) -> (Axis, Axis) {
        let dt = (t - self.last_time_ms) as f64 / 1000.0;
        let q1 = pack.filter.accel_var;
        match (&self.imm, &pack.maneuver) {
            (Some(two), Some(m)) => {
                let p = two.predict(dt, [q1, m.accel_var]);
                (p.east, p.north)
            }
            _ => (self.east.predict(dt, q1), self.north.predict(dt, q1)),
        }
    }
}

/// A report's `ce`; absent when not a number or 0 or below (spec: Reports).
pub(crate) fn report_ce(report: &BTreeMap<String, Json>) -> Option<f64> {
    report::optional_f64(report, "ce")
}
