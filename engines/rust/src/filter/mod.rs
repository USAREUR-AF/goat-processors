//! The filter function (spec/filter.md, version 0.1): for each report, keep
//! or drop, by the first rule whose conditions all pass, else the default.
//!
//! | File | Spec section |
//! |---|---|
//! | `pack.rs` | Pack |
//! | `geometry.rs` | Geometry |
//! | this file | Reports, Conditions, Rules, Tick, Events, Trace, Snapshot |
//!
//! The required keys, the reject event and the optional-key rules are the
//! correlate engine's own (`crate::report`, correlate.md Reports).

use std::collections::BTreeMap;

use crate::model::{obj, Json};
use crate::model::report::{self, Required};
use crate::trace::StepResult;

mod conditions;
pub mod geometry;

use conditions::{difference, Report, Truth};
pub mod pack;

pub use pack::{load_pack, parse_pack, Action, Condition, Pack, Range};

crate::function::function!(Engine, "filter", Pack, parse_pack);

/// An entity's stored state (spec: Snapshot).
#[derive(Debug, Clone, PartialEq)]
struct Entity {
    time_ms: i64,
    lat: f64,
    lon: f64,
    course: Option<f64>,
    speed_ms: Option<f64>,
    stale_ms: Option<i64>,
    kept_ms: Option<i64>,
}

impl Entity {
    /// Position and motion keys taken from an accepted report; `kept_ms` null.
    fn from_report(r: &Required, fields: &BTreeMap<String, Json>) -> Entity {
        Entity {
            time_ms: r.time_ms,
            lat: r.lat,
            lon: r.lon,
            course: report::optional_f64(fields, "course"),
            speed_ms: report::optional_f64(fields, "speed_ms"),
            stale_ms: report::optional(fields, "stale_ms").and_then(Json::as_i64),
            kept_ms: None,
        }
    }
}

fn opt_int(v: Option<i64>) -> Json {
    v.map(Json::from).unwrap_or(Json::Null)
}

fn opt_num(v: Option<f64>) -> Json {
    v.map(Json::from).unwrap_or(Json::Null)
}

pub struct Engine {
    pack: Pack,
    entities: BTreeMap<String, Entity>,
}

impl Engine {
    pub fn new(pack: Pack) -> Engine {
        Engine { pack, entities: BTreeMap::new() }
    }

    // ---- ingest (spec: Reports, Rules)

    pub fn ingest(&mut self, input: &Json) -> StepResult {
        let mut out = StepResult::default();
        let empty = BTreeMap::new();
        let fields = input.as_object().unwrap_or(&empty);

        // Reports: a missing required key rejects, with no trace and no state change.
        let required = match report::required(fields) {
            Ok(r) => r,
            Err(missing) => {
                out.events.push(report::reject_missing(missing));
                return out;
            }
        };
        let key = required.key();
        let r = Report { required, fields };

        // Rules 1-2: rules in pack order, conditions in pack order; the first
        // condition that does not pass ends the rule; the first rule that
        // matches decides, else `default`.
        let mut decision = (self.pack.default, "default".to_string());
        for rule in &self.pack.rules {
            let mut matched = true;
            for when in &rule.conditions {
                let o = self.evaluate(&when.condition, &r, &key);
                let truth = if when.negated { o.truth.negate() } else { o.truth };
                let pass = truth == Truth::True;
                let mut rec = vec![
                    ("stage", Json::from("rule")),
                    ("rule", rule.name.as_str().into()),
                    ("entity", key.as_str().into()),
                    ("test", when.condition.name().into()),
                    ("negated", when.negated.into()),
                    ("value", o.value),
                    ("limit", o.limit),
                    ("pass", pass.into()),
                ];
                if truth == Truth::Unknown {
                    rec.push(("unknown", true.into()));
                }
                out.trace.push(obj(rec));
                if !pass {
                    matched = false;
                    break;
                }
            }
            if matched {
                decision = (rule.action, rule.name.clone());
                break;
            }
        }
        let (action, rule_name) = decision;

        // Rules 3: one event.
        out.events.push(obj(vec![
            ("ev", action.name().into()),
            ("entity", key.as_str().into()),
            ("rule", rule_name.into()),
        ]));

        // Rules 4: state, after the decision.
        let time_ms = required.time_ms;
        let fresh = Entity::from_report(&required, fields);
        match self.entities.get_mut(&key) {
            // An entity with no state gets state from this report, kept_ms null.
            None => {
                self.entities.insert(key.clone(), fresh);
            }
            // Same time or newer: the position and motion keys are replaced.
            Some(e) if time_ms >= e.time_ms => *e = Entity { kept_ms: e.kept_ms, ..fresh },
            // An older report replaces none of them.
            Some(_) => {}
        }
        let entity = self.entities.get_mut(&key).expect("state was just set");
        if action == Action::Keep && entity.kept_ms.is_none_or(|k| k < time_ms) {
            entity.kept_ms = Some(time_ms);
        }
        out
    }

    // ---- tick (spec: Tick)

    pub fn tick(&mut self, now_ms: i64) -> StepResult {
        let mut out = StepResult::default();
        let forget_ms = self.pack.forget_ms;
        let mut forgotten = Vec::new();
        for (key, e) in &self.entities {
            let (age, value) = difference(now_ms, e.time_ms);
            let pass = age > forget_ms as i128;
            out.trace.push(obj(vec![
                ("stage", "forget".into()),
                ("entity", key.as_str().into()),
                ("test", "age".into()),
                ("value", value),
                ("limit", forget_ms.into()),
                ("pass", pass.into()),
            ]));
            if pass {
                forgotten.push(key.clone());
            }
        }
        for key in forgotten {
            self.entities.remove(&key);
            out.events.push(obj(vec![("ev", "forget".into()), ("entity", key.into())]));
        }
        out
    }

    // ---- snapshot (spec: Snapshot)

    pub fn snapshot(&self) -> Json {
        let entities = self
            .entities
            .iter()
            .map(|(k, e)| {
                let state = obj(vec![
                    ("time_ms", e.time_ms.into()),
                    ("lat", e.lat.into()),
                    ("lon", e.lon.into()),
                    ("course", opt_num(e.course)),
                    ("speed_ms", opt_num(e.speed_ms)),
                    ("stale_ms", opt_int(e.stale_ms)),
                    ("kept_ms", opt_int(e.kept_ms)),
                ]);
                (k.clone(), state)
            })
            .collect();
        obj(vec![("entities", Json::Obj(entities))])
    }
}
