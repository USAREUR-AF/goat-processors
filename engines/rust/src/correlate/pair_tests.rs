//! correlate.md Tests: A, the entity just reported, against B predicted to
//! A's `time_ms`; each test's `value`, `limit` and `pass`, run in pack order
//! within a stage and stopping at the first failure.

use super::pack::Test;
use super::Engine;
use crate::model::{Axis, Json};
use crate::trace::{record, StepResult};

/// The result of one test (spec: Tests).
pub(crate) struct Outcome {
    pub(crate) value: Json,
    pub(crate) limit: Json,
    pub(crate) pass: bool,
    pub(crate) skipped: bool,
}

impl Outcome {
    fn ran(value: f64, limit: f64, pass: bool) -> Outcome {
        Outcome { value: value.into(), limit: limit.into(), pass, skipped: false }
    }

    fn skipped() -> Outcome {
        Outcome { value: Json::Null, limit: Json::Null, pass: true, skipped: true }
    }
}

impl Engine {
    /// Runs `tests` in order between A and B, writing each to the trace and
    /// stopping at the first failure. True when every test passed.
    pub(crate) fn run_tests(&self, stage: &str, tests: &[Test], a: &str, b: &str, out: &mut StepResult) -> bool {
        for t in tests {
            let o = self.evaluate(t, a, b);
            out.trace.push(record(stage, a, b, t.name(), o.value, o.limit, o.pass, o.skipped));
            if !o.pass {
                return false;
            }
        }
        true
    }

    /// B predicted to A's `time_ms`, with B's timing variance added to `pp`
    /// (Track estimate, Measurement variance), then with `bias` moved into
    /// A's frame (correlate-assign.md Sensor bias, Moving B into A's frame).
    pub(crate) fn predict_seen_by(&self, a: &str, b: &str) -> (Axis, Axis) {
        let ea = &self.entities[a];
        let eb = &self.entities[b];
        self.move_into_frame(&ea.source, &eb.source, eb.predict_for_comparison(ea.last_time_ms, &self.pack))
    }

    /// `d² = sum over east, north of (pa - pb)² / (pp_b + r_a)`: A's filter,
    /// B as seen by A, and `r_a` A's measurement variance on that axis.
    pub(crate) fn d2(&self, a: &str, b: &str) -> f64 {
        let ea = &self.entities[a];
        let (pe, pn) = self.predict_seen_by(a, b);
        let (r_east, r_north) = ea.r;
        (ea.east.p - pe.p).powi(2) / (pe.pp + r_east) + (ea.north.p - pn.p).powi(2) / (pn.pp + r_north)
    }

    /// Tests: A as filtered, B predicted to A's `time_ms`.
    pub(crate) fn evaluate(&self, test: &Test, a: &str, b: &str) -> Outcome {
        let ea = &self.entities[a];
        let eb = &self.entities[b];
        let dce = self.pack.filter.default_ce_m;
        let distance = || {
            let (pe, pn) = self.predict_seen_by(a, b);
            ((ea.east.p - pe.p).powi(2) + (ea.north.p - pn.p).powi(2)).sqrt()
        };
        // Both speeds present and at least min_speed_ms.
        let speeds = |min_speed_ms: f64| -> Option<(f64, f64)> {
            let (sa, sb) = (ea.num("speed_ms")?, eb.num("speed_ms")?);
            if sa < min_speed_ms || sb < min_speed_ms {
                return None;
            }
            Some((sa, sb))
        };
        // Course: both courses present, and the speed condition above.
        let courses = |min_speed_ms: f64| -> Option<(f64, f64)> {
            let (ca, cb) = (ea.num("course")?, eb.num("course")?);
            speeds(min_speed_ms)?;
            Some((ca, cb))
        };
        match test {
            Test::Distance { max_m } => {
                let d = distance();
                Outcome::ran(d, *max_m, d < *max_m)
            }
            Test::Window { multiplier, window_m, err_min_m, err_max_m } => {
                let d = distance();
                let ea_e = ea.ce(dce).clamp(*err_min_m, *err_max_m);
                let eb_e = eb.ce(dce).clamp(*err_min_m, *err_max_m);
                let limit = multiplier * (ea_e * ea_e + eb_e * eb_e).sqrt() + window_m;
                Outcome::ran(d, limit, d < limit)
            }
            Test::Mahalanobis { gate } => {
                let d2 = self.d2(a, b);
                Outcome::ran(d2, *gate, d2 < *gate)
            }
            Test::Course { max_deg, min_speed_ms } => match courses(*min_speed_ms) {
                None => Outcome::skipped(),
                Some((ca, cb)) => {
                    let diff = (ca - cb).abs();
                    let v = diff.min(360.0 - diff);
                    Outcome::ran(v, *max_deg, v <= *max_deg)
                }
            },
            Test::Speed { max_pct, min_speed_ms } => match speeds(*min_speed_ms) {
                None => Outcome::skipped(),
                Some((sa, sb)) => {
                    let (slow, fast) = (sa.min(sb), sa.max(sb));
                    let v = if fast == 0.0 { 0.0 } else { (1.0 - slow / fast).abs() * 100.0 };
                    Outcome::ran(v, *max_pct, v <= *max_pct)
                }
            },
            Test::Altitude { max_m } => match (ea.num("hae"), eb.num("hae")) {
                (Some(ha), Some(hb)) => {
                    let v = (ha - hb).abs();
                    Outcome::ran(v, *max_m, v <= *max_m)
                }
                _ => Outcome::skipped(),
            },
            Test::Same { key } => {
                let (va, vb) = (ea.same_value(key), eb.same_value(key));
                let pass = match (&va, &vb) {
                    (Some(x), Some(y)) => x.same(y),
                    (None, None) => true,
                    _ => false,
                };
                Outcome { value: va.unwrap_or(Json::Null), limit: vb.unwrap_or(Json::Null), pass, skipped: false }
            }
        }
    }
}
