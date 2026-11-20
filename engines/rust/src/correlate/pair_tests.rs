//! correlate.md Tests: A, the entity just reported, against B predicted to
//! A's `time_ms`; each test's `value`, `limit` and `pass`, run in pack order
//! within a stage and stopping at the first failure.

use super::pack::Test;
use super::{Engine, Entity};
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

/// What a test reads about one pair: A as filtered, and B predicted to A's
/// `time_ms` as A sees it (B's timing variance added; with `bias`, moved
/// into A's frame). `seen` computes that prediction when a test needs it.
pub(crate) struct Pair<'a> {
    pub(crate) a: &'a Entity,
    pub(crate) b: &'a Entity,
    pub(crate) default_ce_m: f64,
    pub(crate) seen: &'a dyn Fn() -> (Axis, Axis),
}

impl Pair<'_> {
    /// The plane distance from A's filtered position to B's prediction, m.
    pub(crate) fn distance(&self) -> f64 {
        let (pe, pn) = (self.seen)();
        ((self.a.east.p - pe.p).powi(2) + (self.a.north.p - pn.p).powi(2)).sqrt()
    }

    /// `d²` of A against B's prediction (`d2`).
    pub(crate) fn d2(&self) -> f64 {
        d2(self.a, (self.seen)())
    }

    /// Both speeds, when both are present and at least `min_speed_ms`.
    pub(crate) fn speeds(&self, min_speed_ms: f64) -> Option<(f64, f64)> {
        let (sa, sb) = (self.a.num("speed_ms")?, self.b.num("speed_ms")?);
        if sa < min_speed_ms || sb < min_speed_ms {
            return None;
        }
        Some((sa, sb))
    }

    /// Both courses, when both are present and `speeds` holds.
    pub(crate) fn courses(&self, min_speed_ms: f64) -> Option<(f64, f64)> {
        let (ca, cb) = (self.a.num("course")?, self.b.num("course")?);
        self.speeds(min_speed_ms)?;
        Some((ca, cb))
    }
}

/// `d² = sum over east, north of (pa - pb)² / (pp_b + r_a)`: A's filter,
/// B's prediction as A sees it, and `r_a` A's measurement variance per axis.
pub(crate) fn d2(a: &Entity, (pe, pn): (Axis, Axis)) -> f64 {
    let (r_east, r_north) = a.r;
    (a.east.p - pe.p).powi(2) / (pe.pp + r_east) + (a.north.p - pn.p).powi(2) / (pn.pp + r_north)
}

/// One test of correlate.md Tests on one pair. Pure: reads the pair only.
pub(crate) fn evaluate(test: &Test, pair: &Pair) -> Outcome {
    let (ea, eb, dce) = (pair.a, pair.b, pair.default_ce_m);
    match test {
        Test::Distance { max_m } => {
            let d = pair.distance();
            Outcome::ran(d, *max_m, d < *max_m)
        }
        Test::Window { multiplier, window_m, err_min_m, err_max_m } => {
            let d = pair.distance();
            let ea_e = ea.ce(dce).clamp(*err_min_m, *err_max_m);
            let eb_e = eb.ce(dce).clamp(*err_min_m, *err_max_m);
            let limit = multiplier * (ea_e * ea_e + eb_e * eb_e).sqrt() + window_m;
            Outcome::ran(d, limit, d < limit)
        }
        Test::Mahalanobis { gate } => {
            let d2 = pair.d2();
            Outcome::ran(d2, *gate, d2 < *gate)
        }
        Test::Course { max_deg, min_speed_ms } => match pair.courses(*min_speed_ms) {
            None => Outcome::skipped(),
            Some((ca, cb)) => {
                let diff = (ca - cb).abs();
                let v = diff.min(360.0 - diff);
                Outcome::ran(v, *max_deg, v <= *max_deg)
            }
        },
        Test::Speed { max_pct, min_speed_ms } => match pair.speeds(*min_speed_ms) {
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

impl Engine {
    /// Runs `tests` in order between A and B, writing each to the trace and
    /// stopping at the first failure. True when every test passed.
    pub(crate) fn run_tests(&self, stage: &str, tests: &[Test], a: &str, b: &str, out: &mut StepResult) -> bool {
        let seen = || self.predict_seen_by(a, b);
        let pair = Pair { a: &self.entities[a], b: &self.entities[b], default_ce_m: self.pack.filter.default_ce_m, seen: &seen };
        for t in tests {
            let o = evaluate(t, &pair);
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

    /// `d2` of A against B as A sees it.
    pub(crate) fn d2(&self, a: &str, b: &str) -> f64 {
        d2(&self.entities[a], self.predict_seen_by(a, b))
    }
}
