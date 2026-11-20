//! Quality engine, spec/quality.md version 0.2: `ingest`, `tick`, `snapshot`.
//!
//! The plane and the per-axis Kalman filter are the correlate ones
//! (`crate::filter`, spec/correlate.md sections Frame and Track estimate).
//! Each function below names the spec section it implements.

use std::collections::{BTreeMap, BTreeSet};

use crate::model::{rad, Axis, Frame};
use crate::model::{obj, Json};
use crate::model::pack::TimeState;
use crate::model::report::{time_error_ms, time_state};

mod forwarding;
mod measures;
pub mod pack;
mod rules;
mod samples;
mod snapshot;

use measures::{quality_event, source_measures};
use samples::{time_state_code, Ms, Order, Record};

pub use pack::{load_pack, parse_pack, Action, Op, Pack, Rule, Scope, ENTITY_MEASURES, SOURCE_ONLY_MEASURE};

pub use crate::trace::StepResult;

crate::function::function!(Engine, "quality", Pack, parse_pack);

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

        // Input clock and source latest, from the entities that exist just
        // before the report is applied.
        let (clock, source_latest) = self.input_clock(source);

        // Reports, Time quality: each key resolved from the report's own
        // valid value, else the pack's `time_default` for the report's
        // `track.source_id`, else unstated (None).
        let default = self.pack.time_default.get(source);
        let reported_error = time_error_ms(fields);
        let default_error = default.and_then(|d| d.error_ms);
        let reported_state = time_state(fields);
        let default_state = default.and_then(|d| d.state);

        // Samples, in the order interval, latency, lateness, time_error,
        // time_state, source_order, nis, speed_err.
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
        let mut lateness = None;
        if let Some(clock) = clock {
            let value = clock.minus(t);
            lateness = Some(value);
            out.trace.push(sample("lateness", value.to_json(), vec![clock.to_json(), Json::Int(t)]));
        }
        let time_error = reported_error.or(default_error);
        if let Some(value) = time_error {
            out.trace.push(sample("time_error", Json::Num(value), vec![num_or_null(reported_error), num_or_null(default_error)]));
        }
        let time_state = reported_state.or(default_state);
        if let Some(value) = time_state {
            let name = |s: Option<TimeState>| s.map(|s| Json::from(s.name())).unwrap_or(Json::Null);
            out.trace.push(sample("time_state", value.name().into(), vec![name(reported_state), name(default_state)]));
        }
        let source_out_of_order = source_latest.is_some_and(|latest| t < latest);
        let source_order = if source_out_of_order { "out-of-order" } else { "in-order" };
        out.trace.push(sample("source_order", source_order.into(), vec![Json::Int(t), int_or_null(source_latest)]));
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
            lateness,
            time_error,
            time_state,
            source_out_of_order,
            nis,
            speed_err,
            ce: valid_ce.is_some(),
            vel: vel.is_some(),
            hae: hae.is_some(),
        });

        out.events.push(self.forward(&key, source, fields, valid_ce));
        out
    }

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

}

