//! filter.md Conditions: the report as conditions read it, the three-valued
//! result, and each condition against the report and the state before it.

use super::*;

/// The report being decided: its required keys and all its fields.
pub(super) struct Report<'a> {
    pub(super) required: Required<'a>,
    pub(super) fields: &'a crate::model::json::Map,
}

impl Report<'_> {
    /// A key's value when present (spec: Conditions, "Absent and present").
    pub(super) fn get(&self, name: &str) -> Option<&Json> {
        report::optional(self.fields, name)
    }

    /// `type` split on `-`, when present.
    pub(super) fn type_elements(&self) -> Option<Vec<&str>> {
        self.get("type").and_then(Json::as_str).map(|t| t.split('-').collect())
    }

    /// Environment: the third element of `type`; absent with fewer than three.
    pub(super) fn environment(&self) -> Option<&str> {
        self.type_elements()?.get(2).copied()
    }

    /// Affiliation: the second element of `type` when the first is exactly `a`.
    pub(super) fn affiliation(&self) -> Option<&str> {
        match self.type_elements()?[..] {
            ["a", second, ..] => Some(second),
            _ => None,
        }
    }
}

/// A condition's result before negation (spec: Conditions).
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) enum Truth {
    True,
    False,
    Unknown,
}

impl Truth {
    pub(super) fn of(b: bool) -> Truth {
        if b {
            Truth::True
        } else {
            Truth::False
        }
    }

    /// `not`: true and false swap; unknown stays unknown.
    pub(super) fn negate(self) -> Truth {
        match self {
            Truth::True => Truth::False,
            Truth::False => Truth::True,
            Truth::Unknown => Truth::Unknown,
        }
    }
}

/// One evaluated condition: its trace `value`, `limit` and result.
pub(super) struct Outcome {
    pub(super) value: Json,
    pub(super) limit: Json,
    pub(super) truth: Truth,
}

/// An `in` list as the trace `limit`: the items in pack order.
pub(super) fn list_json(items: &[String]) -> Json {
    Json::Arr(items.iter().map(|s| Json::from(s.as_str())).collect())
}

/// A range as the trace `limit`: `[min, max]`, null for an omitted bound.
pub(super) fn range_json(r: &Range) -> Json {
    let bound = |b: Option<f64>| b.map(Json::from).unwrap_or(Json::Null);
    Json::Arr(vec![bound(r.min), bound(r.max)])
}

/// An optional string as a trace `value`.
pub(super) fn opt_str(v: Option<&str>) -> Json {
    v.map(Json::from).unwrap_or(Json::Null)
}

/// `in` list membership, byte for byte; unknown when the value is absent.
pub(super) fn in_list(value: Option<&str>, items: &[String]) -> Outcome {
    let truth = match value {
        None => Truth::Unknown,
        Some(v) => Truth::of(items.iter().any(|i| i == v)),
    };
    Outcome { value: opt_str(value), limit: list_json(items), truth }
}

/// A range on an optional report value: unknown when absent or not a number
/// (`true` and `false` are not numbers).
pub(super) fn in_range(value: Option<&Json>, range: &Range) -> Outcome {
    let truth = match value.and_then(Json::as_f64) {
        None => Truth::Unknown,
        Some(v) => Truth::of(range.holds(v)),
    };
    Outcome { value: value.cloned().unwrap_or(Json::Null), limit: range_json(range), truth }
}

/// `key` equality between a report value `v` and a pack text `t`
/// (`number` is `t` read as a pack number, when it is one).
pub(super) fn key_equals(v: &Json, t: &str, number: Option<f64>) -> bool {
    match v {
        Json::Str(s) => s == t,
        Json::Int(_) | Json::Num(_) => number.is_some_and(|n| v.as_f64() == Some(n)),
        Json::Bool(true) => t == "true",
        Json::Bool(false) => t == "false",
        Json::Arr(_) | Json::Obj(_) | Json::Null => false,
    }
}

/// `a - b` as a trace number: an integer when it fits in 64 bits.
pub(super) fn difference(a: i64, b: i64) -> (i128, Json) {
    let d = a as i128 - b as i128;
    let json = i64::try_from(d).map(Json::Int).unwrap_or(Json::Num(d as f64));
    (d, json)
}

impl Engine {
    /// One condition against the report and the state before it (spec: Conditions).
    pub(super) fn evaluate(&self, c: &Condition, r: &Report, key: &str) -> Outcome {
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn three_valued_results() {
        assert_eq!(Truth::True.negate(), Truth::False);
        assert_eq!(Truth::False.negate(), Truth::True);
        assert_eq!(Truth::Unknown.negate(), Truth::Unknown);
        assert_eq!(Truth::of(true), Truth::True);
    }

    #[test]
    fn key_equality_and_differences() {
        assert!(key_equals(&Json::Str("a".into()), "a", None));
        assert!(key_equals(&Json::Int(2), "2.0", Some(2.0)));
        assert!(!key_equals(&Json::Int(2), "two", None));
        assert!(key_equals(&Json::Bool(true), "true", None) && key_equals(&Json::Bool(false), "false", None));
        assert!(!key_equals(&Json::Arr(vec![]), "[]", None));
        assert_eq!(difference(5, 7), (-2, Json::Int(-2)));
        assert_eq!(difference(i64::MAX, -1).1, Json::Num(i64::MAX as f64 + 1.0));
        assert_eq!(range_json(&Range { min: Some(1.0), max: None }).to_string(), "[1.0,null]");
        assert_eq!(in_list(None, &["a".to_string()]).truth, Truth::Unknown);
        assert_eq!(in_range(Some(&Json::Bool(true)), &Range { min: None, max: None }).truth, Truth::Unknown);
    }
}
