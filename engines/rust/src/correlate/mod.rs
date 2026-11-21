//! Correlate (spec/correlate.md 1.0, with the method of
//! spec/correlate-assign.md 0.7): the engine shared by both methods. Here:
//! Reports with Time quality, Track estimate with Measurement variance,
//! Two-model filter, Restart, Tests, the stale time of a source, and the
//! dispatch of `tick` and `snapshot` to the pack's method (`confirm` in
//! `confirm.rs`, with its sequential test in `sprt.rs`; `assign` in
//! `crate::assign`).

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use crate::model::report;
use crate::model::{deg, measurement_variance, obj, velocity, Axis, Frame, Json, Measurement, MeasurementVariance, Model};
use crate::trace::record;

mod confirm;
mod entity;
pub mod method;
pub mod pack;
pub mod pair_tests;
pub mod registry;
mod restart;
mod sprt;

pub(crate) use entity::{report_ce, Entity};

pub use crate::trace::StepResult;
pub use method::MethodKind;
pub use pack::{load_pack, parse_pack, parse_pack_with, Output, Pack, Params, Sprt, StaleRate, Staleness, Test};
pub use pair_tests::{Outcome, Pair, PairTest, TestKind};
pub use registry::Registry;

crate::function::function!(Engine, "correlate", Pack, parse_pack);

pub(crate) fn pair_key(a: &str, b: &str) -> (String, String) {
    if a <= b {
        (a.to_string(), b.to_string())
    } else {
        (b.to_string(), a.to_string())
    }
}

pub(crate) fn group_name(n: u64) -> String {
    format!("g{}", n)
}

/// The engine: all of its state, read out by `snapshot()`. `Clone` copies
/// the state, so a copy continues exactly as the original would.
#[derive(Clone)]
pub struct Engine {
    pub(crate) pack: Pack,
    pub(crate) frame: Option<Frame>,
    pub(crate) entities: BTreeMap<String, Entity>,
    pub(crate) groups: BTreeMap<u64, BTreeSet<String>>,
    pub(crate) counts: BTreeMap<(String, String), u64>,
    /// `sprt`: each pair's log-likelihood ratio `L` (Association, Sequential test).
    pub(crate) llr: BTreeMap<(String, String), f64>,
    /// `stale_rate`: each source's last intervals, oldest first (Stale time
    /// of a source).
    pub(crate) intervals: BTreeMap<String, VecDeque<i64>>,
    pub(crate) next_group: u64,
    /// `method assign`: the committed membership (correlate-assign.md Memberships).
    pub(crate) committed: crate::assign::Membership,
    /// `method assign`: the histories, in rank order.
    pub(crate) histories: Vec<crate::assign::History>,
    /// `method assign`: stale entities whose drop is not yet committed.
    pub(crate) retiring: BTreeSet<String>,
    /// `method assign`: entities with an accepted report since the previous tick.
    pub(crate) reported: BTreeSet<String>,
    /// `method assign` with `restart`: entities whose filter started again
    /// since the previous tick (correlate.md Restart).
    pub(crate) restarted: BTreeSet<String>,
    /// `method assign` with `bias`: the stored offset per pair key `"<S>|<T>"`
    /// (correlate-assign.md Sensor bias, State).
    pub(crate) bias: BTreeMap<String, crate::assign::PairBias>,
}

impl Engine {
    pub fn new(pack: Pack) -> Engine {
        Engine {
            pack,
            frame: None,
            entities: BTreeMap::new(),
            groups: BTreeMap::new(),
            counts: BTreeMap::new(),
            llr: BTreeMap::new(),
            intervals: BTreeMap::new(),
            next_group: 1,
            committed: crate::assign::Membership::default(),
            histories: vec![crate::assign::History::default()],
            retiring: BTreeSet::new(),
            reported: BTreeSet::new(),
            restarted: BTreeSet::new(),
            bias: BTreeMap::new(),
        }
    }

    // ---- ingest (spec: Reports, Track estimate, Association "On each accepted report")

    pub fn ingest(&mut self, report: &Json) -> StepResult {
        let mut out = StepResult::default();
        let empty = BTreeMap::new();
        let fields = report.as_object().unwrap_or(&empty);

        // Reports: required keys, checked in table order (src/report.rs).
        let required = match report::required(fields) {
            Ok(r) => r,
            Err(missing) => {
                out.events.push(report::reject_missing(missing));
                return out;
            }
        };
        let report::Required { source, time_ms, lat, lon, .. } = required;
        let key = required.key();

        // correlate-assign.md Window: a retiring entity's reports are refused.
        if self.retiring.contains(&key) {
            out.events.push(obj(vec![("ev", "reject".into()), ("entity", key.as_str().into()), ("reason", "retiring".into())]));
            return out;
        }

        if let Some(e) = self.entities.get(&key) {
            if time_ms < e.last_time_ms {
                out.events.push(obj(vec![
                    ("ev", "reject".into()),
                    ("entity", key.as_str().into()),
                    ("reason", "out-of-order".into()),
                ]));
                return out;
            }
        }

        // Frame: the reference is the first accepted report.
        let frame = *self.frame.get_or_insert(Frame { lat0: lat, lon0: lon });
        let (ze, zn) = frame.to_plane(lat, lon);

        // Track estimate.
        let f = self.pack.filter.clone();
        let ce = report_ce(fields).unwrap_or(f.default_ce_m);
        let vel = velocity(fields.get("course").and_then(Json::as_f64), fields.get("speed_ms").and_then(Json::as_f64));

        // Reports, Time quality: `te`, from the report, else the pack's
        // `time_default` for the source, else 0. The time state is resolved
        // with it but not used by correlate in this version.
        let te = report::time_quality(fields, source, &self.pack.time_default).error_ms;

        // Track estimate, Measurement variance: the velocity is the entity's
        // prediction to this report's time (for its first report: the
        // measured velocity, or 0).
        let variance = measurement_variance(ce, te, || match self.entities.get(&key) {
            Some(e) => {
                let (pe, pn) = e.predict(time_ms, &self.pack);
                (pe.v, pn.v)
            }
            None => vel.unwrap_or((0.0, 0.0)),
        });
        if let Some((var_e, var_n)) = variance.time_var {
            out.trace.push(obj(vec![
                ("stage", "filter".into()),
                ("a", key.as_str().into()),
                ("b", Json::Null),
                ("test", "time".into()),
                ("value", te.into()),
                ("limit", Json::Null),
                ("pass", true.into()),
                ("var_east", var_e.into()),
                ("var_north", var_n.into()),
            ]));
        }
        let MeasurementVariance { r, time_var } = variance;

        let meas = Measurement { pos: (ze, zn), r_pos: r, vel, r_vel: f.vel_sigma_ms * f.vel_sigma_ms };
        let maneuver = self.pack.maneuver.clone();

        // Track estimate, first report; Two-model filter, first report. Also
        // the filter a Restart starts again from.
        let first_filter = || entity::first_filter(&meas, &f, maneuver.as_ref());

        let mut restarted = false;
        match self.entities.get(&key) {
            None => {
                let (east, north, imm) = first_filter();
                self.entities.insert(
                    key.clone(),
                    Entity {
                        source: source.to_string(),
                        last_time_ms: time_ms,
                        group: None,
                        system: None,
                        hold_failures: 0,
                        east,
                        north,
                        imm,
                        report: fields.clone(),
                        r,
                        time_var,
                    },
                );
                out.events.push(obj(vec![("ev", "new".into()), ("entity", key.as_str().into())]));
            }
            Some(e) => {
                // Stale time of a source: the interval since the entity's
                // last report joins the list of its (the entity's) source,
                // which keeps the last n.
                if let pack::Staleness::Rate(rate) = &self.pack.stale {
                    let list = self.intervals.entry(e.source.clone()).or_default();
                    list.push_back(time_ms - e.last_time_ms);
                    while list.len() > rate.samples {
                        list.pop_front();
                    }
                }
                // Restart (correlate.md): before the filter update, d² of the
                // report against the entity predicted to its time.
                let mut restart = false;
                if let Some(g) = self.pack.restart {
                    let (value, pass) = restart::test(e.predict(time_ms, &self.pack), (ze, zn), r, g);
                    out.trace.push(restart::record(&key, value, g, pass));
                    restart = !pass;
                }

                let e = self.entities.get_mut(&key).expect("checked above");
                if restart {
                    // The filter starts again from this report as a first
                    // report; key, group, pair counts and hold failures stay.
                    let (east, north, imm) = first_filter();
                    e.east = east;
                    e.north = north;
                    e.imm = imm;
                } else {
                    let dt = (time_ms - e.last_time_ms) as f64 / 1000.0;
                    let (next, mode) = entity::later_filter(e, dt, &meas, &f, maneuver.as_ref());
                    (e.east, e.north, e.imm) = next;
                    // Two-model filter: `likelihood` and `mode` per model.
                    if let Some(mode) = mode {
                        for (test, values) in [("likelihood", mode.lambda), ("mode", mode.mu)] {
                            for (model, value) in ["quiet", "maneuver"].into_iter().zip(values) {
                                out.trace.push(record("filter", &key, model, test, value.into(), Json::Null, true, false));
                            }
                        }
                    }
                }
                e.last_time_ms = time_ms;
                e.report = fields.clone();
                // The entity keeps this report's measurement and timing
                // variance, also after a restart.
                e.r = r;
                e.time_var = time_var;
                restarted = restart;
            }
        }

        (self.pack.method.ingested)(self, key, restarted, &mut out);
        out
    }

    // ---- tick (spec: Association "On each tick")

    /// Entities stale at `now_ms`, in key order (spec: On each tick, Staleness).
    pub(crate) fn stale_entities(&self, now_ms: i64) -> Vec<String> {
        self.entities
            .iter()
            .filter(|(_, e)| {
                self.is_past_stale_time(&e.source, now_ms - e.last_time_ms)
                    || e.report.get("stale_ms").and_then(Json::as_i64).is_some_and(|s| now_ms >= s)
            })
            .map(|(k, _)| k.clone())
            .collect()
    }

    /// Whether `age` ms is above the source's stale time: `stale_ms`, or
    /// with `stale_rate` `k * m` (`m` the lower median of the source's
    /// intervals) raised to `floor_ms` and lowered to `ceiling_ms`, and
    /// `ceiling_ms` with no interval.
    fn is_past_stale_time(&self, source: &str, age: i64) -> bool {
        match &self.pack.stale {
            pack::Staleness::Fixed(ms) => age > *ms,
            pack::Staleness::Rate(rate) => (age as f64) > stale_time(rate, self.intervals.get(source)),
        }
    }

    /// `intervals` of the snapshot, with `stale_rate`: each source with at
    /// least one interval, oldest first.
    pub(crate) fn intervals_json(&self) -> Option<(&'static str, Json)> {
        match self.pack.stale {
            pack::Staleness::Rate(_) => Some((
                "intervals",
                Json::Obj(self.intervals.iter().map(|(s, l)| (s.clone().into(), Json::Arr(l.iter().map(|i| Json::Int(*i)).collect()))).collect()),
            )),
            pack::Staleness::Fixed(_) => None,
        }
    }

    /// On each tick: the pack's method.
    pub fn tick(&mut self, now_ms: i64) -> StepResult {
        (self.pack.method.tick)(self, now_ms)
    }

    /// The snapshot: the pack's method's.
    pub fn snapshot(&self) -> Json {
        (self.pack.method.snapshot)(self)
    }

    pub(crate) fn reference_json(&self) -> Json {
        crate::snapshot::reference(self.frame)
    }

}
/// A source's stale time with `stale_rate`, ms: `k * m` clamped to
/// `[floor_ms, ceiling_ms]`, or `ceiling_ms` with an empty list.
pub(crate) fn stale_time(rate: &pack::StaleRate, intervals: Option<&VecDeque<i64>>) -> f64 {
    let Some(list) = intervals.filter(|l| !l.is_empty()) else { return rate.ceiling_ms as f64 };
    let mut sorted: Vec<i64> = list.iter().copied().collect();
    sorted.sort_unstable();
    let m = sorted[(sorted.len() - 1) / 2];
    let t = rate.factor * m as f64;
    if t < rate.floor_ms as f64 {
        rate.floor_ms as f64
    } else if t > rate.ceiling_ms as f64 {
        rate.ceiling_ms as f64
    } else {
        t
    }
}

/// `course = deg(atan2(ve, vn))` in [0, 360) and `speed_ms = hypot(ve, vn)`.
pub(crate) fn course_speed(east: &Axis, north: &Axis) -> (f64, f64) {
    let mut course = deg(east.v.atan2(north.v));
    if course < 0.0 {
        course += 360.0;
    }
    if course >= 360.0 {
        course -= 360.0;
    }
    (course, east.v.hypot(north.v))
}

/// The snapshot's `filter`, plus `models` and `mode` with two models.
pub(crate) fn filter_json(e: &Entity) -> Vec<(&'static str, Json)> {
    let mut pairs = vec![("filter", crate::snapshot::model(&Model { east: e.east, north: e.north }))];
    if let Some(two) = &e.imm {
        pairs.push(("models", obj(vec![("quiet", crate::snapshot::model(&two.models[0])), ("maneuver", crate::snapshot::model(&two.models[1]))])));
        pairs.push(("mode", Json::Arr(vec![two.mu[0].into(), two.mu[1].into()])));
    }
    // `time`, when the last report had a time error above 0.
    if let Some((var_e, var_n)) = e.time_var {
        pairs.push(("time", obj(vec![("var_east", var_e.into()), ("var_north", var_n.into())])));
    }
    pairs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_time_is_the_lower_median_times_k_within_the_bounds() {
        let rate = pack::StaleRate { factor: 5.0, floor_ms: 20_000, ceiling_ms: 60_000, samples: 9 };
        assert_eq!(stale_time(&rate, None), 60_000.0);
        assert_eq!(stale_time(&rate, Some(&VecDeque::new())), 60_000.0);
        assert_eq!(stale_time(&rate, Some(&VecDeque::from(vec![10_000, 4_000, 8_000, 6_000]))), 30_000.0);
        assert_eq!(stale_time(&rate, Some(&VecDeque::from(vec![200, 200]))), 20_000.0);
        assert_eq!(stale_time(&rate, Some(&VecDeque::from(vec![30_000]))), 60_000.0);
    }
}
