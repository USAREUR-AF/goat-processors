//! The command line and the service, run as a site runs them: the binary,
//! a config file, input files, the fabric.

use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use goat_correlator::json::{self, Json};

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_goat-processors"))
}

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").canonicalize().unwrap()
}

fn tmp(name: &str) -> PathBuf {
    let d = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A config for tests: the shipped one with the placeholders set.
fn shipped_with(site: &str, router: &str) -> String {
    std::fs::read_to_string(repo().join("runner/config/runner.yaml"))
        .unwrap()
        .replace("site: CHANGE-ME", &format!("site: {site}"))
        .replace("tls/CHANGE-ME:7447", router)
        .replace("/usr/share/goat-processors/packs", repo().join("packs").to_str().unwrap())
}

fn check(text: &str) -> (bool, String) {
    let d = tmp(&format!("check-{:x}", text.len() * 31 + text.bytes().map(|b| b as usize).sum::<usize>()));
    let p = d.join("runner.yaml");
    std::fs::write(&p, text).unwrap();
    let out = bin().args(["config", "check", "-c"]).arg(&p).output().unwrap();
    (out.status.success(), String::from_utf8_lossy(&out.stdout).to_string())
}

#[test]
fn config_check_refuses_the_unedited_file() {
    let (ok, out) = check(&std::fs::read_to_string(repo().join("runner/config/runner.yaml")).unwrap());
    assert!(!ok);
    assert!(out.contains("still holds the placeholder CHANGE-ME"), "{out}");
}

#[test]
fn config_check_accepts_the_edited_file() {
    let (ok, out) = check(&shipped_with("site-a", "tls/router.site-a:7447"));
    assert!(ok, "{out}");
}

#[test]
fn config_check_says_what_to_fix() {
    let good = shipped_with("site-a", "tls/router.site-a:7447");
    let cases: Vec<(String, &str)> = vec![
        (good.replace("tick_ms: 1000", "tick_ms: 1000\ncolour: red"), "unknown field `colour`"),
        (good.replace("pack: quality-feed", "pack: quality-nothing"), "does not load"),
        (good.replace("pack: quality-feed", "pack: fuse-best"), "is not a quality pack"),
        (good.replace("function: quality", "function: filter").replace("pack: quality-feed", "pack: filter-thin"), "comes after correlate"),
        (good.replace("data/entity/track/**", "data/**"), "would read what it publishes"),
        (good.replace("tls/router.site-a:7447", "router.site-a"), "fabric locator"),
        (good.replace("site: site-a", "site: site a"), "is not a valid name"),
        (good.replace("clock: wall", "clock: sundial"), "unknown variant"),
        (good.replace("tick_ms: 1000", "tick_ms: 1"), "out of range"),
    ];
    for (text, want) in cases {
        let (ok, out) = check(&text);
        assert!(!ok, "accepted, but should fail with {want:?}");
        assert!(out.contains(want), "want {want:?} in:\n{out}");
    }
}

#[test]
fn config_check_json() {
    let d = tmp("check-json");
    std::fs::write(d.join("r.yaml"), "name: x\n").unwrap();
    let out = bin().args(["config", "check", "-o", "json", "-c"]).arg(d.join("r.yaml")).output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let v = json::parse(String::from_utf8_lossy(&out.stdout).trim()).unwrap();
    assert_eq!(v.get("valid"), Some(&Json::Bool(false)));
}

#[test]
fn pack_ls_lists_every_pack() {
    let out = bin().args(["pack", "ls", "-o", "json", "--packs-dir"]).arg(repo().join("packs")).output().unwrap();
    assert!(out.status.success());
    let v = json::parse(String::from_utf8_lossy(&out.stdout).trim()).unwrap();
    let names: Vec<&str> = v.as_array().unwrap().iter().map(|p| p.get("pack").unwrap().as_str().unwrap()).collect();
    assert!(names.contains(&"correlate-assign-time") && names.contains(&"quality-feed"), "{names:?}");
}

#[test]
fn selftest_replays_every_vector() {
    let out = bin().args(["selftest", "-o", "json", "--packs-dir"]).arg(repo().join("packs")).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stdout));
    let v = json::parse(String::from_utf8_lossy(&out.stdout).trim()).unwrap();
    assert!(v.get("passed").unwrap().as_i64().unwrap() > 100);
}

#[test]
fn doctor_reports_a_missing_service() {
    let d = tmp("doctor");
    let cfg = shipped_with("site-a", "tcp/127.0.0.1:1").replace("  tls:\n    root_ca: /etc/goat-processors/tls/ca.pem\n    certificate: /etc/goat-processors/tls/runner.pem\n    private_key: /etc/goat-processors/tls/runner.key\n", "")
        + &format!("status_file: {}\napi:\n  enabled: false\n", d.join("status.json").display());
    std::fs::write(d.join("r.yaml"), cfg).unwrap();
    let out = bin().args(["doctor", "-o", "json", "-c"]).arg(d.join("r.yaml")).output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    let v = json::parse(String::from_utf8_lossy(&out.stdout).trim()).unwrap();
    let fails: Vec<String> = v.as_array().unwrap().iter().filter(|f| f.get("level").unwrap().as_str() == Some("fail")).map(|f| f.get("detail").unwrap().as_str().unwrap().to_string()).collect();
    assert!(fails.iter().any(|f| f.contains("no TCP connection")), "{fails:?}");
    assert!(fails.iter().any(|f| f.contains("no status")), "{fails:?}");
}

/// The reports of a correlate vector and a quality vector, as a recording of reports only.
fn scenario(dir: &Path) -> PathBuf {
    let mut lines = Vec::new();
    for v in ["packs/correlate-assign-time/vectors/56-assign-time-offset-fit.json"] {
        let want = json::parse(&std::fs::read_to_string(repo().join(v)).unwrap()).unwrap();
        for s in want.get("steps").unwrap().as_array().unwrap() {
            if let Some(r) = s.get("ingest") {
                lines.push(r.to_string());
            }
        }
    }
    let p = dir.join("scenario.jsonl");
    std::fs::write(&p, lines.join("\n") + "\n").unwrap();
    p
}

/// Runs the service until every input has ended, then stops it.
fn run_until_inputs_end(cfg: &Path) {
    let mut child = bin().args(["run", "-c"]).arg(cfg).stderr(Stdio::piped()).spawn().unwrap();
    let stderr = child.stderr.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for l in BufReader::new(stderr).lines().map_while(Result::ok) {
            let _ = tx.send(l);
        }
    });
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut log = Vec::new();
    loop {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok(l) if l.contains("every input has ended") => break,
            Ok(l) => log.push(l),
            Err(_) => {}
        }
        assert!(Instant::now() < deadline, "the service did not finish its input: {log:?}");
        if let Ok(Some(st)) = child.try_wait() {
            panic!("the service exited ({st}): {log:?}");
        }
    }
    child.kill().unwrap();
    child.wait().unwrap();
}

#[test]
fn service_record_replays_to_the_same_output() {
    let d = tmp("service-file");
    let scen = scenario(&d);
    let cfg = format!(
        "name: t\nsite: s\npacks_dir: {}\ntick_ms: 1000\nclock: input\ninputs:\n  file:\n    path: {}\n    speed: 0\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\n  - {{function: fuse, pack: fuse-independent}}\n  - {{function: quality, pack: quality-feed}}\noutputs:\n  file:\n    path: {}\n    trace: true\nrecord:\n  path: {}\nstatus_file: {}\napi:\n  enabled: false\n",
        repo().join("packs").display(),
        scen.display(),
        d.join("out.jsonl").display(),
        d.join("record.jsonl").display(),
        d.join("status.json").display()
    );
    std::fs::write(d.join("r.yaml"), cfg).unwrap();
    let ok = bin().args(["config", "check", "-c"]).arg(d.join("r.yaml")).output().unwrap();
    assert!(ok.status.success(), "{}", String::from_utf8_lossy(&ok.stdout));
    run_until_inputs_end(&d.join("r.yaml"));

    let service_out = std::fs::read_to_string(d.join("out.jsonl")).unwrap();
    assert!(service_out.contains("\"ev\":\"system\""), "no system track in the output");
    assert!(service_out.contains("\"ev\":\"fused\""), "fuse made no fused estimate from correlate's groups");
    // The recording, replayed with the same config, gives the same lines.
    let replay = bin().args(["replay"]).arg(d.join("record.jsonl")).args(["--trace", "-c"]).arg(d.join("r.yaml")).output().unwrap();
    assert!(replay.status.success(), "{}", String::from_utf8_lossy(&replay.stderr));
    assert_eq!(String::from_utf8(replay.stdout).unwrap(), service_out);
    // The replay of the reports alone, ticked by the input clock, gives them too.
    let replay = bin().args(["replay"]).arg(&scen).args(["--trace", "-c"]).arg(d.join("r.yaml")).output().unwrap();
    assert_eq!(String::from_utf8(replay.stdout).unwrap(), service_out);

    let st = json::parse(&std::fs::read_to_string(d.join("status.json")).unwrap()).unwrap();
    let c = st.get("counters").unwrap();
    assert!(c.get("reports_in").unwrap().as_i64().unwrap() > 0);
    assert_eq!(st.get("state").unwrap().as_str(), Some("running"));
}

#[test]
/// A report's radar cross section reaches the system track, per source, in
/// the service and in a replay of the same reports.
fn service_carries_the_radar_cross_section_per_source() {
    let d = tmp("service-rcs");
    let mut sources = std::collections::BTreeSet::new();
    let lines: Vec<String> = std::fs::read_to_string(scenario(&d))
        .unwrap()
        .lines()
        .map(|l| {
            let r = json::parse(l).unwrap();
            let src = r.get("track.source_id").unwrap().as_str().unwrap().to_string();
            // One value per source, so the output shows whose value is whose.
            let v = if sources.is_empty() || sources.iter().next() == Some(&src) { "0.25" } else { "1.5" };
            sources.insert(src);
            format!("{},\"radar.rcs_m2\":{v}}}", l.trim_end().strip_suffix('}').unwrap())
        })
        .collect();
    assert!(sources.len() >= 2, "the scenario needs two sources: {sources:?}");
    let scen = d.join("rcs.jsonl");
    std::fs::write(&scen, lines.join("\n") + "\n").unwrap();
    let cfg = format!(
        "name: t\nsite: s\npacks_dir: {}\ntick_ms: 1000\nclock: input\ninputs:\n  file:\n    path: {}\n    speed: 0\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\n  - {{function: fuse, pack: fuse-independent}}\noutputs:\n  file:\n    path: {}\nstatus_file: {}\napi:\n  enabled: false\n",
        repo().join("packs").display(),
        scen.display(),
        d.join("out.jsonl").display(),
        d.join("status.json").display()
    );
    std::fs::write(d.join("r.yaml"), cfg).unwrap();
    run_until_inputs_end(&d.join("r.yaml"));
    let out = std::fs::read_to_string(d.join("out.jsonl")).unwrap();
    let mut both = 0;
    for stage in out.lines().map(|l| json::parse(l).unwrap()) {
        let Some(events) = stage.get("events").and_then(|e| e.as_array()) else { continue };
        for e in events {
            let Some(rcs) = e.get("rcs").and_then(|r| r.as_array()) else { continue };
            let members: Vec<&str> = e.get("members").unwrap().as_array().unwrap().iter().filter_map(|m| m.as_str()).collect();
            for entry in rcs {
                let member = entry.get("member").unwrap().as_str().unwrap();
                assert!(members.contains(&member), "{member} is not a member of this track");
                let first = sources.iter().next().unwrap();
                let want = if entry.get("source").unwrap().as_str() == Some(first) { 0.25 } else { 1.5 };
                assert_eq!(entry.get("rcs_m2").unwrap().as_f64(), Some(want), "each source keeps its own value");
                assert!(entry.get("time_ms").unwrap().as_i64().is_some());
            }
            // The top value is the value of the entry with the latest time.
            let latest = rcs.iter().max_by_key(|x| x.get("time_ms").unwrap().as_i64().unwrap()).unwrap();
            let top = e.get("rcs_m2").unwrap().as_f64().unwrap();
            let latest_ms = latest.get("time_ms").unwrap().as_i64();
            assert!(rcs.iter().any(|x| x.get("time_ms").unwrap().as_i64() == latest_ms && x.get("rcs_m2").unwrap().as_f64() == Some(top)));
            if rcs.len() >= 2 {
                both += 1;
            }
        }
    }
    assert!(both > 0, "no track listed the value of two sources");
    let replay = bin().args(["replay"]).arg(&scen).args(["-c"]).arg(d.join("r.yaml")).output().unwrap();
    assert_eq!(String::from_utf8(replay.stdout).unwrap(), out);
}

#[test]
fn service_reads_and_publishes_on_the_fabric() {
    use zenoh::Wait;
    let d = tmp("service-fabric");
    let port = {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        l.local_addr().unwrap().port()
    };
    // The test is the other side of the fabric: a peer that listens.
    let mut zc = zenoh::Config::default();
    zc.insert_json5("mode", "\"peer\"").unwrap();
    zc.insert_json5("listen/endpoints", &format!("[\"tcp/127.0.0.1:{port}\"]")).unwrap();
    zc.insert_json5("scouting/multicast/enabled", "false").unwrap();
    let z = zenoh::open(zc).wait().unwrap();
    let got = z.declare_subscriber("data/processed/**").with(zenoh::handlers::FifoChannel::new(10_000)).wait().unwrap();

    let cfg = format!(
        "name: t\nsite: s\npacks_dir: {}\ntick_ms: 200\nfabric:\n  mode: peer\n  connect: [\"tcp/127.0.0.1:{port}\"]\ninputs:\n  fabric:\n    keys: [\"data/entity/track/**\"]\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\n  - {{function: quality, pack: quality-feed}}\noutputs:\n  fabric: {{}}\nstatus_file: {}\napi:\n  enabled: false\n",
        repo().join("packs").display(),
        d.join("status.json").display()
    );
    std::fs::write(d.join("r.yaml"), cfg).unwrap();
    let mut child = bin().args(["run", "-c"]).arg(d.join("r.yaml")).stderr(Stdio::null()).spawn().unwrap();

    // Two sources report one object near the wall clock, every 200 ms.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut keys = std::collections::BTreeSet::new();
    let mut joined = false;
    let mut i = 0;
    while Instant::now() < deadline && !(joined && keys.iter().any(|k: &String| k.contains("/quality/"))) {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as i64;
        for (src, dlat) in [("radar-1", 0.0), ("adsb", 0.0001)] {
            let r = format!("{{\"track.source_id\":\"{src}\",\"uid\":\"T1\",\"time_ms\":{now},\"lat\":{},\"lon\":1.0,\"ce\":30.0,\"type\":\"a-f-A\"}}", 1.0 + dlat + i as f64 * 1e-5);
            z.put(format!("data/entity/track/s/{src}/T1"), r).wait().unwrap();
        }
        i += 1;
        std::thread::sleep(Duration::from_millis(200));
        while let Ok(Some(s)) = got.try_recv() {
            let key = s.key_expr().as_str().to_string();
            if key.contains("/tracks/") {
                let v = json::parse(&String::from_utf8_lossy(&s.payload().to_bytes())).unwrap();
                joined |= v.get("members").map(|m| m.to_string()) == Some("[\"adsb/T1\",\"radar-1/T1\"]".into());
                assert_eq!(s.encoding(), &zenoh::bytes::Encoding::APPLICATION_JSON);
            }
            keys.insert(key);
        }
    }
    // One more tick, so the status file has counted every report.
    std::thread::sleep(Duration::from_millis(500));
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(joined, "no system track joined the two sources: {keys:?}");
    assert!(keys.iter().any(|k| k.starts_with("data/processed/s/t/quality/entity/")), "{keys:?}");
    assert!(keys.contains("data/processed/s/t/events/correlate"), "{keys:?}");
    let st = json::parse(&std::fs::read_to_string(d.join("status.json")).unwrap()).unwrap();
    assert!(st.get("counters").unwrap().get("per_source").unwrap().get("adsb").is_some());
}

#[test]
fn service_batch_layout_publishes_a_fixed_key_set() {
    use zenoh::Wait;
    let d = tmp("service-fabric-batch");
    let port = {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        l.local_addr().unwrap().port()
    };
    let mut zc = zenoh::Config::default();
    zc.insert_json5("mode", "\"peer\"").unwrap();
    zc.insert_json5("listen/endpoints", &format!("[\"tcp/127.0.0.1:{port}\"]")).unwrap();
    zc.insert_json5("scouting/multicast/enabled", "false").unwrap();
    let z = zenoh::open(zc).wait().unwrap();
    let got = z.declare_subscriber("volatile/site-a/**").with(zenoh::handlers::FifoChannel::new(10_000)).wait().unwrap();

    let cfg = format!(
        "name: t\nsite: s\npacks_dir: {}\ntick_ms: 200\nfabric:\n  mode: peer\n  connect: [\"tcp/127.0.0.1:{port}\"]\ninputs:\n  fabric:\n    keys: [\"data/entity/track/**\"]\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\n  - {{function: quality, pack: quality-feed}}\noutputs:\n  fabric:\n    prefix: volatile/site-a/stream/processors\n    layout: batch\n    heartbeat_ms: 1000\nstatus_file: {}\napi:\n  enabled: false\n",
        repo().join("packs").display(),
        d.join("status.json").display()
    );
    std::fs::write(d.join("r.yaml"), cfg).unwrap();
    let ok = bin().args(["config", "check", "-c"]).arg(d.join("r.yaml")).output().unwrap();
    assert!(ok.status.success(), "{}", String::from_utf8_lossy(&ok.stdout));
    let mut child = bin().args(["run", "-c"]).arg(d.join("r.yaml")).stderr(Stdio::null()).spawn().unwrap();

    let deadline = Instant::now() + Duration::from_secs(30);
    let mut keys = std::collections::BTreeSet::new();
    let mut joined = false;
    let mut i = 0;
    while Instant::now() < deadline && !(joined && keys.contains("volatile/site-a/stream/processors/quality")) {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as i64;
        for (src, dlat) in [("radar-1", 0.0), ("radar-2", 0.0001)] {
            let r = format!("{{\"track.source_id\":\"{src}\",\"uid\":\"T1\",\"time_ms\":{now},\"lat\":{},\"lon\":1.0,\"ce\":30.0,\"type\":\"a-f-A\"}}", 1.0 + dlat + i as f64 * 1e-5);
            z.put(format!("data/entity/track/s/{src}/T1"), r).wait().unwrap();
        }
        i += 1;
        std::thread::sleep(Duration::from_millis(200));
        while let Ok(Some(s)) = got.try_recv() {
            let key = s.key_expr().as_str().to_string();
            if key.ends_with("/tracks") {
                let text = String::from_utf8_lossy(&s.payload().to_bytes()).to_string();
                // JSON lines: one system track per line, each with now_ms.
                for l in text.lines() {
                    let v = json::parse(l).unwrap();
                    assert!(v.get("now_ms").is_some(), "{l}");
                    joined |= v.get("members").map(|m| m.to_string()) == Some("[\"radar-1/T1\",\"radar-2/T1\"]".into());
                }
            }
            keys.insert(key);
        }
    }
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(joined, "no system track joined the two sources: {keys:?}");
    // Only fixed keys: no key per track and none per quality subject.
    for k in &keys {
        assert!(
            ["volatile/site-a/stream/processors/tracks", "volatile/site-a/stream/processors/quality"].contains(&k.as_str())
                || k.starts_with("volatile/site-a/stream/processors/events/"),
            "a key outside the fixed set: {k}"
        );
    }
}
