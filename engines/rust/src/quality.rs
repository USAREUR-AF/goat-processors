//! Quality engine, spec/quality.md version 0.1: `ingest`, `tick`, `snapshot`.
//!
//! The plane and the per-axis Kalman filter are the correlate ones
//! (`crate::filter`, spec/correlate.md sections Frame and Track estimate).
//! Each function below names the spec section it implements.

use std::collections::{BTreeMap, BTreeSet};

use crate::filter::{rad, Axis, Frame};
use crate::json::{obj, Json};

pub mod pack;

pub use pack::{load_pack, parse_pack, Action, Op, Pack, Rule, Scope, ENTITY_MEASURES, SOURCE_ONLY_MEASURE};

pub use crate::engine::StepResult;

/// Spec Order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Order {
    First,
    Advance,
    Duplicate,
    OutOfOrder,
}

impl Order {
    fn name(self) -> &'static str {
        match self {
            Order::First => "first",
            Order::Advance => "advance",
            Order::Duplicate => "duplicate",
            Order::OutOfOrder => "out-of-order",
        }
    }
}

/// Spec Samples: a report's record, appended to its entity's window.
#[derive(Debug, Clone)]
struct Record {
    wt: i64,
    time_ms: i64,
    order: Order,
    interval: Option<i64>,
    latency: Option<i64>,
    nis: Option<f64>,
    speed_err: Option<f64>,
    ce: bool,
    vel: bool,
    hae: bool,
}

#[derive(Debug, Clone)]
struct Entity {
    source: String,
    /// `last`: the latest accepted `first` or `advance` time.
    last_time_ms: i64,
    /// Spec Frame and filter: plane position of the latest `first` or
    /// `advance` report, as reported.
    last_pos: (f64, f64),
    east: Axis,
    north: Axis,
    /// Spec Window: records in arrival order.
    window: Vec<Record>,
}

/// Spec Rules: per rule, per subject.
#[derive(Debug, Clone, Copy, Default)]
struct RuleState {
    count: u64,
    active: bool,
}

/// A scope's measures, keyed by measure name; `Json::Null` when absent.
type Measures = BTreeMap<&'static str, Json>;

pub struct Engine {
    pack: Pack,
    frame: Option<Frame>,
    last_tick: Option<i64>,
    entities: BTreeMap<String, Entity>,
    /// Rule name → subject → state.
    rules: BTreeMap<String, BTreeMap<String, RuleState>>,
}

fn int_or_null(v: Option<i64>) -> Json {
    v.map(Json::Int).unwrap_or(Json::Null)
}

fn num_or_null(v: Option<f64>) -> Json {
    v.map(Json::Num).unwrap_or(Json::Null)
}

/// Spec Entity measures: a mean is `s / n`, `s` starting at 0.0 and adding
/// each sample in order.
fn mean(values: &[f64]) -> f64 {
    let mut s = 0.0;
    for v in values {
        s += v;
    }
    s / values.len() as f64
}

/// Spec Reports: an optional number; `null`, wrong type (a boolean is never a
/// number) is absent.
fn optional_number(report: &BTreeMap<String, Json>, key: &str) -> Option<f64> {
    report.get(key).and_then(Json::as_f64)
}

impl Engine {
    pub fn new(pack: Pack) -> Engine {
        let rules = pack.rules.iter().map(|r| (r.name.clone(), BTreeMap::new())).collect();
        Engine { pack, frame: None, last_tick: None, entities: BTreeMap::new(), rules }
    }

    // ---- Ingest ------------------------------------------------------------

    /// Spec Ingest: check the required keys; set the reference; find the
    /// order; take the samples; create or update the entity; append the
    /// record; emit `pass`.
    pub fn ingest(&mut self, report: &Json) -> StepResult {
        let mut out = StepResult::default();
        let empty = BTreeMap::new();
        let fields = report.as_object().unwrap_or(&empty);

        // Reports: required keys in table order (as correlate.md, Reports).
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
        let (source, uid, t, lat, lon) = (source.unwrap(), uid.unwrap(), time_ms.unwrap(), lat.unwrap(), lon.unwrap());
        let key = format!("{}/{}", source, uid);

        // Reports: optional keys. A `ce` of 0 or below is absent.
        let f = self.pack.filter.clone();
        let valid_ce = optional_number(fields, "ce").filter(|c| *c > 0.0);
        let ce = valid_ce.unwrap_or(f.default_ce_m);
        let course = optional_number(fields, "course");
        let speed_ms = optional_number(fields, "speed_ms");
        let hae = optional_number(fields, "hae");
        let received_ms = fields.get("received_ms").and_then(Json::as_i64);
        // correlate.md, Track estimate: the velocity measurement.
        let vel = match (course, speed_ms) {
            (Some(c), Some(s)) => Some((s * rad(c).sin(), s * rad(c).cos())),
            _ => None,
        };

        // Frame and filter: the reference is the first accepted report.
        let frame = *self.frame.get_or_insert(Frame { lat0: lat, lon0: lon });
        let (e, n) = frame.to_plane(lat, lon);

        // Order.
        let last = self.entities.get(&key).map(|en| en.last_time_ms);
        let order = match last {
            None => Order::First,
            Some(last) if t > last => Order::Advance,
            Some(last) if t == last => Order::Duplicate,
            Some(_) => Order::OutOfOrder,
        };
        let wt = match order {
            Order::First | Order::Advance => t,
            Order::Duplicate | Order::OutOfOrder => last.unwrap(),
        };
        let sample = |name: &str, value: Json, inputs: Vec<Json>| {
            obj(vec![
                ("stage", "sample".into()),
                ("entity", key.as_str().into()),
                ("sample", name.into()),
                ("value", value),
                ("inputs", Json::Arr(inputs)),
            ])
        };
        out.trace.push(sample("order", order.name().into(), vec![Json::Int(t), int_or_null(last)]));

        // Samples, in the order interval, latency, nis, speed_err.
        let mut interval = None;
        if order == Order::Advance {
            let last = last.unwrap();
            interval = Some(t - last);
            out.trace.push(sample("interval", Json::Int(t - last), vec![Json::Int(t), Json::Int(last)]));
        }
        let mut latency = None;
        if let Some(rcv) = received_ms {
            latency = Some(rcv - t);
            out.trace.push(sample("latency", Json::Int(rcv - t), vec![Json::Int(rcv), Json::Int(t)]));
        }
        let mut nis = None;
        let mut speed_err = None;
        let mut predicted = None;
        if order == Order::Advance {
            let entity = &self.entities[&key];
            let dt = (t - entity.last_time_ms) as f64 / 1000.0;
            let pe = entity.east.predict(dt, f.accel_var);
            let pn = entity.north.predict(dt, f.accel_var);
            let r = ce * ce;
            let de = e - pe.p;
            let dn = n - pn.p;
            let se = pe.pp + r;
            let sn = pn.pp + r;
            let value = de * de / se + dn * dn / sn;
            nis = Some(value);
            out.trace.push(sample("nis", Json::Num(value), vec![Json::Num(de), Json::Num(dn), Json::Num(se), Json::Num(sn)]));
            predicted = Some((pe, pn));

            if let Some(speed) = speed_ms {
                let (lpe, lpn) = entity.last_pos;
                let implied = (e - lpe).hypot(n - lpn) / dt;
                let value = (implied - speed).abs();
                speed_err = Some(value);
                out.trace.push(sample("speed_err", Json::Num(value), vec![Json::Num(implied), Json::Num(speed)]));
            }
        }

        // Create the entity (event `new`) or update its filter, `last` and
        // `last_pos` as the order says (correlate.md, Track estimate).
        match order {
            Order::First => {
                let east = Axis::first(e, vel.map(|v| v.0), ce, f.vel_sigma_ms, f.unknown_vel_ms);
                let north = Axis::first(n, vel.map(|v| v.1), ce, f.vel_sigma_ms, f.unknown_vel_ms);
                self.entities.insert(
                    key.clone(),
                    Entity { source: source.to_string(), last_time_ms: t, last_pos: (e, n), east, north, window: Vec::new() },
                );
                out.events.push(obj(vec![("ev", "new".into()), ("entity", key.as_str().into())]));
            }
            Order::Advance => {
                let (pe, pn) = predicted.unwrap();
                let r_pos = ce * ce;
                let r_vel = f.vel_sigma_ms * f.vel_sigma_ms;
                let mut east = pe.update_position(e, r_pos).0;
                let mut north = pn.update_position(n, r_pos).0;
                if let Some((ve, vn)) = vel {
                    east = east.update_velocity(ve, r_vel).0;
                    north = north.update_velocity(vn, r_vel).0;
                }
                let entity = self.entities.get_mut(&key).unwrap();
                entity.east = east;
                entity.north = north;
                entity.last_time_ms = t;
                entity.last_pos = (e, n);
            }
            Order::Duplicate | Order::OutOfOrder => {}
        }

        let entity = self.entities.get_mut(&key).unwrap();
        entity.window.push(Record {
            wt,
            time_ms: t,
            order,
            interval,
            latency,
            nis,
            speed_err,
            ce: valid_ce.is_some(),
            vel: vel.is_some(),
            hae: hae.is_some(),
        });

        out.events.push(self.forward(&key, fields, valid_ce));
        out
    }

    /// Spec Rules, Actions: is `rule` active for its subject of this entity?
    fn in_force(&self, rule: &Rule, key: &str) -> bool {
        let subject = match rule.scope {
            Scope::Entity => key,
            Scope::Source => self.entities[key].source.as_str(),
        };
        self.rules[&rule.name].get(subject).is_some_and(|s| s.active)
    }

    /// Spec Forwarding: the `pass` event.
    fn forward(&self, key: &str, fields: &BTreeMap<String, Json>, valid_ce: Option<f64>) -> Json {
        let actions: Vec<&Rule> =
            self.pack.rules.iter().filter(|r| r.action != Action::Alert && self.in_force(r, key)).collect();
        let names = Json::Arr(actions.iter().map(|r| r.name.as_str().into()).collect());
        let mut pass = vec![("ev", "pass".into()), ("entity", key.into()), ("rules", names)];

        if actions.iter().any(|r| r.action == Action::Drop) {
            pass.push(("withheld", true.into()));
            return obj(pass);
        }

        let mut report = fields.clone();
        let downgrades: Vec<f64> =
            actions.iter().filter_map(|r| if let Action::Downgrade(f) = r.action { Some(f) } else { None }).collect();
        if !downgrades.is_empty() {
            let mut x = valid_ce.unwrap_or(self.pack.filter.default_ce_m);
            for factor in downgrades {
                x *= factor;
            }
            report.insert("ce".into(), Json::Num(x));
        }
        let marks: Vec<&str> = actions.iter().filter(|r| r.action == Action::Mark).map(|r| r.name.as_str()).collect();
        if !marks.is_empty() {
            let mut list: Vec<Json> = match fields.get("quality.marks") {
                Some(Json::Arr(items)) if items.iter().all(|i| matches!(i, Json::Str(_))) => items.clone(),
                _ => Vec::new(),
            };
            for name in marks {
                if !list.iter().any(|m| m.as_str() == Some(name)) {
                    list.push(name.into());
                }
            }
            report.insert("quality.marks".into(), Json::Arr(list));
        }
        pass.push(("withheld", false.into()));
        pass.push(("report", Json::Obj(report)));
        obj(pass)
    }

    // ---- Tick --------------------------------------------------------------

    /// Spec Tick, steps 1 to 6.
    pub fn tick(&mut self, now_ms: i64) -> StepResult {
        let mut out = StepResult::default();

        // 1. Order.
        if self.last_tick.is_some_and(|last| now_ms < last) {
            out.events.push(obj(vec![("ev", "reject".into()), ("reason", "tick-out-of-order".into())]));
            return out;
        }
        self.last_tick = Some(now_ms);

        // 2. Forget entities, key order.
        let sources_at_start: BTreeSet<String> = self.entities.values().map(|e| e.source.clone()).collect();
        let forget_ms = self.pack.window.forget_ms;
        let forgotten: Vec<String> =
            self.entities.iter().filter(|(_, e)| now_ms - e.last_time_ms > forget_ms).map(|(k, _)| k.clone()).collect();
        for key in forgotten {
            self.forget_subject(Scope::Entity, &key, &mut out);
            self.entities.remove(&key);
            out.events.push(obj(vec![("ev", "forget".into()), ("entity", key.as_str().into())]));
        }

        // 3. Forget sources that had entities at the start and have none now.
        let sources_now: BTreeSet<String> = self.entities.values().map(|e| e.source.clone()).collect();
        for source in sources_at_start.difference(&sources_now) {
            self.forget_subject(Scope::Source, source, &mut out);
            out.events.push(obj(vec![("ev", "forget".into()), ("source", source.as_str().into())]));
        }

        // 4. Window: drop records with `wt <= now_ms - window_ms`.
        let cutoff = now_ms - self.pack.window.window_ms;
        for entity in self.entities.values_mut() {
            entity.window.retain(|r| r.wt > cutoff);
        }

        // 5. Entities, key order.
        let mut entity_measures: BTreeMap<String, Measures> = BTreeMap::new();
        let keys: Vec<String> = self.entities.keys().cloned().collect();
        for key in &keys {
            let m = self.entity_measures(&self.entities[key], now_ms);
            out.events.push(quality_event(Scope::Entity, key, &m));
            self.evaluate_rules(Scope::Entity, key, &m, &mut out);
            entity_measures.insert(key.clone(), m);
        }

        // 6. Sources, key order.
        for source in &sources_now {
            let members: Vec<&Measures> = keys
                .iter()
                .filter(|k| self.entities[*k].source == *source)
                .map(|k| &entity_measures[k])
                .collect();
            let m = source_measures(&members);
            out.events.push(quality_event(Scope::Source, source, &m));
            self.evaluate_rules(Scope::Source, source, &m, &mut out);
        }
        out
    }

    /// Spec Tick, steps 2 and 3: each active rule of the scope for the
    /// subject ends (reason `forget`, value null), in pack order; every rule
    /// state for the subject is removed.
    fn forget_subject(&mut self, scope: Scope, subject: &str, out: &mut StepResult) {
        for rule in self.pack.rules.iter().filter(|r| r.scope == scope) {
            let states = self.rules.get_mut(&rule.name).unwrap();
            if let Some(state) = states.remove(subject) {
                if state.active {
                    out.events.push(action_event("action-end", rule, subject, Json::Null, Some("forget")));
                }
            }
        }
    }

    /// Spec Entity measures, over the entity's window `W`.
    fn entity_measures(&self, entity: &Entity, now_ms: i64) -> Measures {
        let w = &entity.window;
        let k = self.pack.window.min_samples;
        let reports = w.len() as i64;
        // A statistic: null when fewer than `k` records hold the sample.
        let enough = |n: usize| n as i64 >= k;
        let ints = |pick: fn(&Record) -> Option<i64>| -> Option<Vec<i64>> {
            let v: Vec<i64> = w.iter().filter_map(pick).collect();
            if enough(v.len()) {
                Some(v)
            } else {
                None
            }
        };
        let floats = |pick: fn(&Record) -> Option<f64>| -> Option<Vec<f64>> {
            let v: Vec<f64> = w.iter().filter_map(pick).collect();
            if enough(v.len()) {
                Some(v)
            } else {
                None
            }
        };
        let as_f64 = |v: &Vec<i64>| v.iter().map(|x| *x as f64).collect::<Vec<f64>>();
        let fraction = |flag: fn(&Record) -> bool| -> Option<f64> {
            if reports < k {
                return None;
            }
            let without = w.iter().filter(|r| !flag(r)).count();
            Some(without as f64 / reports as f64)
        };
        let count_order = |o: Order| w.iter().filter(|r| r.order == o).count() as i64;

        let intervals = ints(|r| r.interval);
        let latencies = ints(|r| r.latency);
        let nis = floats(|r| r.nis);
        let speed_err = floats(|r| r.speed_err);

        let mut m = Measures::new();
        m.insert("reports", Json::Int(reports));
        m.insert("interval_last", int_or_null(intervals.as_ref().and_then(|v| v.last().copied())));
        m.insert("interval_mean", num_or_null(intervals.as_ref().map(|v| mean(&as_f64(v)))));
        m.insert("interval_max", int_or_null(intervals.as_ref().and_then(|v| v.iter().max().copied())));
        m.insert("age", Json::Int(now_ms - entity.last_time_ms));
        m.insert("latency_mean", num_or_null(latencies.as_ref().map(|v| mean(&as_f64(v)))));
        m.insert("latency_max", int_or_null(latencies.as_ref().and_then(|v| v.iter().max().copied())));
        m.insert("nis_mean", num_or_null(nis.as_ref().map(|v| mean(v))));
        m.insert("speed_err_mean", num_or_null(speed_err.as_ref().map(|v| mean(v))));
        m.insert("out_of_order", Json::Int(count_order(Order::OutOfOrder)));
        m.insert("duplicate", Json::Int(count_order(Order::Duplicate)));
        m.insert("missing_ce", num_or_null(fraction(|r| r.ce)));
        m.insert("missing_vel", num_or_null(fraction(|r| r.vel)));
        m.insert("missing_hae", num_or_null(fraction(|r| r.hae)));
        m
    }

    /// Spec Rules, Evaluation: each rule of the scope, in pack order, for one
    /// subject; events `action-start`/`action-end` and one trace record each.
    fn evaluate_rules(&mut self, scope: Scope, subject: &str, measures: &Measures, out: &mut StepResult) {
        for rule in self.pack.rules.iter().filter(|r| r.scope == scope) {
            let v = &measures[rule.measure.as_str()];
            let value = v.as_f64();
            let state = self.rules.get_mut(&rule.name).unwrap().entry(subject.to_string()).or_default();
            let (limit, pass) = if !state.active {
                let met = value.is_some_and(|x| rule.op.holds(x, rule.limit));
                state.count = if met { state.count + 1 } else { 0 };
                if state.count >= rule.for_n {
                    state.active = true;
                    state.count = 0;
                    out.events.push(action_event("action-start", rule, subject, v.clone(), None));
                }
                (rule.limit, met)
            } else {
                let cleared = value.is_some_and(|x| rule.op.clears(x, rule.clear));
                if cleared {
                    state.active = false;
                    out.events.push(action_event("action-end", rule, subject, v.clone(), Some("clear")));
                }
                (rule.clear, cleared)
            };
            out.trace.push(obj(vec![
                ("stage", "rule".into()),
                ("rule", rule.name.as_str().into()),
                ("subject", subject.into()),
                ("measure", rule.measure.as_str().into()),
                ("value", v.clone()),
                ("limit", Json::Num(limit)),
                ("pass", pass.into()),
                ("count", Json::Int(state.count as i64)),
                ("active", state.active.into()),
            ]));
        }
    }

    // ---- Snapshot ----------------------------------------------------------

    /// Spec Snapshot.
    pub fn snapshot(&self) -> Json {
        let reference = match self.frame {
            Some(fr) => Json::Arr(vec![Json::Num(fr.lat0), Json::Num(fr.lon0)]),
            None => Json::Null,
        };
        let axis = |a: &Axis| Json::Arr(a.as_list().iter().map(|x| Json::Num(*x)).collect());
        let entities = self
            .entities
            .iter()
            .map(|(k, e)| {
                let window = e
                    .window
                    .iter()
                    .map(|r| {
                        obj(vec![
                            ("wt", Json::Int(r.wt)),
                            ("time_ms", Json::Int(r.time_ms)),
                            ("order", r.order.name().into()),
                            ("interval", int_or_null(r.interval)),
                            ("latency", int_or_null(r.latency)),
                            ("nis", num_or_null(r.nis)),
                            ("speed_err", num_or_null(r.speed_err)),
                            ("ce", r.ce.into()),
                            ("vel", r.vel.into()),
                            ("hae", r.hae.into()),
                        ])
                    })
                    .collect();
                let value = obj(vec![
                    ("source", e.source.as_str().into()),
                    ("last_time_ms", Json::Int(e.last_time_ms)),
                    ("last_pos", Json::Arr(vec![Json::Num(e.last_pos.0), Json::Num(e.last_pos.1)])),
                    ("filter", obj(vec![("east", axis(&e.east)), ("north", axis(&e.north))])),
                    ("window", Json::Arr(window)),
                ]);
                (k.clone(), value)
            })
            .collect();
        let rules = self
            .rules
            .iter()
            .map(|(name, states)| {
                let states = states
                    .iter()
                    .map(|(s, st)| (s.clone(), obj(vec![("count", Json::Int(st.count as i64)), ("active", st.active.into())])))
                    .collect();
                (name.clone(), Json::Obj(states))
            })
            .collect();
        obj(vec![
            ("ref", reference),
            ("last_tick", int_or_null(self.last_tick)),
            ("entities", Json::Obj(entities)),
            ("rules", Json::Obj(rules)),
        ])
    }
}

/// Spec Source measures: aggregates of the source's entities' measures,
/// taken in entity key order.
fn source_measures(members: &[&Measures]) -> Measures {
    let present = |name: &str| -> Vec<&Json> { members.iter().map(|m| &m[name]).filter(|v| **v != Json::Null).collect() };
    let ints = |name: &str| -> Vec<i64> { present(name).into_iter().filter_map(Json::as_i64).collect() };
    let sum = |name: &str| Json::Int(ints(name).iter().sum());
    let mean_of = |name: &str| {
        let values: Vec<f64> = present(name).into_iter().filter_map(Json::as_f64).collect();
        if values.is_empty() {
            Json::Null
        } else {
            Json::Num(mean(&values))
        }
    };
    let largest = |name: &str| int_or_null(ints(name).into_iter().max());

    let mut m = Measures::new();
    for name in ENTITY_MEASURES {
        let value = match name {
            "reports" | "out_of_order" | "duplicate" => sum(name),
            "interval_max" | "latency_max" => largest(name),
            "age" => int_or_null(ints(name).into_iter().min()),
            _ => mean_of(name),
        };
        m.insert(name, value);
    }
    m.insert(SOURCE_ONLY_MEASURE, Json::Int(members.len() as i64));
    m
}

/// Spec Events: `quality`.
fn quality_event(scope: Scope, subject: &str, measures: &Measures) -> Json {
    let measures = measures.iter().map(|(k, v)| (k.to_string(), v.clone())).collect();
    obj(vec![
        ("ev", "quality".into()),
        ("scope", scope.name().into()),
        ("subject", subject.into()),
        ("measures", Json::Obj(measures)),
    ])
}

/// Spec Events: `action-start`, or `action-end` with its reason.
fn action_event(ev: &str, rule: &Rule, subject: &str, value: Json, reason: Option<&str>) -> Json {
    let mut fields = vec![
        ("ev", ev.into()),
        ("rule", rule.name.as_str().into()),
        ("scope", rule.scope.name().into()),
        ("subject", subject.into()),
        ("action", rule.action.name().into()),
        ("value", value),
    ];
    if let Some(reason) = reason {
        fields.push(("reason", reason.into()));
    }
    obj(fields)
}
