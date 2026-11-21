//! correlate.md Tests: A, the entity just reported, against B predicted to
//! A's `time_ms`; each test's `value`, `limit` and `pass`, run in pack order
//! within a stage and stopping at the first failure.
//!
//! **The registration point of a test kind.** Every kind is one `TestKind`
//! entry: its name in a pack line, its parameters, and a builder that turns
//! the parameters into a `PairTest`. `BUILTIN_TESTS` holds the spec's seven
//! (correlate.md 1.0: `window` is retired, `state` is added);
//! `Registry::register_test` adds one more for a pack parsed with
//! `parse_pack_with` (see tests/registry.rs for a no-op kind that only the
//! tests register).

use std::fmt;
use std::sync::Arc;

use super::pack::Params;
use super::{Engine, Entity};
use crate::model::{Axis, Json, StateDifference};
use crate::trace::{record, StepResult};

/// The result of one test (spec: Tests).
#[derive(Debug, Clone, PartialEq)]
pub struct Outcome {
    pub value: Json,
    pub limit: Json,
    pub pass: bool,
    pub skipped: bool,
    /// Keys the test adds to its trace record (the `state` test's `dof`).
    pub extra: Vec<(&'static str, Json)>,
}

impl Outcome {
    /// A test that ran: numeric `value` and `limit`.
    pub fn ran(value: f64, limit: f64, pass: bool) -> Outcome {
        Outcome { value: value.into(), limit: limit.into(), pass, skipped: false, extra: Vec::new() }
    }

    /// A skipped test: `value` and `limit` null, passes.
    pub fn skipped() -> Outcome {
        Outcome { value: Json::Null, limit: Json::Null, pass: true, skipped: true, extra: Vec::new() }
    }
}

/// What a test reads about one pair: A as filtered, and B predicted to A's
/// `time_ms` as A sees it (B's timing variance added; with `bias`, moved
/// into A's frame). The prediction is computed when a test asks for it.
pub struct Pair<'a> {
    pub(crate) a: &'a Entity,
    pub(crate) b: &'a Entity,
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

    /// The whole-state difference per axis, east and north (the `state` test).
    pub fn state(&self) -> (StateDifference, StateDifference) {
        state(self.a, (self.seen)())
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

/// The whole-state difference of A's filter against B's prediction as A
/// sees it, per axis, with A's timing variance in `spp`.
pub(crate) fn state(a: &Entity, (pe, pn): (Axis, Axis)) -> (StateDifference, StateDifference) {
    let (ta_e, ta_n) = a.timing_variance();
    (StateDifference::of(&a.east, ta_e, &pe), StateDifference::of(&a.north, ta_n, &pn))
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
        Outcome { value: va.unwrap_or(Json::Null), limit: vb.unwrap_or(Json::Null), pass, skipped: false, extra: Vec::new() }
    }
}

/// The chi-square quantiles of the `state` test (Abramowitz and Stegun
/// 1964, table 26.8): `(probability, 4 dof, 5 dof)`.
const CHI_SQUARE: [(f64, f64, f64); 4] = [(0.95, 9.4877, 11.0705), (0.99, 13.2767, 15.0863), (0.995, 14.8603, 16.7496), (0.999, 18.4668, 20.5150)];

/// `state`: the track-to-track statistic on the full state (Bar-Shalom
/// 1981), with height when both last reports have `hae`.
struct State {
    /// The limits for 4 and 5 degrees of freedom.
    limits: (f64, f64),
    hae_sigma_m: f64,
}

impl State {
    fn build(p: &Params) -> Result<Arc<dyn PairTest>, String> {
        let probability = p.num("probability")?;
        let &(_, l4, l5) = CHI_SQUARE.iter().find(|(pr, _, _)| *pr == probability).ok_or_else(|| format!("state probability {} is not in the table", probability))?;
        let hae_sigma_m = p.num("hae_sigma_m")?;
        if !(hae_sigma_m > 0.0) {
            return Err("state hae_sigma_m must be above 0".to_string());
        }
        built(State { limits: (l4, l5), hae_sigma_m })
    }
}

impl PairTest for State {
    fn name(&self) -> &'static str {
        "state"
    }
    fn evaluate(&self, pair: &Pair) -> Outcome {
        let (e, n) = pair.state();
        let mut value = e.q + n.q;
        let (limit, dof) = match (pair.a_number("hae"), pair.b_number("hae")) {
            (Some(ha), Some(hb)) => {
                let (dh, h) = (ha - hb, self.hae_sigma_m);
                value += dh * dh / (2.0 * h * h);
                (self.limits.1, 5)
            }
            _ => (self.limits.0, 4),
        };
        Outcome { extra: vec![("dof", Json::Int(dof))], ..Outcome::ran(value, limit, value < limit) }
    }
}

fn built<T: PairTest + 'static>(t: T) -> Result<Arc<dyn PairTest>, String> {
    Ok(Arc::new(t))
}

/// The spec's test kinds, one entry each.
pub const BUILTIN_TESTS: &[TestKind] = &[
    TestKind { name: "distance", params: &["max_m"], build: |p| built(Distance { max_m: p.num("max_m")? }) },
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
    TestKind { name: "state", params: &["probability", "hae_sigma_m"], build: State::build },
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
        self.run_tests_traced(stage, tests, a, b, Some(out))
    }

    /// As `run_tests`; without `out`, no trace record is written.
    pub(crate) fn run_tests_traced(&self, stage: &str, tests: &[Test], a: &str, b: &str, mut out: Option<&mut StepResult>) -> bool {
        let seen = || self.predict_seen_by(a, b);
        let pair = Pair { a: &self.entities[a], b: &self.entities[b], seen: &seen };
        for t in tests {
            let o = t.0.evaluate(&pair);
            if let Some(out) = out.as_deref_mut() {
                let mut rec = record(stage, a, b, t.name(), o.value, o.limit, o.pass, o.skipped);
                if let Json::Obj(m) = &mut rec {
                    for (k, v) in o.extra {
                        m.insert(k.into(), v);
                    }
                }
                out.trace.push(rec);
            }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::correlate::parse_pack;
    use crate::model::json::parse;
    use std::collections::BTreeMap;

    fn entity(p: (f64, f64), report: &str) -> Entity {
        let axis = |p: f64| Axis { p, v: 0.0, pp: 1.0, pv: 0.0, vv: 1.0 };
        Entity {
            source: "s".into(),
            last_time_ms: 0,
            group: None,
            system: None,
            hold_failures: 0,
            east: axis(p.0),
            north: axis(p.1),
            imm: None,
            report: parse(report).unwrap().as_object().cloned().unwrap_or_else(BTreeMap::new),
            r: (1.0, 1.0),
            time_var: None,
        }
    }

    /// Runs the pack's gate tests (the test lines `lines`) between A and B.
    fn outcomes(lines: &str, a: &Entity, b: &Entity) -> Vec<Outcome> {
        let text = format!("pack p\nversion 0.1.0\nfilter accel_var=1 default_ce_m=10 vel_sigma_ms=5 unknown_vel_ms=100\nconfirm_count 1\nhold_failures 1\nstale_ms 1\n{}", lines);
        let pack = parse_pack(&text).unwrap();
        let seen = || (b.east, b.north);
        let pair = Pair { a, b, seen: &seen };
        pack.gate.iter().map(|t| t.0.evaluate(&pair)).collect()
    }

    #[test]
    fn distance_and_mahalanobis() {
        let (a, b) = (entity((0.0, 0.0), "{}"), entity((3.0, 4.0), r#"{"ce": 20}"#));
        let o = outcomes("gate distance max_m=5\ngate mahalanobis gate=12.6\n", &a, &b);
        assert_eq!(o[0], Outcome::ran(5.0, 5.0, false));
        assert_eq!(o[1], Outcome::ran(12.5, 12.6, true));
    }

    #[test]
    fn state_reads_the_table_and_adds_height() {
        // pp 1 and vv 1 on both: spp = 2, svv = 2, det = 4; q = 2*dp*dp/4.
        let (a, b) = (entity((0.0, 0.0), r#"{"hae": 100}"#), entity((2.0, 0.0), r#"{"hae": 120}"#));
        let o = outcomes("gate state probability=0.990 hae_sigma_m=10\n", &a, &b);
        assert_eq!(o[0], Outcome { extra: vec![("dof", Json::Int(5))], ..Outcome::ran(2.0 + 400.0 / 200.0, 15.0863, true) });
        let c = entity((2.0, 0.0), "{}");
        let o = outcomes("gate state probability=0.95 hae_sigma_m=10\n", &a, &c);
        assert_eq!(o[0], Outcome { extra: vec![("dof", Json::Int(4))], ..Outcome::ran(2.0, 9.4877, true) });
        let text = "pack p\nversion 0.1.0\nfilter accel_var=1 default_ce_m=10 vel_sigma_ms=5 unknown_vel_ms=100\nconfirm_count 1\nhold_failures 1\nstale_ms 1\n";
        assert!(parse_pack(&format!("{}gate state probability=0.9 hae_sigma_m=1\n", text)).unwrap_err().contains("not in the table"));
        assert!(parse_pack(&format!("{}gate state probability=0.99 hae_sigma_m=0\n", text)).unwrap_err().contains("above 0"));
        assert!(parse_pack(&format!("{}gate window multiplier=1 window_m=0 err_min_m=1 err_max_m=15\n", text)).unwrap_err().contains("unknown test"));
    }

    #[test]
    fn course_speed_altitude_skip_without_values() {
        let a = entity((0.0, 0.0), r#"{"course": 350, "speed_ms": 10, "hae": 100}"#);
        let b = entity((0.0, 0.0), r#"{"course": 20, "speed_ms": 8, "hae": 400}"#);
        let lines = "gate course max_deg=30 min_speed_ms=5\ngate speed max_pct=10 min_speed_ms=5\ngate altitude max_m=250\n";
        let o = outcomes(lines, &a, &b);
        assert_eq!(o[0], Outcome::ran(30.0, 30.0, true));
        assert!((o[1].value.as_f64().unwrap() - 20.0).abs() < 1e-12 && !o[1].pass);
        assert_eq!(o[2], Outcome::ran(300.0, 250.0, false));
        let bare = entity((0.0, 0.0), r#"{"speed_ms": 1}"#);
        assert!(outcomes(lines, &a, &bare).iter().all(|o| o.skipped && o.pass));
        let still = entity((0.0, 0.0), r#"{"speed_ms": 0}"#);
        assert_eq!(outcomes("gate speed max_pct=10 min_speed_ms=0\n", &still, &still)[0], Outcome::ran(0.0, 10.0, true));
    }

    #[test]
    fn same_compares_values_and_env() {
        let a = entity((0.0, 0.0), r#"{"type": "a-f-G-U", "k": 1}"#);
        let b = entity((0.0, 0.0), r#"{"type": "a-h-G", "k": 1.0}"#);
        let o = outcomes("gate same key=@env\ngate same key=k\ngate same key=absent\n", &a, &b);
        assert!(o.iter().all(|o| o.pass), "{:?}", o);
        assert_eq!(o[0].value, Json::from("G"));
        let c = entity((0.0, 0.0), r#"{"type": "a-h"}"#);
        let o = outcomes("gate same key=@env\ngate same key=k\n", &a, &c);
        assert_eq!((o[0].pass, o[0].limit.clone(), o[1].pass), (false, Json::Null, false));
    }

    #[test]
    fn builtin_kinds_are_the_spec_tests() {
        let names: Vec<&str> = BUILTIN_TESTS.iter().map(|k| k.name).collect();
        assert_eq!(names, ["distance", "mahalanobis", "course", "speed", "altitude", "same", "state"]);
        assert!(format!("{:?}", BUILTIN_TESTS[0]).contains("distance"));
        assert!(parse_test(&["nearby"], BUILTIN_TESTS).unwrap_err().contains("unknown test"));
        assert_eq!(format!("{:?}", parse_test(&["mahalanobis", "gate=1"], BUILTIN_TESTS).unwrap()), "Test(mahalanobis)");
    }
}
