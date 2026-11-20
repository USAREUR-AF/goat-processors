//! The goat fabric (Zenoh): one session, the subscribers, the publisher.
//!
//! A sample's payload is one shared-model report as a JSON object, a JSON
//! array of reports, or JSON lines of reports. Anything else is counted as
//! unreadable and skipped.

use std::sync::mpsc::Sender;

use goat_correlator::json::{self, Json};
use zenoh::Wait;

use crate::config::Fabric;

/// What an input thread hands the main loop.
pub enum Input {
    Reports(Vec<Json>),
    Unreadable { from: String, why: String },
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
pub fn open(f: &Fabric, keys: &[String], tx: Sender<Input>) -> Result<Session, String> {
    let session = zenoh::open(zenoh_config(f)?).wait().map_err(|e| format!("cannot open the fabric session: {e}"))?;
    let mut subs = Vec::new();
    for k in keys {
        let tx = tx.clone();
        let sub = session
            .declare_subscriber(k.as_str())
            .callback(move |sample| {
                let from = sample.key_expr().as_str().to_string();
                let bytes = sample.payload().to_bytes();
                let _ = tx.send(decode(&from, &bytes));
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

    pub fn put(&self, key: &str, value: &Json) -> Result<(), String> {
        self.session.put(key, value.to_string()).wait().map_err(|e| format!("publish {key}: {e}"))
    }
}

/// Reads a payload: a report, an array of reports, or JSON lines of reports.
pub fn decode(from: &str, bytes: &[u8]) -> Input {
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
