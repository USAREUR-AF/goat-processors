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
        .replace("tls/CHANGE-ME-router:7447", router)
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
fn doctor_reports_a_missing_service() {
    let d = tmp("doctor");
    let cfg = shipped_with("site-a", "tcp/127.0.0.1:1").replace("  tls:\n    root_ca: /etc/goat-processors/tls/ca.pem\n    certificate: /etc/goat-processors/tls/runner.pem\n    private_key: /etc/goat-processors/tls/runner.key\n", "")
        + &format!("status_file: {}\n", d.join("status.json").display());
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
        "name: t\nsite: s\npacks_dir: {}\ntick_ms: 1000\nclock: input\ninputs:\n  file:\n    path: {}\n    speed: 0\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\n  - {{function: fuse, pack: fuse-independent}}\n  - {{function: quality, pack: quality-feed}}\noutputs:\n  file:\n    path: {}\n    trace: true\nrecord:\n  path: {}\nstatus_file: {}\n",
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
        "name: t\nsite: s\npacks_dir: {}\ntick_ms: 200\nfabric:\n  mode: peer\n  connect: [\"tcp/127.0.0.1:{port}\"]\ninputs:\n  fabric:\n    keys: [\"data/entity/track/**\"]\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\n  - {{function: quality, pack: quality-feed}}\noutputs:\n  fabric: {{}}\nstatus_file: {}\n",
        repo().join("packs").display(),
        d.join("status.json").display()
    );
    std::fs::write(d.join("r.yaml"), cfg).unwrap();
    let mut child = bin().args(["run", "-c"]).arg(d.join("r.yaml")).stderr(Stdio::null()).spawn().unwrap();

    // Two sources report one object near the wall clock, every 200 ms.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut keys = std::collections::BTreeSet::new();
    let mut i = 0;
    while Instant::now() < deadline && !(keys.iter().any(|k: &String| k.contains("/tracks/")) && keys.iter().any(|k| k.contains("/quality/"))) {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as i64;
        for (src, dlat) in [("radar-1", 0.0), ("adsb", 0.0001)] {
            let r = format!("{{\"track.source_id\":\"{src}\",\"uid\":\"T1\",\"time_ms\":{now},\"lat\":{},\"lon\":1.0,\"ce\":30.0,\"type\":\"a-f-A\"}}", 1.0 + dlat + i as f64 * 1e-5);
            z.put(format!("data/entity/track/s/{src}/T1"), r).wait().unwrap();
        }
        i += 1;
        std::thread::sleep(Duration::from_millis(200));
        while let Ok(Some(s)) = got.try_recv() {
            keys.insert(s.key_expr().as_str().to_string());
        }
    }
    child.kill().unwrap();
    child.wait().unwrap();
    assert!(keys.iter().any(|k| k.starts_with("data/processed/s/t/tracks/")), "{keys:?}");
    assert!(keys.iter().any(|k| k.starts_with("data/processed/s/t/quality/entity/")), "{keys:?}");
    assert!(keys.contains("data/processed/s/t/events/correlate"), "{keys:?}");
    let st = json::parse(&std::fs::read_to_string(d.join("status.json")).unwrap()).unwrap();
    assert!(st.get("counters").unwrap().get("per_source").unwrap().get("adsb").is_some());
}
