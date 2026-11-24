//! The volume test: what the runner sends and keeps for N objects, at the
//! shipped defaults, against the budget in `runner/volume/budget.json`.
//!
//! For each N (50 and 200 by default; `GP_VOLUME_SIZES=50,200,1000` for
//! more), `runner/volume/scenario.py` writes N objects seen by a radar and a
//! beacon for `GP_VOLUME_SECONDS` (default 120) seconds. The service plays it
//! from a file on the input clock as fast as it can (`speed: 0`), with the
//! shipped fabric output (batch layout, trace off) to a fabric peer this test
//! runs, plus `outputs.file` and `record` at their defaults (events only). The
//! test counts every value and byte the peer receives per key, reads the
//! service's peak resident memory from /proc, and the size of the two files.
//!
//! Ignored by `cargo test`: it takes about a minute at 200 objects. CI runs
//! it as its own job: `cargo test --release --test volume -- --ignored --nocapture`.
//! Each run writes `target/volume/results.json` and prints a table.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use goat_correlator::json::{self, Json};
use zenoh::Wait;

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").canonicalize().unwrap()
}

/// What one run measured.
#[derive(Default, Debug, Clone)]
struct Measured {
    objects: u64,
    reports: u64,
    seconds: u64,
    /// key (after the prefix) -> (values, bytes) received by the peer
    keys: BTreeMap<String, (u64, u64)>,
    published: u64,
    peak_rss_kb: u64,
    file_bytes: u64,
    record_bytes: u64,
    wall_s: f64,
}

impl Measured {
    fn values(&self) -> u64 {
        self.keys.values().map(|v| v.0).sum()
    }
    fn bytes(&self) -> u64 {
        self.keys.values().map(|v| v.1).sum()
    }
    /// The quantities the budget bounds.
    fn metrics(&self) -> BTreeMap<&'static str, f64> {
        let r = self.reports.max(1) as f64;
        let s = self.seconds.max(1) as f64;
        BTreeMap::from([
            ("fabric_bytes_per_report", self.bytes() as f64 / r),
            ("fabric_values_per_s", self.values() as f64 / s),
            ("fabric_bytes_per_s", self.bytes() as f64 / s),
            ("peak_rss_mb", self.peak_rss_kb as f64 / 1024.0),
            ("disk_mb_per_input_hour", (self.file_bytes + self.record_bytes) as f64 / 1048576.0 * 3600.0 / s),
        ])
    }
    fn to_json(&self) -> Json {
        let mut m = json::Map::new();
        for (k, v) in [("objects", self.objects), ("reports", self.reports), ("seconds", self.seconds), ("published", self.published), ("peak_rss_kb", self.peak_rss_kb), ("file_bytes", self.file_bytes), ("record_bytes", self.record_bytes)] {
            m.insert(k.into(), Json::Int(v as i64));
        }
        m.insert("wall_s".into(), Json::Num((self.wall_s * 10.0).round() / 10.0));
        let mut keys = json::Map::new();
        for (k, (n, b)) in &self.keys {
            let mut e = json::Map::new();
            e.insert("values".into(), Json::Int(*n as i64));
            e.insert("bytes".into(), Json::Int(*b as i64));
            keys.insert(k.clone().into(), Json::Obj(e));
        }
        m.insert("keys".into(), Json::Obj(keys));
        let mut met = json::Map::new();
        for (k, v) in self.metrics() {
            met.insert(k.into(), Json::Num((v * 100.0).round() / 100.0));
        }
        m.insert("metrics".into(), Json::Obj(met));
        Json::Obj(m)
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn vm_hwm_kb(pid: u32) -> Option<u64> {
    let s = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    s.lines().find(|l| l.starts_with("VmHWM:"))?.split_whitespace().nth(1)?.parse().ok()
}

fn run(objects: u64, seconds: u64, dir: &Path) -> Measured {
    // The input.
    let input = dir.join("input.json");
    let gen = Command::new("python3")
        .arg("-I")
        .arg(repo().join("runner/volume/scenario.py"))
        .args([objects.to_string(), seconds.to_string()])
        .arg(&input)
        .output()
        .expect("python3 runs the scenario generator");
    assert!(gen.status.success(), "{}", String::from_utf8_lossy(&gen.stderr));
    let reports = json::parse(&std::fs::read_to_string(&input).unwrap()).unwrap().get("steps").and_then(|s| match s {
        Json::Arr(a) => Some(a.iter().filter(|x| x.get("ingest").is_some()).count() as u64),
        _ => None,
    });
    let reports = reports.unwrap();

    // The fabric peer that receives everything the runner publishes.
    let port = free_port();
    let mut zc = zenoh::Config::default();
    zc.insert_json5("mode", "\"peer\"").unwrap();
    zc.insert_json5("listen/endpoints", &format!("[\"tcp/127.0.0.1:{port}\"]")).unwrap();
    zc.insert_json5("scouting/multicast/enabled", "false").unwrap();
    let z = zenoh::open(zc).wait().unwrap();
    let prefix = "volatile/s/stream/processors/vol";
    let keys: Arc<Mutex<BTreeMap<String, (u64, u64)>>> = Arc::default();
    let k2 = keys.clone();
    let _sub = z
        .declare_subscriber(format!("{prefix}/**"))
        .callback(move |s| {
            let k = s.key_expr().as_str().trim_start_matches(prefix).trim_start_matches('/').to_string();
            let mut m = k2.lock().unwrap();
            let e = m.entry(k).or_insert((0, 0));
            e.0 += 1;
            e.1 += s.payload().len() as u64;
        })
        .wait()
        .unwrap();

    // The service, at the shipped defaults but for the input and the files.
    let cfg = format!(
        "name: vol\nsite: s\npacks_dir: {packs}\ntick_ms: 1000\nclock: input\nfabric:\n  mode: peer\n  connect: [\"tcp/127.0.0.1:{port}\"]\ninputs:\n  file:\n    path: {input}\n    speed: 0\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\n  - {{function: quality, pack: quality-feed}}\noutputs:\n  fabric:\n    trace: false\n  file:\n    path: {d}/out.jsonl\nrecord:\n  path: {d}/record.jsonl\nstatus_file: {d}/status.json\napi:\n  enabled: false\n",
        packs = repo().join("packs").display(),
        input = input.display(),
        d = dir.display(),
    );
    std::fs::write(dir.join("r.yaml"), cfg).unwrap();
    let start = Instant::now();
    let mut child = Command::new(env!("CARGO_BIN_EXE_goat-processors")).args(["run", "-c"]).arg(dir.join("r.yaml")).stdout(Stdio::null()).stderr(Stdio::piped()).spawn().unwrap();
    let pid = child.id();
    let (tx, rx) = std::sync::mpsc::channel();
    let stderr = child.stderr.take().unwrap();
    std::thread::spawn(move || {
        for l in BufReader::new(stderr).lines().map_while(Result::ok) {
            if l.contains("every input has ended") {
                let _ = tx.send(());
            }
        }
    });
    let mut peak = 0;
    let deadline = Instant::now() + Duration::from_secs(1800);
    loop {
        peak = peak.max(vm_hwm_kb(pid).unwrap_or(0));
        if rx.recv_timeout(Duration::from_millis(100)).is_ok() {
            break;
        }
        assert!(Instant::now() < deadline, "the service did not finish the input in 30 minutes");
        assert!(child.try_wait().unwrap().is_none(), "the service stopped");
    }
    let wall_s = start.elapsed().as_secs_f64();
    // Let the last values reach the peer, then read the service's state.
    std::thread::sleep(Duration::from_millis(1500));
    peak = peak.max(vm_hwm_kb(pid).unwrap_or(0));
    let status = json::parse(&std::fs::read_to_string(dir.join("status.json")).unwrap()).unwrap();
    let counter = |k: &str| status.get("counters").and_then(|c| c.get(k)).and_then(|v| v.as_i64()).unwrap_or(0) as u64;
    assert_eq!(counter("reports_in"), reports, "every report reached the service");
    let published = counter("published");
    let _ = child.kill();
    let _ = child.wait();
    let size = |p: &str| std::fs::metadata(dir.join(p)).map(|m| m.len()).unwrap_or(0);
    let keys = keys.lock().unwrap().clone();
    Measured { objects, reports, seconds, keys, published, peak_rss_kb: peak, file_bytes: size("out.jsonl"), record_bytes: size("record.jsonl"), wall_s }
}

#[test]
#[ignore = "the volume test runs as its own CI job (about a minute)"]
fn volume_within_the_budget() {
    let sizes: Vec<u64> = std::env::var("GP_VOLUME_SIZES").unwrap_or("50,200".into()).split(',').map(|s| s.trim().parse().unwrap()).collect();
    let seconds: u64 = std::env::var("GP_VOLUME_SECONDS").ok().and_then(|s| s.parse().ok()).unwrap_or(120);
    let budget = json::parse(&std::fs::read_to_string(repo().join("runner/volume/budget.json")).unwrap()).unwrap();
    let out_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/volume");
    std::fs::create_dir_all(&out_dir).unwrap();

    let mut results = Vec::new();
    let mut over = Vec::new();
    println!("\n| objects | reports | fabric values/s | fabric bytes/report | fabric bytes/s | peak memory MB | disk MB per input hour | wall s |");
    println!("|---|---|---|---|---|---|---|---|");
    for n in sizes {
        let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("volume-{n}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let m = run(n, seconds, &dir);
        let met = m.metrics();
        println!(
            "| {n} | {} | {:.1} | {:.1} | {:.0} | {:.0} | {:.1} | {:.1} |",
            m.reports, met["fabric_values_per_s"], met["fabric_bytes_per_report"], met["fabric_bytes_per_s"], met["peak_rss_mb"], met["disk_mb_per_input_hour"], m.wall_s
        );
        println!("|   | keys: {} | published {} values, received {} |", m.keys.iter().map(|(k, (v, b))| format!("{k} {v} values {b} B")).collect::<Vec<_>>().join("; "), m.published, m.values());
        // Only the fixed key set reaches the fabric.
        for k in m.keys.keys() {
            assert!(["tracks", "quality", "events", "status", "trace"].contains(&k.as_str()), "a key outside the fixed set: {k}");
        }
        assert!(!m.keys.contains_key("trace"), "the trace is off by default");
        match budget.get("sizes").and_then(|s| s.get(&n.to_string())) {
            Some(b) => {
                for (k, v) in &met {
                    let Some(limit) = b.get(k).and_then(|x| x.as_f64()) else { continue };
                    if *v > limit {
                        over.push(format!("{n} objects: {k} {v:.2} > budget {limit}"));
                    }
                }
            }
            None => over.push(format!("{n} objects: runner/volume/budget.json has no budget for this size")),
        }
        results.push(m.to_json());
    }
    let mut all = json::Map::new();
    all.insert("seconds".into(), Json::Int(seconds as i64));
    all.insert("runs".into(), Json::Arr(results));
    std::fs::write(out_dir.join("results.json"), Json::Obj(all).to_string()).unwrap();
    assert!(over.is_empty(), "over the volume budget (runner/volume/budget.json):\n  {}", over.join("\n  "));
}
