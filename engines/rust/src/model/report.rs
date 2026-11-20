//! correlate.md Reports (with Time quality): the required keys, the reject event,
//! and the optional-key rules. Shared by correlate and the filter
//! function, whose spec cites this section unchanged.

use std::collections::BTreeMap;

use super::json::{obj, Json};
use super::pack::{TimeDefault, TimeState};

/// The five required keys of an accepted report.
#[derive(Debug, Clone, Copy)]
pub struct Required<'a> {
    pub source: &'a str,
    pub uid: &'a str,
    pub time_ms: i64,
    pub lat: f64,
    pub lon: f64,
}

impl Required<'_> {
    /// The entity key `<track.source_id>/<uid>`.
    pub fn key(&self) -> String {
        format!("{}/{}", self.source, self.uid)
    }
}

/// The required keys, checked in table order. `Err(key)` names the first one
/// that is absent, `null` or of the wrong type: `track.source_id` and `uid`
/// strings, `time_ms` an integer, `lat` and `lon` numbers.
pub fn required(fields: &BTreeMap<String, Json>) -> Result<Required<'_>, &'static str> {
    let source = fields.get("track.source_id").and_then(Json::as_str).ok_or("track.source_id")?;
    let uid = fields.get("uid").and_then(Json::as_str).ok_or("uid")?;
    let time_ms = fields.get("time_ms").and_then(Json::as_i64).ok_or("time_ms")?;
    let lat = fields.get("lat").and_then(Json::as_f64).ok_or("lat")?;
    let lon = fields.get("lon").and_then(Json::as_f64).ok_or("lon")?;
    Ok(Required { source, uid, time_ms, lat, lon })
}

/// `{"ev":"reject","reason":"missing:<key>"}`, never with `entity`.
pub fn reject_missing(key: &str) -> Json {
    obj(vec![("ev", "reject".into()), ("reason", format!("missing:{}", key).into())])
}

/// The value of `key` after the optional-key rules, or `None` when absent:
/// `null` is absent for every key; `hae`, `ce`, `course`, `speed_ms` must be
/// numbers, `type` a string, `stale_ms` an integer, else absent; a `ce` of 0
/// or below is absent. Any other key is present with any non-null value.
pub fn optional<'a>(fields: &'a BTreeMap<String, Json>, key: &str) -> Option<&'a Json> {
    let v = fields.get(key).filter(|v| **v != Json::Null)?;
    let ok = match key {
        "hae" | "course" | "speed_ms" => v.as_f64().is_some(),
        "ce" => v.as_f64().is_some_and(|c| c > 0.0),
        "type" => v.as_str().is_some(),
        "stale_ms" => v.as_i64().is_some(),
        _ => true,
    };
    ok.then_some(v)
}

/// An optional numeric key as a number.
pub fn optional_f64(fields: &BTreeMap<String, Json>, key: &str) -> Option<f64> {
    optional(fields, key).and_then(Json::as_f64)
}

/// A report's `time_error_ms` (correlate.md Reports, Time quality): a finite
/// number 0 or above, else absent. Never a reject.
pub fn time_error_ms(fields: &BTreeMap<String, Json>) -> Option<f64> {
    fields.get("time_error_ms").and_then(Json::as_f64).filter(|ms| ms.is_finite() && *ms >= 0.0)
}

/// A report's `time_state` (correlate.md Reports, Time quality): one of
/// `coherent`, `drifting`, `free-running`, byte for byte, else absent.
pub fn time_state(fields: &BTreeMap<String, Json>) -> Option<TimeState> {
    fields.get("time_state").and_then(Json::as_str).and_then(TimeState::parse)
}

/// The time error and time state of a report (correlate.md Reports, Time
/// quality).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TimeQuality {
    /// `te`, milliseconds, 0 or above.
    pub error_ms: f64,
    /// Parsed and validated; correlate does not use it in this version.
    pub state: TimeState,
}

/// Found per key, independently: 1. the report's own key; 2. otherwise the
/// pack's `time_default` for the report's source, when it gives that key;
/// 3. otherwise error 0 and state `coherent`.
pub fn time_quality(fields: &BTreeMap<String, Json>, source: &str, defaults: &BTreeMap<String, TimeDefault>) -> TimeQuality {
    let default = defaults.get(source);
    let error_ms = time_error_ms(fields).or_else(|| default.and_then(|d| d.error_ms)).unwrap_or(0.0);
    let state = time_state(fields).or_else(|| default.and_then(|d| d.state)).unwrap_or(TimeState::Coherent);
    TimeQuality { error_ms, state }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::json::parse;

    fn fields(text: &str) -> BTreeMap<String, Json> {
        parse(text).unwrap().as_object().unwrap().clone()
    }

    #[test]
    fn required_keys_in_table_order() {
        assert_eq!(required(&fields("{}")).unwrap_err(), "track.source_id");
        assert_eq!(required(&fields(r#"{"track.source_id":"a","time_ms":1}"#)).unwrap_err(), "uid");
        assert_eq!(required(&fields(r#"{"track.source_id":"a","uid":"u","time_ms":1.0,"lat":0,"lon":0}"#)).unwrap_err(), "time_ms");
        assert_eq!(required(&fields(r#"{"track.source_id":"a","uid":"u","time_ms":1,"lat":"0","lon":0}"#)).unwrap_err(), "lat");
        let ok = fields(r#"{"track.source_id":"a","uid":"u","time_ms":1,"lat":2,"lon":3.5}"#);
        let r = required(&ok).unwrap();
        assert_eq!((r.key(), r.time_ms, r.lat, r.lon), ("a/u".to_string(), 1, 2.0, 3.5));
        assert_eq!(reject_missing("uid").to_string(), r#"{"ev":"reject","reason":"missing:uid"}"#);
    }

    #[test]
    fn optional_keys_of_the_wrong_type_are_absent() {
        let f = fields(r#"{"hae":"1","ce":0,"course":3,"type":5,"stale_ms":1.5,"x":null,"y":false}"#);
        assert_eq!(optional(&f, "hae"), None);
        assert_eq!(optional(&f, "ce"), None);
        assert_eq!(optional_f64(&f, "course"), Some(3.0));
        assert_eq!(optional(&f, "type"), None);
        assert_eq!(optional(&f, "stale_ms"), None);
        assert_eq!(optional(&f, "x"), None);
        assert_eq!(optional(&f, "y"), Some(&Json::Bool(false)));
    }

    #[test]
    fn time_quality_takes_the_report_then_the_default_then_zero() {
        let mut defaults = BTreeMap::new();
        defaults.insert("radar".to_string(), TimeDefault { error_ms: Some(500.0), state: None });
        let report = fields(r#"{"time_error_ms":0,"time_state":"drifting"}"#);
        assert_eq!(time_quality(&report, "radar", &defaults), TimeQuality { error_ms: 0.0, state: TimeState::Drifting });
        let invalid = fields(r#"{"time_error_ms":-1,"time_state":"Drifting"}"#);
        assert_eq!(time_quality(&invalid, "radar", &defaults), TimeQuality { error_ms: 500.0, state: TimeState::Coherent });
        assert_eq!(time_quality(&invalid, "other", &defaults).error_ms, 0.0);
    }
}
