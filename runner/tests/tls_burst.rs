//! A burst of input over a mutual TLS fabric link, while the runner publishes
//! on the same link: every message is read, and the runner is still running.
//! Without runner/vendor (eclipse-zenoh/zenoh#2910) the TLS link could stop
//! reading part of the burst, or crash the process. Needs `openssl`.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use goat_correlator::json;
use zenoh::Wait;

const BURST: u64 = 5000;

fn openssl(args: &[&str], dir: &Path) {
    assert!(Command::new("openssl").args(args).current_dir(dir).stderr(Stdio::null()).status().expect("openssl runs").success(), "openssl {args:?}");
}

/// A test CA, and one certificate for `localhost` for both ends of the link.
fn certs(dir: &Path) {
    openssl(&["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca.key"], dir);
    openssl(&["req", "-x509", "-new", "-key", "ca.key", "-sha256", "-days", "2", "-subj", "/CN=test-ca", "-out", "ca.pem", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"], dir);
    openssl(&["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", "end.key"], dir);
    openssl(&["req", "-new", "-key", "end.key", "-subj", "/CN=localhost", "-out", "end.csr"], dir);
    std::fs::write(dir.join("end.ext"), "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth,clientAuth\n").unwrap();
    openssl(&["x509", "-req", "-in", "end.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", "2", "-sha256", "-extfile", "end.ext", "-out", "end.pem"], dir);
}

/// The service under test, stopped when the test ends.
struct Service(std::process::Child);

impl Drop for Service {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn a_burst_over_mutual_tls_is_read_whole() {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("tls-burst");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    certs(&dir);
    let d = dir.display();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();

    // The other end of the link: a router in this process.
    let mut zc = zenoh::Config::default();
    for (k, v) in [
        ("mode", "\"router\"".to_string()),
        ("listen/endpoints", format!("[\"tls/localhost:{port}\"]")),
        ("scouting/multicast/enabled", "false".into()),
        ("transport/link/tls/root_ca_certificate", format!("\"{d}/ca.pem\"")),
        ("transport/link/tls/enable_mtls", "true".into()),
        ("transport/link/tls/listen_certificate", format!("\"{d}/end.pem\"")),
        ("transport/link/tls/listen_private_key", format!("\"{d}/end.key\"")),
    ] {
        zc.insert_json5(k, &v).unwrap();
    }
    let z = zenoh::open(zc).wait().unwrap();
    let received = Arc::new(AtomicU64::new(0));
    let r2 = received.clone();
    let _sub = z.declare_subscriber("volatile/localhost/**").callback(move |_| { r2.fetch_add(1, Ordering::Relaxed); }).wait().unwrap();

    // One tick, and so output on the link, per message: input clock, a second apart.
    std::fs::write(
        dir.join("r.yaml"),
        format!(
            "name: burst\nsite: s\npacks_dir: {packs}\ntick_ms: 1000\nclock: input\nfabric:\n  mode: client\n  connect: [\"tls/localhost:{port}\"]\n  tls:\n    root_ca: {d}/ca.pem\n    certificate: {d}/end.pem\n    private_key: {d}/end.key\ninputs:\n  fabric:\n    keys: [\"in/reports\"]\npipeline:\n  - {{function: correlate, pack: correlate-gnn}}\n  - {{function: fuse, pack: fuse-independent}}\noutputs:\n  fabric:\n    peer: localhost\n    heartbeat_ms: 1000\nstatus_file: {d}/status.json\napi:\n  enabled: false\n",
            packs = Path::new(env!("CARGO_MANIFEST_DIR")).join("../packs").canonicalize().unwrap().display(),
        ),
    )
    .unwrap();
    let mut service = Service(Command::new(env!("CARGO_BIN_EXE_goat-processors")).args(["run", "-c"]).arg(dir.join("r.yaml")).stdout(Stdio::null()).spawn().unwrap());
    let pub_ = z.declare_publisher("in/reports").congestion_control(zenoh::qos::CongestionControl::Block).wait().unwrap();
    let until = Instant::now() + Duration::from_secs(60);
    while !pub_.matching_status().wait().unwrap().matching() {
        assert!(Instant::now() < until, "the runner did not subscribe over TLS");
        std::thread::sleep(Duration::from_millis(50));
    }
    let start = Instant::now();
    for i in 0..BURST {
        let t = 1_000_000 + i * 1000;
        pub_.put(format!("{{\"track.source_id\":\"radar-1\",\"uid\":\"T{}\",\"time_ms\":{t},\"lat\":50.0,\"lon\":10.0,\"ce\":50}}", i % 4)).wait().unwrap();
    }
    let reports_in = || -> u64 {
        let text = std::fs::read_to_string(dir.join("status.json")).unwrap_or_default();
        json::parse(&text).ok().and_then(|s| s.get("counters")?.get("reports_in")?.as_i64()).unwrap_or(0) as u64
    };
    // The status is written on a tick, so it can be one message behind.
    let until = start + Duration::from_secs(60);
    while reports_in() + 1 < BURST {
        assert!(service.0.try_wait().unwrap().is_none(), "the runner stopped after {} of {BURST} messages", reports_in());
        assert!(Instant::now() < until, "the runner read {} of {BURST} messages in 60 s", reports_in());
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(service.0.try_wait().unwrap().is_none(), "the runner stopped");
    println!("read {} of {BURST} in {:.1} s; {} values came back", reports_in(), start.elapsed().as_secs_f64(), received.load(Ordering::Relaxed));
    assert!(received.load(Ordering::Relaxed) > 0, "no output came back over TLS");
}
