//! The four operations' engine: ingest, tick, snapshot (spec: Reports,
//! Tests, Association, Events, Trace, Snapshot).

use std::collections::{BTreeMap, BTreeSet};

use crate::filter::{deg, rad, Axis, Frame};
use crate::json::{obj, Json};
use crate::pack::{Method, Output, Pack, Test};

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
    /// `method assign`: the entity's system track.
    system: Option<u64>,
    hold_failures: u64,
    east: Axis,
    north: Axis,
    /// The entity's last accepted report.
    report: BTreeMap<String, Json>,
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

    /// Prediction to time `t` (spec: Track estimate, Prediction).
    fn predict(&self, t: i64, q: f64) -> (Axis, Axis) {
        let dt = (t - self.last_time_ms) as f64 / 1000.0;
        (self.east.predict(dt, q), self.north.predict(dt, q))
    }
}

/// A report's `ce`; absent when not a number or 0 or below (spec: Reports).
fn report_ce(report: &BTreeMap<String, Json>) -> Option<f64> {
    report.get("ce").and_then(Json::as_f64).filter(|c| *c > 0.0)
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
    /// `method assign`: system tracks by number, members in key order.
    systems: BTreeMap<u64, BTreeSet<String>>,
    next_system: u64,
    /// `method assign`: entities with an accepted report since the previous tick.
    reported: BTreeSet<String>,
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
            systems: BTreeMap::new(),
            next_system: 1,
            reported: BTreeSet::new(),
        }
    }

    // ---- ingest (spec: Reports, Track estimate, Association "On each accepted report")

    pub fn ingest(&mut self, report: &Json) -> StepResult {
        let mut out = StepResult::default();
        let empty = BTreeMap::new();
        let fields = report.as_object().unwrap_or(&empty);

        // Reports: required keys, checked in table order.
        let source = fields.get("track.source_id").and_then(Json::as_str);
        let uid = fields.get("uid").and_then(Json::as_str);
        let time_ms = fields.get("time_ms").and_then(Json::as_i64);
        let lat = fields.get("lat").and_then(Json::as_f64);
        let lon = fields.get("lon").and_then(Json::as_f64);
        let missing = [
            ("track.source_id", source.is_none()),
            ("uid", uid.is_none()),
            ("time_ms", time_ms.is_none()),
            ("lat", lat.is_none()),
            ("lon", lon.is_none()),
        ]
        .into_iter()
        .find(|(_, absent)| *absent);
        if let Some((key, _)) = missing {
            out.events.push(obj(vec![("ev", "reject".into()), ("reason", format!("missing:{}", key).into())]));
            return out;
        }
        let (source, uid, time_ms, lat, lon) = (source.unwrap(), uid.unwrap(), time_ms.unwrap(), lat.unwrap(), lon.unwrap());
        let key = format!("{}/{}", source, uid);

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

        match self.entities.get_mut(&key) {
            None => {
                let east = Axis::first(ze, vel.map(|v| v.0), ce, f.vel_sigma_ms, f.unknown_vel_ms);
                let north = Axis::first(zn, vel.map(|v| v.1), ce, f.vel_sigma_ms, f.unknown_vel_ms);
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
                        report: fields.clone(),
                    },
                );
                out.events.push(obj(vec![("ev", "new".into()), ("entity", key.as_str().into())]));
            }
            Some(e) => {
                let dt = (time_ms - e.last_time_ms) as f64 / 1000.0;
                let r_pos = ce * ce;
                let r_vel = f.vel_sigma_ms * f.vel_sigma_ms;
                let mut east = e.east.predict(dt, f.accel_var).update_position(ze, r_pos);
                let mut north = e.north.predict(dt, f.accel_var).update_position(zn, r_pos);
                if let Some((ve, vn)) = vel {
                    east = east.update_velocity(ve, r_vel);
                    north = north.update_velocity(vn, r_vel);
                }
                e.east = east;
                e.north = north;
                e.last_time_ms = time_ms;
                e.report = fields.clone();
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

    /// `d²` between A's filter and B predicted to A's time.
    fn d2(&self, a: &str, b: &str) -> f64 {
        let ea = &self.entities[a];
        let (pe, pn) = self.entities[b].predict(ea.last_time_ms, self.pack.filter.accel_var);
        let r = ea.ce(self.pack.filter.default_ce_m).powi(2);
        (ea.east.p - pe.p).powi(2) / (pe.pp + r) + (ea.north.p - pn.p).powi(2) / (pn.pp + r)
    }

    /// Tests: A as filtered, B predicted to A's `time_ms`.
    fn evaluate(&self, test: &Test, a: &str, b: &str) -> Outcome {
        let ea = &self.entities[a];
        let eb = &self.entities[b];
        let dce = self.pack.filter.default_ce_m;
        let distance = || {
            let (pe, pn) = eb.predict(ea.last_time_ms, self.pack.filter.accel_var);
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
        let q = self.pack.filter.accel_var;
        for (g, members) in &self.groups {
            let primary = self.primary(members);
            let e = &self.entities[primary];
            let (pe, pn) = e.predict(now_ms, q);
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
        let axis = |a: &Axis| Json::Arr(a.as_list().iter().map(|x| Json::Num(*x)).collect());
        let entities = self
            .entities
            .iter()
            .map(|(k, e)| {
                let v = obj(vec![
                    ("last_time_ms", e.last_time_ms.into()),
                    ("group", e.group.map_or(Json::Null, |g| group_name(g).into())),
                    ("hold_failures", (e.hold_failures as f64).into()),
                    ("filter", obj(vec![("east", axis(&e.east)), ("north", axis(&e.north))])),
                ]);
                (k.clone(), v)
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
