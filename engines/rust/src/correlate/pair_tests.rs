//! correlate.md Tests: A, the entity just reported, against B predicted to
//! A's `time_ms`; each test's `value`, `limit` and `pass`, run in pack order
//! within a stage and stopping at the first failure.
//!
//! **The registration point of a test kind.** Every kind is one `TestKind`
//! entry: its name in a pack line, its parameters, and a builder that turns
//! the parameters into a `PairTest`. `BUILTIN_TESTS` holds the spec's seven;
//! `Registry::register_test` adds one more for a pack parsed with
//! `parse_pack_with` (see tests/registry.rs for a no-op kind that only the
//! tests register).

use std::fmt;
use std::sync::Arc;

use super::pack::Params;
use super::{Engine, Entity};
use crate::model::{Axis, Json};
use crate::trace::{record, StepResult};

/// The result of one test (spec: Tests).
#[derive(Debug, Clone, PartialEq)]
pub struct Outcome {
    pub value: Json,
    pub limit: Json,
    pub pass: bool,
    pub skipped: bool,
}

impl Outcome {
    /// A test that ran: numeric `value` and `limit`.
    pub fn ran(value: f64, limit: f64, pass: bool) -> Outcome {
        Outcome { value: value.into(), limit: limit.into(), pass, skipped: false }
    }

    /// A skipped test: `value` and `limit` null, passes.
    pub fn skipped() -> Outcome {
        Outcome { value: Json::Null, limit: Json::Null, pass: true, skipped: true }
    }
}

/// What a test reads about one pair: A as filtered, and B predicted to A's
/// `time_ms` as A sees it (B's timing variance added; with `bias`, moved
/// into A's frame). The prediction is computed when a test asks for it.
pub struct Pair<'a> {
    pub(crate) a: &'a Entity,
    pub(crate) b: &'a Entity,
    pub(crate) default_ce_m: f64,
    pub(crate) seen: &'a dyn Fn() -> (Axis, Axis),
}

impl Pair<'_> {
    /// The plane distance from A's filtered position to B's prediction, m.
    pub fn distance(&self) -> f64 {
        let (pe, pn) = (self.seen)();
        ((self.a.east.p - pe.p).powi(2) + (self.a.north.p - pn.p).powi(2)).sqrt()
    }

    /// `d²` of A against B's prediction (`d2`).
    pub fn d2(&self) -> f64 {
        d2(self.a, (self.seen)())
    }

    /// A key of A's last accepted report, as a number.
    pub fn a_number(&self, key: &str) -> Option<f64> {
        self.a.num(key)
    }

    /// A key of B's last accepted report, as a number.
    pub fn b_number(&self, key: &str) -> Option<f64> {
        self.b.num(key)
    }

    /// Both speeds, when both are present and at least `min_speed_ms`.
    pub fn speeds(&self, min_speed_ms: f64) -> Option<(f64, f64)> {
        let (sa, sb) = (self.a.num("speed_ms")?, self.b.num("speed_ms")?);
        if sa < min_speed_ms || sb < min_speed_ms {
            return None;
        }
        Some((sa, sb))
    }

    /// Both courses, when both are present and `speeds` holds.
    pub fn courses(&self, min_speed_ms: f64) -> Option<(f64, f64)> {
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

/// One test of a pack line with its parameters. `evaluate` is pure: it
/// reads the pair only.
pub trait PairTest: Send + Sync {
    /// The trace `test`.
    fn name(&self) -> &'static str;
    fn evaluate(&self, pair: &Pair) -> Outcome;
}

/// A test kind: what a pack line `gate|confirm|hold <name> <params>` names.
#[derive(Clone, Copy)]
pub struct TestKind {
    pub name: &'static str,
    /// Its parameters, each required exactly once.
    pub params: &'static [&'static str],
    /// Builds the test from the parameters (checked against `params`).
    pub build: fn(&Params) -> Result<Arc<dyn PairTest>, String>,
}

impl fmt::Debug for TestKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "TestKind({})", self.name)
    }
}

/// A test in a pack: one built `PairTest`.
#[derive(Clone)]
pub struct Test(pub Arc<dyn PairTest>);

impl Test {
    pub fn name(&self) -> &'static str {
        self.0.name()
    }
}

impl fmt::Debug for Test {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Test({})", self.name())
    }
}

// ---- The spec's tests (correlate.md Tests)

struct Distance {
    max_m: f64,
}

impl PairTest for Distance {
    fn name(&self) -> &'static str {
        "distance"
    }
    fn evaluate(&self, pair: &Pair) -> Outcome {
        let d = pair.distance();
        Outcome::ran(d, self.max_m, d < self.max_m)
    }
}

struct Window {
    multiplier: f64,
    window_m: f64,
    err_min_m: f64,
    err_max_m: f64,
}

impl PairTest for Window {
    fn name(&self) -> &'static str {
        "window"
    }
    fn evaluate(&self, pair: &Pair) -> Outcome {
        let Window { multiplier, window_m, err_min_m, err_max_m } = self;
        let (ea, eb, dce) = (pair.a, pair.b, pair.default_ce_m);
        let d = pair.distance();
        let ea_e = ea.ce(dce).clamp(*err_min_m, *err_max_m);
        let eb_e = eb.ce(dce).clamp(*err_min_m, *err_max_m);
        let limit = multiplier * (ea_e * ea_e + eb_e * eb_e).sqrt() + window_m;
        Outcome::ran(d, limit, d < limit)
    }
}

struct Mahalanobis {
    gate: f64,
}

impl PairTest for Mahalanobis {
    fn name(&self) -> &'static str {
        "mahalanobis"
    }
    fn evaluate(&self, pair: &Pair) -> Outcome {
        let d2 = pair.d2();
        Outcome::ran(d2, self.gate, d2 < self.gate)
    }
}

struct Course {
    max_deg: f64,
    min_speed_ms: f64,
}

impl PairTest for Course {
    fn name(&self) -> &'static str {
        "course"
    }
    fn evaluate(&self, pair: &Pair) -> Outcome {
        match pair.courses(self.min_speed_ms) {
            None => Outcome::skipped(),
            Some((ca, cb)) => {
                let diff = (ca - cb).abs();
                let v = diff.min(360.0 - diff);
                Outcome::ran(v, self.max_deg, v <= self.max_deg)
            }
        }
    }
}

struct Speed {
    max_pct: f64,
    min_speed_ms: f64,
}

impl PairTest for Speed {
    fn name(&self) -> &'static str {
        "speed"
    }
    fn evaluate(&self, pair: &Pair) -> Outcome {
        match pair.speeds(self.min_speed_ms) {
            None => Outcome::skipped(),
            Some((sa, sb)) => {
                let (slow, fast) = (sa.min(sb), sa.max(sb));
                let v = if fast == 0.0 { 0.0 } else { (1.0 - slow / fast).abs() * 100.0 };
                Outcome::ran(v, self.max_pct, v <= self.max_pct)
            }
        }
    }
}

struct Altitude {
    max_m: f64,
}

impl PairTest for Altitude {
    fn name(&self) -> &'static str {
        "altitude"
    }
    fn evaluate(&self, pair: &Pair) -> Outcome {
        match (pair.a_number("hae"), pair.b_number("hae")) {
            (Some(ha), Some(hb)) => {
                let v = (ha - hb).abs();
                Outcome::ran(v, self.max_m, v <= self.max_m)
            }
            _ => Outcome::skipped(),
        }
    }
}

struct Same {
    key: String,
}

impl PairTest for Same {
    fn name(&self) -> &'static str {
        "same"
    }
    fn evaluate(&self, pair: &Pair) -> Outcome {
        let key = &self.key;
        let (va, vb) = (pair.a.same_value(key), pair.b.same_value(key));
        let pass = match (&va, &vb) {
            (Some(x), Some(y)) => x.same(y),
            (None, None) => true,
            _ => false,
        };
        Outcome { value: va.unwrap_or(Json::Null), limit: vb.unwrap_or(Json::Null), pass, skipped: false }
    }
}

fn built<T: PairTest + 'static>(t: T) -> Result<Arc<dyn PairTest>, String> {
    Ok(Arc::new(t))
}

/// The spec's test kinds, one entry each.
pub const BUILTIN_TESTS: &[TestKind] = &[
    TestKind { name: "distance", params: &["max_m"], build: |p| built(Distance { max_m: p.num("max_m")? }) },
    TestKind {
        name: "window",
        params: &["multiplier", "window_m", "err_min_m", "err_max_m"],
        build: |p| {
            built(Window {
                multiplier: p.num("multiplier")?,
                window_m: p.num("window_m")?,
                err_min_m: p.num("err_min_m")?,
                err_max_m: p.num("err_max_m")?,
            })
        },
    },
    TestKind { name: "mahalanobis", params: &["gate"], build: |p| built(Mahalanobis { gate: p.num("gate")? }) },
    TestKind {
        name: "course",
        params: &["max_deg", "min_speed_ms"],
        build: |p| built(Course { max_deg: p.num("max_deg")?, min_speed_ms: p.num("min_speed_ms")? }),
    },
    TestKind {
        name: "speed",
        params: &["max_pct", "min_speed_ms"],
        build: |p| built(Speed { max_pct: p.num("max_pct")?, min_speed_ms: p.num("min_speed_ms")? }),
    },
    TestKind { name: "altitude", params: &["max_m"], build: |p| built(Altitude { max_m: p.num("max_m")? }) },
    TestKind { name: "same", params: &["key"], build: |p| built(Same { key: p.string("key")? }) },
];

/// Parses the words after `gate`, `confirm` or `hold`: a test name the
/// registry knows, then exactly its parameters.
pub(crate) fn parse_test(args: &[&str], kinds: &[TestKind]) -> Result<Test, String> {
    let (name, rest) = args.split_first().ok_or("test line without a test name")?;
    let kind = kinds.iter().find(|k| k.name == *name).ok_or_else(|| format!("unknown test: {:?}", name))?;
    let params = Params::parse(rest, kind.params)?;
    Ok(Test((kind.build)(&params)?))
}

impl Engine {
    /// Runs `tests` in order between A and B, writing each to the trace and
    /// stopping at the first failure. True when every test passed.
    pub(crate) fn run_tests(&self, stage: &str, tests: &[Test], a: &str, b: &str, out: &mut StepResult) -> bool {
        let seen = || self.predict_seen_by(a, b);
        let pair = Pair { a: &self.entities[a], b: &self.entities[b], default_ce_m: self.pack.filter.default_ce_m, seen: &seen };
        for t in tests {
            let o = t.0.evaluate(&pair);
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
