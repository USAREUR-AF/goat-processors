//! The goat fabric (Zenoh): one session, the subscribers, the publisher.
//!
//! A sample's payload is one shared-model report as a JSON object, a JSON
//! array of reports, or JSON lines of reports. Anything else is counted as
//! unreadable and skipped.

use std::sync::mpsc::SyncSender;

use crate::json::{self, Json};
use zenoh::Wait;

use crate::config::Fabric;

/// What an input thread hands the main loop.
pub enum Input {
    /// Reports from the fabric, UDP or a file: the runner cannot check who
    /// wrote their provenance, so it removes any `provenance.checked` claim.
    Reports(Vec<Json>),
    /// Reports an agent published through the API (`POST /v1/source`): the
    /// runner checked the identity and set the provenance itself.
    Checked(Vec<Json>),
    Unreadable { from: String, why: String },
    /// A request from the API, answered by the service loop.
    Api(crate::api::Call),
    /// A file input has played to its end.
    Ended,
    /// A proposal's policy gate finished.
    GateDone { id: String, passed: bool, gate: Json },
}

/// The Zenoh config for a fabric section.
pub fn zenoh_config(f: &Fabric) -> Result<zenoh::Config, String> {
    let mut c = zenoh::Config::default();
    let set = |c: &mut zenoh::Config, k: &str, v: String| c.insert_json5(k, &v).map_err(|e| format!("fabric setting {k}: {e}"));
    set(&mut c, "mode", json_str(&f.mode))?;
    set(&mut c, "connect/endpoints", json_list(&f.connect))?;
    set(&mut c, "listen/endpoints", json_list(&f.listen))?;
    // The runner finds its routers from the config, not by scouting.
    set(&mut c, "scouting/multicast/enabled", "false".into())?;
    if let Some(t) = &f.tls {
        set(&mut c, "transport/link/tls/root_ca_certificate", json_str(&t.root_ca.to_string_lossy()))?;
        set(&mut c, "transport/link/tls/enable_mtls", "true".into())?;
        set(&mut c, "transport/link/tls/connect_certificate", json_str(&t.certificate.to_string_lossy()))?;
        set(&mut c, "transport/link/tls/connect_private_key", json_str(&t.private_key.to_string_lossy()))?;
        set(&mut c, "transport/link/tls/listen_certificate", json_str(&t.certificate.to_string_lossy()))?;
        set(&mut c, "transport/link/tls/listen_private_key", json_str(&t.private_key.to_string_lossy()))?;
    }
    Ok(c)
}

fn json_str(s: &str) -> String {
    Json::Str(s.to_string()).to_string()
}

fn json_list(v: &[String]) -> String {
    Json::Arr(v.iter().map(|s| Json::Str(s.clone())).collect()).to_string()
}

pub struct Session {
    pub session: zenoh::Session,
    _subs: Vec<zenoh::pubsub::Subscriber<()>>,
}

/// Opens the session and subscribes to `keys`; every sample goes to `tx`.
pub fn open(f: &Fabric, keys: &[String], tx: SyncSender<Input>) -> Result<Session, String> {
    let session = zenoh::open(zenoh_config(f)?).wait().map_err(|e| format!("cannot open the fabric session: {e}"))?;
    let mut subs = Vec::new();
    for k in keys {
        let tx = tx.clone();
        let sub = session
            .declare_subscriber(k.as_str())
            .callback(move |sample| {
                let from = sample.key_expr().as_str().to_string();
                let bytes = sample.payload().to_bytes();
                crate::service::offer(&tx, decode(&from, &bytes));
            })
            .wait()
            .map_err(|e| format!("cannot subscribe to {k}: {e}"))?;
        subs.push(sub);
    }
    Ok(Session { session, _subs: subs })
}

impl Session {
    /// How many routers the session is connected to now.
    pub fn routers(&self) -> usize {
        self.session.info().routers_zid().wait().count()
    }

    // Every value is live data: when a link is congested it is dropped,
    // never waited for, so the runner cannot back up the fabric (goat's
    // decouple-and-drop rule for the live plane).
    pub fn put(&self, key: &str, value: &Json) -> Result<(), String> {
        self.session
            .put(key, value.to_string())
            .encoding(zenoh::bytes::Encoding::APPLICATION_JSON)
            .congestion_control(zenoh::qos::CongestionControl::Drop)
            .wait()
            .map_err(|e| format!("publish {key}: {e}"))
    }

    /// Publishes text as JSON lines (one JSON object per line).
    pub fn put_text(&self, key: &str, value: String) -> Result<(), String> {
        self.session
            .put(key, value)
            .encoding(zenoh::bytes::Encoding::TEXT_PLAIN.with_schema("jsonl"))
            .congestion_control(zenoh::qos::CongestionControl::Drop)
            .wait()
            .map_err(|e| format!("publish {key}: {e}"))
    }
}

/// Reads a payload: a report, an array of reports, or JSON lines of reports.
/// Refuses a report whose position or kinematics no real object has: a
/// number that is not finite, `lat` beyond 90, or `lon` beyond 360. The
/// engines bring longitudes into (-180, 180] by adding or subtracting 360
/// until they fit, which for a value like 1e308 never ends and stops the
/// service loop; the spec leaves such values open, so the runner refuses
/// them before any engine sees them. Every value a real source sends,
/// including a longitude written in 0 to 360, passes.
pub fn in_range(r: &Json) -> Result<(), String> {
    for k in ["lat", "lon", "hae", "ce", "course", "speed_ms", "time_error_ms"] {
        if let Some(Json::Num(x)) = r.get(k) {
            if !x.is_finite() {
                return Err(format!("{k} is not a finite number"));
            }
        }
    }
    if let Some(x) = r.get("lat").and_then(Json::as_f64) {
        if x.abs() > 90.0 {
            return Err(format!("lat {x} is beyond 90"));
        }
    }
    if let Some(x) = r.get("lon").and_then(Json::as_f64) {
        if x.abs() > 360.0 {
            return Err(format!("lon {x} is beyond 360"));
        }
    }
    Ok(())
}

pub fn decode(from: &str, bytes: &[u8]) -> Input {
    match decode_raw(from, bytes) {
        Input::Reports(v) => Input::Reports(v.into_iter().map(flatten).collect()),
        other => other,
    }
}

/// A report written with nested objects, as a JSON encoder that cannot
/// write a member name holding `.` produces it (`{"track": {"source_id":
/// "r1"}}`), is read with dotted keys (`"track.source_id": "r1"`). A dotted
/// key already present is kept; arrays are left as they are.
pub fn flatten(r: Json) -> Json {
    let Json::Obj(m) = r else { return r };
    if !m.values().any(|v| matches!(v, Json::Obj(_))) {
        return Json::Obj(m);
    }
    fn walk(prefix: &str, m: &json::Map, out: &mut Vec<(String, Json)>) {
        for (k, v) in m {
            let key = if prefix.is_empty() { k.as_str().to_string() } else { format!("{prefix}.{}", k.as_str()) };
            match v {
                Json::Obj(inner) => walk(&key, inner, out),
                _ => out.push((key, v.clone())),
            }
        }
    }
    let mut flat = Vec::new();
    walk("", &m, &mut flat);
    let mut out = json::Map::new();
    // Keys written flat in the input win over the same key reached by nesting.
    for (k, v) in m.iter().filter(|(_, v)| !matches!(v, Json::Obj(_))) {
        out.insert(k.clone(), v.clone());
    }
    for (k, v) in flat {
        if !out.contains_key(k.as_str()) {
            out.insert(k.into(), v);
        }
    }
    Json::Obj(out)
}

fn decode_raw(from: &str, bytes: &[u8]) -> Input {
    let Ok(text) = std::str::from_utf8(bytes) else {
        return Input::Unreadable { from: from.into(), why: "not UTF-8".into() };
    };
    match json::parse(text) {
        Ok(Json::Obj(m)) => Input::Reports(vec![Json::Obj(m)]),
        Ok(Json::Arr(v)) if v.iter().all(|r| matches!(r, Json::Obj(_))) => Input::Reports(v),
        Ok(_) => Input::Unreadable { from: from.into(), why: "JSON, but not a report or a list of reports".into() },
        Err(e) => {
            let mut out = Vec::new();
            for line in text.lines().filter(|l| !l.trim().is_empty()) {
                match json::parse(line) {
                    Ok(Json::Obj(m)) => out.push(Json::Obj(m)),
                    _ => return Input::Unreadable { from: from.into(), why: format!("not JSON ({e})") },
                }
            }
            Input::Reports(out)
        }
    }
}

/// A key chunk made safe: characters a key may not hold become `_`.
pub fn key_chunk(s: &str) -> String {
    s.chars().map(|c| if matches!(c, '*' | '$' | '?' | '#') || c.is_control() { '_' } else { c }).collect::<String>()
        .split('/').filter(|c| !c.is_empty()).collect::<Vec<_>>().join("/")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes() {
        assert!(matches!(decode("k", b"{\"uid\":\"a\"}"), Input::Reports(v) if v.len() == 1));
        assert!(matches!(decode("k", b"[{\"uid\":\"a\"},{\"uid\":\"b\"}]"), Input::Reports(v) if v.len() == 2));
        assert!(matches!(decode("k", b"{\"uid\":\"a\"}\n{\"uid\":\"b\"}\n"), Input::Reports(v) if v.len() == 2));
        assert!(matches!(decode("k", b"3"), Input::Unreadable { .. }));
        assert!(matches!(decode("k", b"\xff"), Input::Unreadable { .. }));
        assert_eq!(key_chunk("radar-1/T*1"), "radar-1/T_1");
        match decode("k", br#"{"track":{"source_id":"r1"},"uid":"T1","track.source_id":"r0","a":{"b":{"c":1}}}"#) {
            Input::Reports(v) => {
                assert_eq!(v[0].get("track.source_id").and_then(|x| x.as_str()), Some("r0"), "a flat key wins");
                assert_eq!(v[0].get("a.b.c"), Some(&Json::Int(1)));
                assert!(v[0].get("track").is_none());
            }
            _ => panic!(),
        }
        match decode("k", br#"{"track":{"source_id":"r1"},"uid":"T1"}"#) {
            Input::Reports(v) => assert_eq!(v[0].get("track.source_id").and_then(|x| x.as_str()), Some("r1")),
            _ => panic!(),
        }
        assert_eq!(key_chunk("a//b"), "a/b");
    }

    #[test]
    fn tls_config_builds() {
        let f = Fabric {
            mode: "client".into(),
            connect: vec!["tls/router:7447".into()],
            listen: vec![],
            tls: Some(crate::config::Tls { root_ca: "/a/ca.pem".into(), certificate: "/a/c.pem".into(), private_key: "/a/k.pem".into() }),
        };
        zenoh_config(&f).unwrap();
    }
}
