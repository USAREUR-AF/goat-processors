//! The four operations' engine: ingest, tick, snapshot (spec/correlate.md 0.8:
//! Reports with Time quality, Track estimate with Measurement variance,
//! Two-model filter, Restart, Tests, Association, Events, Trace, Snapshot).

use std::collections::{BTreeMap, BTreeSet};

use crate::filter::{deg, rad, Axis, Frame, Measurement, Model, TwoModel};
use crate::json::{obj, Json};
use crate::pack::{Method, Output, Pack, Test};
use crate::report;

mod assign;

/// What `ingest` and `tick` return.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct StepResult {
    pub events: Vec<Json>,
    pub trace: Vec<Json>,
}

#[derive(Debug, Clone)]
struct Entity {
    source: String,
    last_time_ms: i64,
    group: Option<u64>,
    /// `method assign`: the entity's system track in the committed membership.
    system: Option<u64>,
    hold_failures: u64,
    /// The entity's filter; with two models, their combination.
    east: Axis,
    north: Axis,
    /// With the pack's `maneuver` directive: the two models and `mu`.
    imm: Option<TwoModel>,
    /// The entity's last accepted report.
    report: BTreeMap<String, Json>,
    /// That report's measurement variance `(r_east, r_north)` (Track
    /// estimate, Measurement variance).
    r: (f64, f64),
    /// That report's timing variance `((v_e*ts)², (v_n*ts)²)`; `None` when its
    /// time error was 0, which reads as 0 and 0.
    time_var: Option<(f64, f64)>,
}

impl Entity {
    fn num(&self, key: &str) -> Option<f64> {
        self.report.get(key).and_then(Json::as_f64)
    }

    /// Last `ce`, or the pack's `default_ce_m`.
    fn ce(&self, default_ce_m: f64) -> f64 {
        report_ce(&self.report).unwrap_or(default_ce_m)
    }

    /// `@env`: the third `-`-separated element of `type`; absent when `type`
    /// is absent or has fewer than three elements.
    fn env(&self) -> Option<Json> {
        let t = self.report.get("type")?.as_str()?;
        t.split('-').nth(2).map(Json::from)
    }

    /// Value for a `same` test.
    fn same_value(&self, key: &str) -> Option<Json> {
        if key == "@env" {
            self.env()
        } else {
            self.report.get(key).filter(|v| **v != Json::Null).cloned()
        }
    }

    /// The timing variance per axis, 0 and 0 when the last report's time
    /// error was 0.
    fn timing_variance(&self) -> (f64, f64) {
        self.time_var.unwrap_or((0.0, 0.0))
    }

    /// Prediction to time `t` for a comparison with another entity: the
    /// prediction with this entity's timing variance added to `pp` on each
    /// axis (Track estimate, Measurement variance).
    fn predict_for_comparison(&self, t: i64, pack: &Pack) -> (Axis, Axis) {
        let (pe, pn) = self.predict(t, pack);
        let (var_e, var_n) = self.timing_variance();
        (Axis { pp: pe.pp + var_e, ..pe }, Axis { pp: pn.pp + var_n, ..pn })
    }

    /// Prediction to time `t` (spec: Track estimate, Prediction; Two-model
    /// filter, Prediction). Never changes the entity.
    fn predict(&self, t: i64, pack: &Pack) -> (Axis, Axis) {
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
fn report_ce(report: &BTreeMap<String, Json>) -> Option<f64> {
    report::optional_f64(report, "ce")
}

/// The result of one test (spec: Tests).
struct Outcome {
    value: Json,
    limit: Json,
    pass: bool,
    skipped: bool,
}

impl Outcome {
    fn ran(value: f64, limit: f64, pass: bool) -> Outcome {
        Outcome { value: value.into(), limit: limit.into(), pass, skipped: false }
    }

    fn skipped() -> Outcome {
        Outcome { value: Json::Null, limit: Json::Null, pass: true, skipped: true }
    }
}

fn record(stage: &str, a: &str, b: &str, test: &str, value: Json, limit: Json, pass: bool, skipped: bool) -> Json {
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

fn pair_key(a: &str, b: &str) -> (String, String) {
    if a <= b {
        (a.to_string(), b.to_string())
    } else {
        (b.to_string(), a.to_string())
    }
}

fn group_name(n: u64) -> String {
    format!("g{}", n)
}

pub struct Engine {
    pack: Pack,
    frame: Option<Frame>,
    entities: BTreeMap<String, Entity>,
    groups: BTreeMap<u64, BTreeSet<String>>,
    counts: BTreeMap<(String, String), u64>,
    next_group: u64,
    /// `method assign`: the committed membership (correlate-assign.md Memberships).
    committed: assign::Membership,
    /// `method assign`: the histories, in rank order.
    histories: Vec<assign::History>,
    /// `method assign`: stale entities whose drop is not yet committed.
    retiring: BTreeSet<String>,
    /// `method assign`: entities with an accepted report since the previous tick.
    reported: BTreeSet<String>,
    /// `method assign` with `restart`: entities whose filter started again
    /// since the previous tick (correlate.md Restart).
    restarted: BTreeSet<String>,
    /// `method assign` with `bias`: the stored offset per pair key `"<S>|<T>"`
    /// (correlate-assign.md Sensor bias, State).
    bias: BTreeMap<String, assign::PairBias>,
}

impl Engine {
    pub fn new(pack: Pack) -> Engine {
        Engine {
            pack,
            frame: None,
            entities: BTreeMap::new(),
            groups: BTreeMap::new(),
            counts: BTreeMap::new(),
            next_group: 1,
            committed: assign::Membership::default(),
            histories: vec![assign::History::default()],
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
        let course = fields.get("course").and_then(Json::as_f64);
        let speed = fields.get("speed_ms").and_then(Json::as_f64);
        let vel = match (course, speed) {
            (Some(c), Some(s)) => Some((s * rad(c).sin(), s * rad(c).cos())),
            _ => None,
        };

        // Reports, Time quality: `te`, from the report, else the pack's
        // `time_default` for the source, else 0. The time state is resolved
        // with it but not used by correlate in this version.
        let time = report::time_quality(fields, source, &self.pack.time_default);
        let te = time.error_ms;

        // Track estimate, Measurement variance. With `te` 0, r = ce² on both
        // axes. Otherwise the velocity comes from the entity's prediction to
        // this report's time (for its first report: the measured velocity, or
        // 0), `ts = te / 1000`, and r = ce² + (v*ts)² per axis.
        let (r, time_var) = if te == 0.0 {
            ((ce * ce, ce * ce), None)
        } else {
            let (v_e, v_n) = match self.entities.get(&key) {
                Some(e) => {
                    let (pe, pn) = e.predict(time_ms, &self.pack);
                    (pe.v, pn.v)
                }
                None => vel.unwrap_or((0.0, 0.0)),
            };
            let ts = te / 1000.0;
            let (de, dn) = (v_e * ts, v_n * ts);
            let (var_e, var_n) = (de * de, dn * dn);
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
            ((ce * ce + var_e, ce * ce + var_n), Some((var_e, var_n)))
        };
        let (r_east, r_north) = r;

        let meas = Measurement { pos: (ze, zn), r_pos: r, vel, r_vel: f.vel_sigma_ms * f.vel_sigma_ms };
        let maneuver = self.pack.maneuver.clone();

        // Track estimate, first report (pp = that axis's measurement
        // variance); Two-model filter, first report. Also the filter a
        // Restart starts again from.
        let first_filter = || {
            let east = Axis::first_with_variance(ze, vel.map(|v| v.0), r_east, f.vel_sigma_ms, f.unknown_vel_ms);
            let north = Axis::first_with_variance(zn, vel.map(|v| v.1), r_north, f.vel_sigma_ms, f.unknown_vel_ms);
            let imm = maneuver.as_ref().map(|m| TwoModel::first(Model { east, north }, m.p_enter, m.p_leave));
            (east, north, imm)
        };

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
                // Restart (correlate.md): before the filter update, d² of the
                // report against the entity predicted to its time.
                let mut restart = false;
                if let Some(g) = self.pack.restart {
                    // The entity's own prediction: no timing variance added.
                    let (pe, pn) = e.predict(time_ms, &self.pack);
                    let d2 = (ze - pe.p) * (ze - pe.p) / (pe.pp + r_east) + (zn - pn.p) * (zn - pn.p) / (pn.pp + r_north);
                    let pass = d2 < g;
                    out.trace.push(obj(vec![
                        ("stage", "filter".into()),
                        ("a", key.as_str().into()),
                        ("b", Json::Null),
                        ("test", "restart".into()),
                        ("value", d2.into()),
                        ("limit", g.into()),
                        ("pass", pass.into()),
                    ]));
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
                    match (&e.imm, &maneuver) {
                        (Some(two), Some(m)) => {
                            // Two-model filter, later reports, steps 1 to 5.
                            let (next, mode) = two.step(dt, [f.accel_var, m.accel_var], m.p_enter, m.p_leave, &meas);
                            let combined = next.combined();
                            e.east = combined.east;
                            e.north = combined.north;
                            e.imm = Some(next);
                            for (test, values) in [("likelihood", mode.lambda), ("mode", mode.mu)] {
                                for (model, value) in ["quiet", "maneuver"].into_iter().zip(values) {
                                    out.trace.push(record("filter", &key, model, test, value.into(), Json::Null, true, false));
                                }
                            }
                        }
                        _ => {
                            // Track estimate, later reports, steps 1 to 3.
                            let (next, _) = Model { east: e.east, north: e.north }.step(dt, f.accel_var, &meas);
                            e.east = next.east;
                            e.north = next.north;
                        }
                    }
                }
                e.last_time_ms = time_ms;
                e.report = fields.clone();
                // The entity keeps this report's measurement and timing
                // variance, also after a restart.
                e.r = r;
                e.time_var = time_var;
                // With method assign the entity is restarted until the next tick.
                if restart && self.pack.method == Method::Assign {
                    self.restarted.insert(key.clone());
                }
            }
        }

        if self.pack.method == Method::Assign {
            // Assignment waits for the next tick.
            self.reported.insert(key);
        } else if self.entities[&key].group.is_some() {
            self.hold(&key, &mut out);
        } else {
            self.associate(&key, &mut out);
        }
        out
    }

    /// Association: A is in a group G, hold.
    fn hold(&mut self, a: &str, out: &mut StepResult) {
        let g = self.entities[a].group.expect("hold needs a group");
        let others: Vec<String> = self.groups[&g].iter().filter(|m| m.as_str() != a).cloned().collect();
        let tests = self.pack.hold.clone();
        let mut held = false;
        for b in &others {
            if self.run_tests("hold", &tests, a, b, out) {
                held = true;
                break;
            }
        }
        let limit = self.pack.hold_failures;
        let e = self.entities.get_mut(a).unwrap();
        if held {
            e.hold_failures = 0;
        } else {
            e.hold_failures += 1;
            if e.hold_failures >= limit {
                self.leave(a, "hold", out);
            }
        }
    }

    /// Association: A is not in a group, associate.
    fn associate(&mut self, a: &str, out: &mut StepResult) {
        let a_source = self.entities[a].source.clone();
        let allow = self.pack.same_source_allow;
        let candidates: Vec<String> = self
            .entities
            .iter()
            .filter(|(bk, b)| {
                bk.as_str() != a
                    && (allow || b.source != a_source)
                    && (allow || !b.group.is_some_and(|g| self.group_has_source(g, &a_source)))
            })
            .map(|(bk, _)| bk.clone())
            .collect();

        let gate = self.pack.gate.clone();
        let confirm = self.pack.confirm.clone();
        let need = self.pack.confirm_count;
        let mut confirmed: Vec<String> = Vec::new();
        for b in &candidates {
            let all_passed = self.run_tests("gate", &gate, a, b, out) && self.run_tests("confirm", &confirm, a, b, out);
            let pk = pair_key(a, b);
            let count = if all_passed { self.counts.get(&pk).copied().unwrap_or(0) + 1 } else { 0 };
            self.counts.insert(pk, count);
            out.trace.push(record("confirm", a, b, "count", (count as f64).into(), (need as f64).into(), count >= need, false));
            if count >= need {
                confirmed.push(b.clone());
            }
        }

        // Rank by d², ties to key order.
        let mut chosen: Option<(String, f64)> = None;
        for b in &confirmed {
            let d2 = self.d2(a, b);
            out.trace.push(record("rank", a, b, "rank", d2.into(), Json::Null, true, false));
            if chosen.as_ref().is_none_or(|(_, best)| d2 < *best) {
                chosen = Some((b.clone(), d2));
            }
        }
        let Some((b, _)) = chosen else { return };

        match self.entities[&b].group {
            Some(g) => {
                self.groups.get_mut(&g).unwrap().insert(a.to_string());
                self.entities.get_mut(a).unwrap().group = Some(g);
                out.events.push(obj(vec![("ev", "join".into()), ("group", group_name(g).into()), ("entity", a.into())]));
            }
            None => {
                let g = self.next_group;
                self.next_group += 1;
                let members: BTreeSet<String> = [a.to_string(), b.clone()].into_iter().collect();
                let list = Json::Arr(members.iter().map(|m| m.as_str().into()).collect());
                self.groups.insert(g, members);
                self.entities.get_mut(a).unwrap().group = Some(g);
                self.entities.get_mut(&b).unwrap().group = Some(g);
                out.events.push(obj(vec![("ev", "correlate".into()), ("group", group_name(g).into()), ("members", list)]));
            }
        }
        self.counts.insert(pair_key(a, &b), 0);
    }

    fn group_has_source(&self, g: u64, source: &str) -> bool {
        self.groups[&g].iter().any(|m| self.entities[m].source == source)
    }

    /// Runs `tests` in order between A and B, writing each to the trace and
    /// stopping at the first failure. True when every test passed.
    fn run_tests(&self, stage: &str, tests: &[Test], a: &str, b: &str, out: &mut StepResult) -> bool {
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
    fn predict_seen_by(&self, a: &str, b: &str) -> (Axis, Axis) {
        let ea = &self.entities[a];
        let eb = &self.entities[b];
        self.move_into_frame(&ea.source, &eb.source, eb.predict_for_comparison(ea.last_time_ms, &self.pack))
    }

    /// `d² = sum over east, north of (pa - pb)² / (pp_b + r_a)`: A's filter,
    /// B as seen by A, and `r_a` A's measurement variance on that axis.
    fn d2(&self, a: &str, b: &str) -> f64 {
        let ea = &self.entities[a];
        let (pe, pn) = self.predict_seen_by(a, b);
        let (r_east, r_north) = ea.r;
        (ea.east.p - pe.p).powi(2) / (pe.pp + r_east) + (ea.north.p - pn.p).powi(2) / (pn.pp + r_north)
    }

    /// Tests: A as filtered, B predicted to A's `time_ms`.
    fn evaluate(&self, test: &Test, a: &str, b: &str) -> Outcome {
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

    /// Entity leaves its group; the group is dissolved if one member is left.
    fn leave(&mut self, key: &str, reason: &str, out: &mut StepResult) {
        let e = self.entities.get_mut(key).unwrap();
        let Some(g) = e.group.take() else { return };
        e.hold_failures = 0;
        let members = self.groups.get_mut(&g).unwrap();
        members.remove(key);
        out.events.push(obj(vec![
            ("ev", "leave".into()),
            ("group", group_name(g).into()),
            ("entity", key.into()),
            ("reason", reason.into()),
        ]));
        if members.len() == 1 {
            let last = members.iter().next().unwrap().clone();
            self.groups.remove(&g);
            let rest = self.entities.get_mut(&last).unwrap();
            rest.group = None;
            rest.hold_failures = 0;
            out.events.push(obj(vec![("ev", "dissolve".into()), ("group", group_name(g).into()), ("entity", last.as_str().into())]));
        }
    }

    // ---- tick (spec: Association "On each tick")

    /// Entities stale at `now_ms`, in key order (spec: On each tick, Staleness).
    fn stale_entities(&self, now_ms: i64) -> Vec<String> {
        let pack_stale = self.pack.stale_ms;
        self.entities
            .iter()
            .filter(|(_, e)| {
                now_ms - e.last_time_ms > pack_stale
                    || e.report.get("stale_ms").and_then(Json::as_i64).is_some_and(|s| now_ms >= s)
            })
            .map(|(k, _)| k.clone())
            .collect()
    }

    pub fn tick(&mut self, now_ms: i64) -> StepResult {
        if self.pack.method == Method::Assign {
            return self.tick_assign(now_ms);
        }
        let mut out = StepResult::default();

        // 1. Staleness, entities in key order.
        let stale = self.stale_entities(now_ms);
        for k in &stale {
            self.leave(k, "stale", &mut out);
            self.entities.remove(k);
            self.counts.retain(|(x, y), _| x != k && y != k);
            out.events.push(obj(vec![("ev", "drop".into()), ("entity", k.as_str().into())]));
        }

        // 2. Fused output, groups in creation order.
        for (g, members) in &self.groups {
            let primary = self.primary(members);
            let e = &self.entities[primary];
            let (pe, pn) = e.predict(now_ms, &self.pack);
            let frame = self.frame.expect("a group implies a reference");
            let (lat, lon) = frame.to_degrees(pe.p, pn.p);
            let (course, speed) = course_speed(&pe, &pn);
            let mut pairs = vec![
                ("ev", Json::from("fused")),
                ("group", group_name(*g).into()),
                ("primary", primary.into()),
                ("members", Json::Arr(members.iter().map(|m| m.as_str().into()).collect())),
                ("lat", lat.into()),
                ("lon", lon.into()),
                ("course", course.into()),
                ("speed_ms", speed.into()),
            ];
            if let Some(hae) = e.num("hae") {
                pairs.push(("hae", hae.into()));
            }
            out.events.push(obj(pairs));
        }
        out
    }

    fn reference_json(&self) -> Json {
        match self.frame {
            Some(f) => Json::Arr(vec![f.lat0.into(), f.lon0.into()]),
            None => Json::Null,
        }
    }

    /// The primary member by the pack's `output` line, ties to key order.
    fn primary<'a>(&self, members: &'a BTreeSet<String>) -> &'a str {
        let mut best: Option<&'a String> = None;
        for m in members {
            let better = match best {
                None => true,
                Some(b) => match self.pack.output {
                    Output::Priority => self.pack.priority_of(&self.entities[m].source) < self.pack.priority_of(&self.entities[b].source),
                    Output::Latest => self.entities[m].last_time_ms > self.entities[b].last_time_ms,
                },
            };
            if better {
                best = Some(m);
            }
        }
        best.expect("a group has members")
    }

    // ---- snapshot (spec: Snapshot)

    pub fn snapshot(&self) -> Json {
        if self.pack.method == Method::Assign {
            return self.snapshot_assign();
        }
        let reference = match self.frame {
            Some(f) => Json::Arr(vec![f.lat0.into(), f.lon0.into()]),
            None => Json::Null,
        };
        let entities = self
            .entities
            .iter()
            .map(|(k, e)| {
                let mut pairs = vec![
                    ("last_time_ms", e.last_time_ms.into()),
                    ("group", e.group.map_or(Json::Null, |g| group_name(g).into())),
                    ("hold_failures", (e.hold_failures as f64).into()),
                ];
                pairs.extend(filter_json(e));
                (k.clone(), obj(pairs))
            })
            .collect();
        let groups = self
            .groups
            .iter()
            .map(|(g, ms)| (group_name(*g), Json::Arr(ms.iter().map(|m| m.as_str().into()).collect())))
            .collect();
        let counts = self.counts.iter().map(|((x, y), n)| (format!("{}|{}", x, y), Json::Num(*n as f64))).collect();
        obj(vec![
            ("ref", reference),
            ("entities", Json::Obj(entities)),
            ("groups", Json::Obj(groups)),
            ("counts", Json::Obj(counts)),
            ("next_group", (self.next_group as f64).into()),
        ])
    }
}

/// `course = deg(atan2(ve, vn))` in [0, 360) and `speed_ms = hypot(ve, vn)`.
fn course_speed(east: &Axis, north: &Axis) -> (f64, f64) {
    let mut course = deg(east.v.atan2(north.v));
    if course < 0.0 {
        course += 360.0;
    }
    if course >= 360.0 {
        course -= 360.0;
    }
    (course, east.v.hypot(north.v))
}

fn axis_json(a: &Axis) -> Json {
    Json::Arr(a.as_list().iter().map(|x| Json::Num(*x)).collect())
}

fn model_json(m: &Model) -> Json {
    obj(vec![("east", axis_json(&m.east)), ("north", axis_json(&m.north))])
}

/// The snapshot's `filter`, plus `models` and `mode` with two models.
fn filter_json(e: &Entity) -> Vec<(&'static str, Json)> {
    let mut pairs = vec![("filter", model_json(&Model { east: e.east, north: e.north }))];
    if let Some(two) = &e.imm {
        pairs.push(("models", obj(vec![("quiet", model_json(&two.models[0])), ("maneuver", model_json(&two.models[1]))])));
        pairs.push(("mode", Json::Arr(vec![two.mu[0].into(), two.mu[1].into()])));
    }
    // `time`, when the last report had a time error above 0.
    if let Some((var_e, var_n)) = e.time_var {
        pairs.push(("time", obj(vec![("var_east", var_e.into()), ("var_north", var_n.into())])));
    }
    pairs
}
