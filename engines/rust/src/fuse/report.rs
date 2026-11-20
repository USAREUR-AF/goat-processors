//! fuse.md Reports: the required keys and the normalized report.

use super::*;

pub(super) const REQUIRED: [&str; 5] = ["track.source_id", "uid", "time_ms", "lat", "lon"];

/// Reports: the required key that is missing, checked in table order.
pub(super) fn missing_required(fields: &BTreeMap<String, Json>) -> Option<&'static str> {
    REQUIRED.into_iter().find(|key| {
        let v = fields.get(*key);
        match *key {
            "track.source_id" | "uid" => v.and_then(Json::as_str).is_none(),
            "time_ms" => v.and_then(Json::as_i64).is_none(),
            _ => v.and_then(Json::as_f64).is_none(),
        }
    })
}

/// The normalized report: every key removed that is `null`, an optional
/// correlate key of the wrong type, a `ce` of 0 or below, or an unusable
/// `fuse.group` (not a string, or empty).
pub(super) fn normalize(fields: &BTreeMap<String, Json>) -> BTreeMap<String, Json> {
    fields
        .iter()
        .filter(|(key, value)| match key.as_str() {
            _ if **value == Json::Null => false,
            "hae" | "course" | "speed_ms" => value.as_f64().is_some(),
            "ce" => value.as_f64().is_some_and(|c| c > 0.0),
            "type" => value.as_str().is_some(),
            "stale_ms" => value.as_i64().is_some(),
            "fuse.group" => value.as_str().is_some_and(|g| !g.is_empty()),
            _ => true,
        })
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect()
}
