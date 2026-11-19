//! Reports (spec/correlate.md, Reports): the required keys, the reject event,
//! and the optional-key rules. Shared by correlate (`engine`) and the filter
//! function (`filter_fn`), whose spec cites this section unchanged.

use std::collections::BTreeMap;

use crate::json::{obj, Json};

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
