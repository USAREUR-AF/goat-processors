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

use crate::json::{obj, Json};
use crate::report::{self, Required};
use crate::StepResult;

pub mod geometry;
pub mod pack;

pub use pack::{load_pack, parse_pack, Action, Condition, Pack, Range};

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

/// The report being decided: its required keys and all its fields.
struct Report<'a> {
    required: Required<'a>,
    fields: &'a BTreeMap<String, Json>,
}

impl Report<'_> {
    /// A key's value when present (spec: Conditions, "Absent and present").
    fn get(&self, name: &str) -> Option<&Json> {
        report::optional(self.fields, name)
    }

    /// `type` split on `-`, when present.
    fn type_elements(&self) -> Option<Vec<&str>> {
        self.get("type").and_then(Json::as_str).map(|t| t.split('-').collect())
    }

    /// Environment: the third element of `type`; absent with fewer than three.
    fn environment(&self) -> Option<&str> {
        self.type_elements()?.get(2).copied()
    }

    /// Affiliation: the second element of `type` when the first is exactly `a`.
    fn affiliation(&self) -> Option<&str> {
        match self.type_elements()?[..] {
            ["a", second, ..] => Some(second),
            _ => None,
        }
    }
}

/// A condition's result before negation (spec: Conditions).
#[derive(Debug, Clone, Copy, PartialEq)]
enum Truth {
    True,
    False,
    Unknown,
}

impl Truth {
    fn of(b: bool) -> Truth {
        if b {
            Truth::True
        } else {
            Truth::False
        }
    }

    /// `not`: true and false swap; unknown stays unknown.
    fn negate(self) -> Truth {
        match self {
            Truth::True => Truth::False,
            Truth::False => Truth::True,
            Truth::Unknown => Truth::Unknown,
        }
    }
}

/// One evaluated condition: its trace `value`, `limit` and result.
struct Outcome {
    value: Json,
    limit: Json,
    truth: Truth,
}

/// An `in` list as the trace `limit`: the items in pack order.
fn list_json(items: &[String]) -> Json {
    Json::Arr(items.iter().map(|s| Json::from(s.as_str())).collect())
}

/// A range as the trace `limit`: `[min, max]`, null for an omitted bound.
fn range_json(r: &Range) -> Json {
    let bound = |b: Option<f64>| b.map(Json::from).unwrap_or(Json::Null);
    Json::Arr(vec![bound(r.min), bound(r.max)])
}

fn opt_int(v: Option<i64>) -> Json {
    v.map(Json::from).unwrap_or(Json::Null)
}

fn opt_num(v: Option<f64>) -> Json {
    v.map(Json::from).unwrap_or(Json::Null)
}

/// An optional string as a trace `value`.
fn opt_str(v: Option<&str>) -> Json {
    v.map(Json::from).unwrap_or(Json::Null)
}

/// `in` list membership, byte for byte; unknown when the value is absent.
fn in_list(value: Option<&str>, items: &[String]) -> Outcome {
    let truth = match value {
        None => Truth::Unknown,
        Some(v) => Truth::of(items.iter().any(|i| i == v)),
    };
    Outcome { value: opt_str(value), limit: list_json(items), truth }
}

/// A range on an optional report value: unknown when absent or not a number
/// (`true` and `false` are not numbers).
fn in_range(value: Option<&Json>, range: &Range) -> Outcome {
    let truth = match value.and_then(Json::as_f64) {
        None => Truth::Unknown,
        Some(v) => Truth::of(range.holds(v)),
    };
    Outcome { value: value.cloned().unwrap_or(Json::Null), limit: range_json(range), truth }
}

/// `key` equality between a report value `v` and a pack text `t`
/// (`number` is `t` read as a pack number, when it is one).
fn key_equals(v: &Json, t: &str, number: Option<f64>) -> bool {
    match v {
        Json::Str(s) => s == t,
        Json::Int(_) | Json::Num(_) => number.is_some_and(|n| v.as_f64() == Some(n)),
        Json::Bool(true) => t == "true",
        Json::Bool(false) => t == "false",
        Json::Arr(_) | Json::Obj(_) | Json::Null => false,
    }
}

/// `a - b` as a trace number: an integer when it fits in 64 bits.
fn difference(a: i64, b: i64) -> (i128, Json) {
    let d = a as i128 - b as i128;
    let json = i64::try_from(d).map(Json::Int).unwrap_or(Json::Num(d as f64));
    (d, json)
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

    /// One condition against the report and the state before it (spec: Conditions).
    fn evaluate(&self, c: &Condition, r: &Report, key: &str) -> Outcome {
        let (time_ms, lat, lon) = (r.required.time_ms, r.required.lat, r.required.lon);
        let kept_ms = self.entities.get(key).and_then(|e| e.kept_ms);
        match c {
            Condition::Circle { lat: clat, lon: clon, radius_m } => {
                let d = geometry::distance(lat, lon, *clat, *clon);
                Outcome { value: d.into(), limit: (*radius_m).into(), truth: Truth::of(d <= *radius_m) }
            }
            Condition::Polygon { vertices } => {
                let place = geometry::polygon(vertices, lat, lon);
                Outcome {
                    value: place.name().into(),
                    limit: Json::Null,
                    truth: Truth::of(place != geometry::Place::Outside),
                }
            }
            Condition::Near { reference, radius_m, max_age_ms } => {
                let unknown = Outcome { value: Json::Null, limit: (*radius_m).into(), truth: Truth::Unknown };
                // The reference's state before this report.
                let Some(refe) = self.entities.get(reference) else { return unknown };
                let (age, _) = difference(time_ms, refe.time_ms);
                let stale = age.abs() > *max_age_ms as i128 || refe.stale_ms.is_some_and(|s| time_ms >= s);
                if stale {
                    return unknown;
                }
                let (plat, plon) = geometry::predict(refe.time_ms, refe.lat, refe.lon, refe.course, refe.speed_ms, time_ms);
                let d = geometry::distance(lat, lon, plat, plon);
                Outcome { value: d.into(), limit: (*radius_m).into(), truth: Truth::of(d <= *radius_m) }
            }
            Condition::Env { items } => in_list(r.environment(), items),
            Condition::Affiliation { items } => in_list(r.affiliation(), items),
            Condition::Source { items } => in_list(Some(r.required.source), items),
            Condition::Uid { items } => in_list(Some(r.required.uid), items),
            Condition::KeyEq { name, text, number } => {
                let v = r.get(name);
                let truth = match v {
                    None => Truth::Unknown,
                    Some(v) => Truth::of(key_equals(v, text, *number)),
                };
                Outcome { value: v.cloned().unwrap_or(Json::Null), limit: text.as_str().into(), truth }
            }
            Condition::KeyIn { name, items } => {
                let v = r.get(name);
                let truth = match v {
                    None => Truth::Unknown,
                    Some(v) => Truth::of(items.iter().any(|t| key_equals(v, t, pack::number(t).ok()))),
                };
                Outcome { value: v.cloned().unwrap_or(Json::Null), limit: list_json(items), truth }
            }
            Condition::KeyRange { name, range } => in_range(r.get(name), range),
            Condition::Has { name } => {
                let present = r.get(name).is_some();
                Outcome { value: present.into(), limit: Json::Null, truth: Truth::of(present) }
            }
            Condition::Speed { range } => in_range(r.get("speed_ms"), range),
            Condition::Altitude { range } => in_range(r.get("hae"), range),
            Condition::Interval { min_ms } => {
                // time_ms - kept_ms; null (and false) with no kept report.
                let (value, truth) = match kept_ms {
                    None => (Json::Null, Truth::False),
                    Some(k) => {
                        let (d, json) = difference(time_ms, k);
                        (json, Truth::of(d < *min_ms as i128))
                    }
                };
                Outcome { value, limit: (*min_ms).into(), truth }
            }
            Condition::Order => Outcome {
                value: time_ms.into(),
                limit: opt_int(kept_ms),
                truth: Truth::of(kept_ms.is_some_and(|k| time_ms < k)),
            },
        }
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
