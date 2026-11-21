//! The API and the CLI verbs, against a running service: every route, the
//! roles, the audit log, and a recorded run with a pack change that replays
//! to the same output.

use std::io::{Read, Write};
use std::net::{TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
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

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as i64
}

struct Service {
    child: Child,
    dir: PathBuf,
    api: String,
    udp: String,
}

impl Drop for Service {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Service {
    fn start(name: &str, extra: &str) -> Service {
        let dir = tmp(name);
        let api = format!("127.0.0.1:{}", free_port());
        let udp = format!("127.0.0.1:{}", free_port());
        let cfg = format!(
            "name: t\nsite: s\npacks_dir: {packs}\ntick_ms: 200\ninputs:\n  udp:\n    - listen: \"{udp}\"\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\n  - {{function: quality, pack: quality-feed}}\noutputs:\n  file:\n    path: {d}/out.jsonl\n    trace: true\nrecord:\n  path: {d}/record.jsonl\nstatus_file: {d}/status.json\napi:\n  listen: \"{api}\"\n  token_file: {d}/api.token\n  audit_file: {d}/audit.jsonl\n{extra}",
            packs = repo().join("packs").display(),
            d = dir.display(),
        );
        std::fs::write(dir.join("r.yaml"), cfg).unwrap();
        let check = bin().args(["config", "check", "-c"]).arg(dir.join("r.yaml")).output().unwrap();
        assert!(check.status.success(), "{}", String::from_utf8_lossy(&check.stdout));
        let child = bin().args(["run", "-c"]).arg(dir.join("r.yaml")).stderr(Stdio::null()).spawn().unwrap();
        let s = Service { child, dir, api, udp };
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if let Ok((200, _)) = s.raw("GET", "/v1/health", None, None) {
                return s;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        panic!("the service did not become healthy");
    }

    fn token(&self) -> String {
        std::fs::read_to_string(self.dir.join("api.token")).unwrap()
    }

    fn raw(&self, method: &str, path: &str, token: Option<&str>, body: Option<&str>) -> Result<(u16, String), String> {
        let mut s = TcpStream::connect(&self.api).map_err(|e| e.to_string())?;
        let body = body.unwrap_or("");
        let auth = token.map(|t| format!("Authorization: Bearer {t}\r\n")).unwrap_or_default();
        write!(s, "{method} {path} HTTP/1.1\r\nHost: x\r\n{auth}Content-Length: {}\r\n\r\n{body}", body.len()).map_err(|e| e.to_string())?;
        let mut out = String::new();
        s.read_to_string(&mut out).map_err(|e| e.to_string())?;
        let status = out.split(' ').nth(1).and_then(|c| c.parse().ok()).ok_or("no status")?;
        let body = out.split_once("\r\n\r\n").map(|(_, b)| b.to_string()).unwrap_or_default();
        Ok((status, body))
    }

    fn get(&self, path: &str) -> Json {
        let (st, b) = self.raw("GET", path, None, None).unwrap();
        assert_eq!(st, 200, "{path}: {b}");
        json::parse(&b).unwrap()
    }

    fn cli(&self, args: &[&str]) -> (bool, String) {
        let out = bin().args(args).args(["-c"]).arg(self.dir.join("r.yaml")).output().unwrap();
        (out.status.success(), format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)))
    }

    /// Two sources report one object, `n` times, 200 ms apart.
    fn feed(&self, n: usize) {
        let sock = UdpSocket::bind("127.0.0.1:0").unwrap();
        for i in 0..n {
            let t = now_ms();
            for (src, d) in [("radar-1", 0.0), ("adsb", 0.00005)] {
                let r = format!(
                    "{{\"track.source_id\":\"{src}\",\"uid\":\"T1\",\"time_ms\":{t},\"lat\":{},\"lon\":1.0,\"ce\":30.0,\"course\":0.0,\"speed_ms\":11.0,\"type\":\"a-f-S\"}}",
                    1.0 + d + i as f64 * 2e-5
                );
                sock.send_to(r.as_bytes(), &self.udp).unwrap();
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        std::thread::sleep(Duration::from_millis(500));
    }

    fn audit(&self) -> Vec<Json> {
        std::fs::read_to_string(self.dir.join("audit.jsonl")).unwrap_or_default().lines().map(|l| json::parse(l).unwrap()).collect()
    }
}

fn s<'a>(v: &'a Json, k: &str) -> &'a str {
    v.get(k).and_then(|x| x.as_str()).unwrap_or("")
}

#[test]
fn every_route_and_verb() {
    let svc = Service::start("api-routes", "");
    svc.feed(15);
    let token = svc.token();

    // status, health, pipeline, packs, metrics, routes
    let st = svc.get("/v1/status");
    assert_eq!(s(&st, "state"), "running");
    assert!(st.get("counters").unwrap().get("per_source").unwrap().get("adsb").is_some());
    assert_eq!(svc.get("/v1/health").get("healthy"), Some(&Json::Bool(true)));
    let p = svc.get("/v1/pipeline");
    assert_eq!(s(&p.as_array().unwrap()[0], "pack"), "correlate-assign-time");
    let packs = svc.get("/v1/packs");
    assert!(packs.as_array().unwrap().iter().any(|x| s(x, "pack") == "quality-time"));
    let m = svc.get("/v1/metrics");
    assert!(m.get("reports_in").unwrap().as_i64().unwrap() >= 30);
    assert!(m.get("processing_us").unwrap().get("p99").is_some());
    assert!(svc.get("/v1/routes").as_array().unwrap().len() >= 13);
    let (st, prom) = svc.raw("GET", "/v1/metrics/prometheus", None, None).unwrap();
    assert_eq!(st, 200, "{prom}");
    assert!(prom.contains("goat_processors_up 1"), "{prom}");
    assert!(prom.contains("goat_processors_reports_in_total{source=\"adsb\"}"), "{prom}");
    assert!(prom.contains("# TYPE goat_processors_system_tracks_multi_source gauge"), "{prom}");
    assert!(prom.contains("goat_processors_events_total{function=\"correlate\""), "{prom}");
    // quality events about a source are labeled with each measure they carry, never empty
    assert!(!prom.contains("ev=\"quality\",what=\"\""), "a quality event counted with an empty measure label: {prom}");
    assert!(
        prom.lines().any(|l| l.starts_with("goat_processors_quality_source_events_total{") && l.contains("ev=\"quality\",what=\"") && !l.contains("what=\"\"")),
        "no quality event counted under a measure name: {prom}"
    );

    // tracks and explain: the two sources are one system track, explained by its trace
    let tr = svc.get("/v1/tracks");
    let tracks = tr.get("tracks").unwrap().as_array().unwrap().clone();
    let joined = tracks.iter().find(|t| t.get("members").map(|m| m.to_string()) == Some("[\"adsb/T1\",\"radar-1/T1\"]".into())).expect("a joined system track");
    let id = s(joined, "system").to_string();
    let ex = svc.get(&format!("/v1/explain/{id}"));
    assert!(!ex.get("trace").unwrap().as_array().unwrap().is_empty());
    assert!(ex.get("events").unwrap().as_array().unwrap().iter().any(|e| e.get("event").and_then(|x| x.get("ev")).and_then(|x| x.as_str()) == Some("join") || e.get("event").and_then(|x| x.get("ev")).and_then(|x| x.as_str()) == Some("start")));
    assert_eq!(svc.raw("GET", "/v1/explain/nope", None, None).unwrap().0, 404);

    // replay through the API equals the offline replay of the same file
    let vector = repo().join("packs/correlate-assign-time/vectors/56-assign-time-offset-fit.json");
    let body = std::fs::read_to_string(&vector).unwrap();
    let (st_code, online) = svc.raw("POST", "/v1/replay", None, Some(&body)).unwrap();
    assert_eq!(st_code, 200);
    let (ok, offline) = svc.cli(&["replay", vector.to_str().unwrap()]);
    assert!(ok);
    let offline: String = offline.lines().filter(|l| l.starts_with('{')).map(|l| format!("{l}\n")).collect();
    assert_eq!(online, offline);

    // roles: without the token, a change is refused and audited
    let (code, b) = svc.raw("POST", "/v1/stop", None, None).unwrap();
    assert_eq!(code, 403, "{b}");
    assert!(b.contains("run the command with sudo"));
    assert!(svc.audit().iter().any(|a| s(a, "path") == "/v1/stop" && a.get("status").and_then(|x| x.as_i64()) == Some(403) && s(a, "who") == "local"));
    assert_eq!(svc.raw("GET", "/v1/audit", None, None).unwrap().0, 403);
    assert_eq!(svc.raw("DELETE", "/v1/status", None, None).unwrap().0, 405);
    assert_eq!(svc.raw("GET", "/v2/status", None, None).unwrap().0, 404);

    // CLI verbs (the token file is readable by this user, as by root on a site)
    for (verb, want) in [
        (vec!["status"], "running"),
        (vec!["health"], "true"),
        (vec!["pipeline"], "correlate-assign-time"),
        (vec!["metrics"], "reports_per_second"),
        (vec!["tracks"], "radar-1/T1"),
        (vec!["explain", id.as_str()], "trace records"),
    ] {
        let (ok, out) = svc.cli(&verb);
        assert!(ok, "{verb:?}: {out}");
        assert!(out.contains(want), "{verb:?}: want {want:?} in {out}");
    }
    let (ok, out) = svc.cli(&["status", "-o", "json"]);
    assert!(ok && json::parse(out.trim()).is_ok(), "{out}");

    // pack use: quality switches packs; the pipeline shows it differs from the file
    let (ok, out) = svc.cli(&["pack", "use", "quality", "quality-time"]);
    assert!(ok, "{out}");
    assert!(out.contains("quality-time") && out.contains("(config file: quality-feed)"), "{out}");
    let (ok, out) = svc.cli(&["pack", "use", "quality", "correlate-gnn"]);
    assert!(!ok && out.contains("is not a quality pack"), "{out}");
    let (ok, out) = svc.cli(&["pack", "use", "fuse", "fuse-best"]);
    assert!(!ok && out.contains("no fuse stage"), "{out}");
    svc.feed(5);

    // stop and start
    let (ok, out) = svc.cli(&["stop"]);
    assert!(ok && out.contains("paused"), "{out}");
    assert_eq!(svc.raw("GET", "/v1/health", None, None).unwrap().0, 503);
    svc.feed(3);
    let st = svc.get("/v1/status");
    assert!(st.get("counters").unwrap().get("dropped_paused").unwrap().as_i64().unwrap() >= 6);
    let (ok, out) = svc.cli(&["start"]);
    assert!(ok && out.contains("running"), "{out}");
    svc.feed(3);

    // audit: every change, with its identity
    let (ok, out) = svc.cli(&["audit"]);
    assert!(ok, "{out}");
    let audit = svc.audit();
    for path in ["/v1/pipeline/quality", "/v1/stop", "/v1/start"] {
        assert!(audit.iter().any(|a| s(a, "path") == path && s(a, "who") == "local-admin" && a.get("status").and_then(|x| x.as_i64()) == Some(200)), "{path} not audited: {audit:?}");
    }
    assert!(audit.iter().any(|a| s(a, "path") == "/v1/pipeline/quality" && a.get("body").map(|b| b.to_string()).unwrap_or_default().contains("quality-time")));
    let _ = token;

    // the recorded run, with its pack change, replays to the same output
    let replay = bin().arg("replay").arg(svc.dir.join("record.jsonl")).args(["--trace", "-c"]).arg(svc.dir.join("r.yaml")).output().unwrap();
    assert!(replay.status.success());
    let out_file = std::fs::read_to_string(svc.dir.join("out.jsonl")).unwrap();
    let replayed: Vec<String> = String::from_utf8(replay.stdout).unwrap().lines().filter(|l| !l.contains("\"call\":\"pack\"")).map(str::to_string).collect();
    // The service is still running, so the two files were read at different
    // moments: compare the part both hold.
    let served: Vec<&str> = out_file.lines().collect();
    let n = served.len().min(replayed.len());
    assert!(n > 50, "only {n} lines to compare");
    assert_eq!(&replayed[..n], &served[..n]);
    assert!(std::fs::read_to_string(svc.dir.join("record.jsonl")).unwrap().contains("{\"pack\":{\"function\":\"quality\",\"pack\":\"quality-time\"}}"));

    // explain --html: the step-by-step page of the recorded run, naming the
    // track and its members (asked of the running service)
    let page = svc.dir.join("explain.html");
    let (ok, out) = svc.cli(&["explain", id.as_str(), "--html", page.to_str().unwrap()]);
    assert!(ok, "{out}");
    let html = std::fs::read_to_string(&page).unwrap();
    assert!(html.contains("through its correlate stage") && html.contains("radar-1/T1") && html.contains(&format!("look for {id}")), "page note");
    assert!(html.contains("\"snapshot\":{"), "a snapshot per step");
    let (ok, out) = svc.cli(&["explain", id.as_str(), "--html", page.to_str().unwrap(), "--stage", "quality"]);
    assert!(ok && std::fs::read_to_string(&page).unwrap().contains("through its quality stage"), "{out}");
    let (ok, out) = svc.cli(&["explain", id.as_str(), "--html", page.to_str().unwrap(), "--stage", "fuse"]);
    assert!(!ok && out.contains("no fuse stage"), "{out}");

    // replay --html: the same page from any file, without a service
    let page2 = svc.dir.join("replay.html");
    let out = bin().arg("replay").arg(svc.dir.join("record.jsonl")).args(["-c"]).arg(svc.dir.join("r.yaml")).arg("--html").arg(&page2).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(out.stdout.is_empty(), "the page goes to the file, not stdout");
    assert!(std::fs::read_to_string(&page2).unwrap().contains("through its correlate stage"));
}

#[test]
fn openapi_documents_every_route() {
    let svc = Service::start("api-openapi", "");
    let routes = svc.get("/v1/routes");
    let doc = std::fs::read_to_string(repo().join("runner/openapi.yaml")).unwrap();
    // paths are keys at two spaces; methods at four.
    let mut documented = Vec::new();
    let mut path = String::new();
    for l in doc.lines() {
        if l.starts_with("  /") && l.ends_with(':') {
            path = l.trim().trim_end_matches(':').to_string();
        } else if let Some(m) = ["get", "put", "post", "delete"].iter().find(|m| l == &format!("    {m}:")) {
            documented.push(format!("{} {}", m.to_uppercase(), path));
        }
    }
    let mut served: Vec<String> = routes.as_array().unwrap().iter().map(|r| format!("{} {}", s(r, "method"), s(r, "path"))).collect();
    served.sort();
    documented.sort();
    assert_eq!(served, documented, "runner/openapi.yaml and the served routes differ");
}

fn openssl(args: &[&str], dir: &Path) {
    let st = Command::new("openssl").args(args).current_dir(dir).stderr(Stdio::null()).status().unwrap();
    assert!(st.success(), "openssl {args:?}");
}

fn curl(dir: &Path, port: u16, who: Option<&str>, method: &str, path: &str) -> (String, String) {
    let mut c = Command::new("curl");
    c.current_dir(dir).args(["-s", "-o", "body.txt", "-w", "%{http_code}", "--cacert", "ca.pem", "-X", method]);
    if let Some(w) = who {
        c.args(["--cert", &format!("{w}.pem"), "--key", &format!("{w}.key")]);
    }
    if method == "PUT" {
        c.args(["-d", "{\"pack\":\"quality-time\"}"]);
    }
    c.arg(format!("https://localhost:{port}{path}"));
    let out = c.output().unwrap();
    (String::from_utf8_lossy(&out.stdout).to_string(), std::fs::read_to_string(dir.join("body.txt")).unwrap_or_default())
}

#[test]
fn mesh_api_needs_an_allowed_certificate() {
    if Command::new("openssl").arg("version").output().is_err() || Command::new("curl").arg("--version").output().is_err() {
        eprintln!("skipped: openssl or curl missing");
        return;
    }
    let certs = tmp("api-mesh-certs");
    openssl(&["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca.key"], &certs);
    openssl(&["req", "-x509", "-new", "-key", "ca.key", "-sha256", "-days", "2", "-subj", "/CN=test-ca", "-out", "ca.pem", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"], &certs);
    for who in ["server", "ops", "viewer", "stranger"] {
        openssl(&["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", &format!("{who}.key")], &certs);
        openssl(&["req", "-new", "-key", &format!("{who}.key"), "-subj", &format!("/CN={who}"), "-out", &format!("{who}.csr")], &certs);
        std::fs::write(certs.join(format!("{who}.ext")), "subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\n").unwrap();
        openssl(&["x509", "-req", "-in", &format!("{who}.csr"), "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", "2", "-sha256", "-extfile", &format!("{who}.ext"), "-out", &format!("{who}.pem")], &certs);
    }
    let port = free_port();
    let extra = format!(
        "  mesh:\n    listen: \"127.0.0.1:{port}\"\n    tls:\n      root_ca: {c}/ca.pem\n      certificate: {c}/server.pem\n      private_key: {c}/server.key\n    allow:\n      - {{name: ops, role: operate}}\n      - {{name: viewer, role: read}}\n",
        c = certs.display()
    );
    let svc = Service::start("api-mesh", &extra);
    let (code, _) = curl(&certs, port, Some("viewer"), "GET", "/v1/status");
    assert_eq!(code, "200");
    let (code, body) = curl(&certs, port, Some("viewer"), "PUT", "/v1/pipeline/quality");
    assert_eq!(code, "403", "{body}");
    let (code, body) = curl(&certs, port, Some("stranger"), "GET", "/v1/status");
    assert_eq!(code, "403", "{body}");
    assert!(body.contains("not in api.mesh.allow"));
    let (code, _) = curl(&certs, port, None, "GET", "/v1/status");
    assert_ne!(code, "200", "a caller without a certificate was answered");
    let (code, body) = curl(&certs, port, Some("ops"), "PUT", "/v1/pipeline/quality");
    assert_eq!(code, "200", "{body}");
    let audit = svc.audit();
    assert!(audit.iter().any(|a| s(a, "who") == "ops" && s(a, "via") == "mesh" && s(a, "path") == "/v1/pipeline/quality" && a.get("status").and_then(|x| x.as_i64()) == Some(200)));
    assert!(audit.iter().any(|a| s(a, "who") == "stranger" && a.get("status").and_then(|x| x.as_i64()) == Some(403)));
    assert!(audit.iter().any(|a| s(a, "who") == "viewer" && a.get("status").and_then(|x| x.as_i64()) == Some(403)));
}

#[test]
fn mesh_api_refuses_a_revoked_certificate_without_a_restart() {
    if Command::new("openssl").arg("version").output().is_err() || Command::new("curl").arg("--version").output().is_err() {
        eprintln!("skipped: openssl or curl missing");
        return;
    }
    let certs = tmp("api-mesh-crl-certs");
    openssl(&["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca.key"], &certs);
    openssl(&["req", "-x509", "-new", "-key", "ca.key", "-sha256", "-days", "2", "-subj", "/CN=test-ca", "-out", "ca.pem", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"], &certs);
    for who in ["server", "ops", "viewer"] {
        openssl(&["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", &format!("{who}.key")], &certs);
        openssl(&["req", "-new", "-key", &format!("{who}.key"), "-subj", &format!("/CN={who}"), "-out", &format!("{who}.csr")], &certs);
        std::fs::write(certs.join(format!("{who}.ext")), "subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\n").unwrap();
        openssl(&["x509", "-req", "-in", &format!("{who}.csr"), "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", "2", "-sha256", "-extfile", &format!("{who}.ext"), "-out", &format!("{who}.pem")], &certs);
    }
    // A minimal CA database, so that openssl can write revocation lists.
    std::fs::write(certs.join("ca.cnf"), "[ca]\ndefault_ca = d\n[d]\ndatabase = index.txt\ncrlnumber = crlnumber\ndefault_md = sha256\ndefault_crl_days = 2\n").unwrap();
    std::fs::write(certs.join("index.txt"), "").unwrap();
    std::fs::write(certs.join("crlnumber"), "01\n").unwrap();
    let gencrl = |dir: &Path| openssl(&["ca", "-config", "ca.cnf", "-keyfile", "ca.key", "-cert", "ca.pem", "-gencrl", "-out", "crl.pem"], dir);
    gencrl(&certs);
    let port = free_port();
    let extra = format!(
        "  mesh:\n    listen: \"127.0.0.1:{port}\"\n    tls:\n      root_ca: {c}/ca.pem\n      certificate: {c}/server.pem\n      private_key: {c}/server.key\n    crl: {c}/crl.pem\n    allow:\n      - {{name: ops, role: operate}}\n      - {{name: viewer, role: read}}\n",
        c = certs.display()
    );
    let _svc = Service::start("api-mesh-crl", &extra);
    assert_eq!(curl(&certs, port, Some("ops"), "GET", "/v1/status").0, "200", "an empty list refuses no one");
    // Revoke ops while the service runs.
    std::thread::sleep(Duration::from_millis(1100));
    openssl(&["ca", "-config", "ca.cnf", "-keyfile", "ca.key", "-cert", "ca.pem", "-revoke", "ops.pem"], &certs);
    gencrl(&certs);
    assert_ne!(curl(&certs, port, Some("ops"), "GET", "/v1/status").0, "200", "a revoked certificate was answered");
    assert_eq!(curl(&certs, port, Some("viewer"), "GET", "/v1/status").0, "200");
    // A list that no longer reads leaves the previous one in force.
    std::thread::sleep(Duration::from_millis(1100));
    std::fs::write(certs.join("crl.pem"), "not a list").unwrap();
    assert_ne!(curl(&certs, port, Some("ops"), "GET", "/v1/status").0, "200", "a bad list let a revoked certificate back in");
    assert_eq!(curl(&certs, port, Some("viewer"), "GET", "/v1/status").0, "200");
}

#[test]
fn metrics_port_serves_only_prometheus_text() {
    let port = free_port();
    let svc = Service::start("api-metrics-port", &format!("  metrics_listen: \"127.0.0.1:{port}\"\n"));
    svc.feed(5);
    let get = |method: &str, path: &str| -> (u16, String) {
        let mut s = TcpStream::connect(format!("127.0.0.1:{port}")).unwrap();
        write!(s, "{method} {path} HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n").unwrap();
        let mut out = String::new();
        s.read_to_string(&mut out).unwrap();
        let st = out.split(' ').nth(1).unwrap().parse().unwrap();
        (st, out.split_once("\r\n\r\n").map(|(_, b)| b.to_string()).unwrap_or_default())
    };
    let (st, body) = get("GET", "/metrics");
    assert_eq!(st, 200, "{body}");
    assert!(body.contains("# TYPE goat_processors_reports_in_total counter"), "{body}");
    // Nothing else is reachable on this port.
    assert_eq!(get("GET", "/v1/tracks").0, 404);
    assert_eq!(get("POST", "/v1/stop").0, 404);
    assert_eq!(get("GET", "/v1/metrics/prometheus").0, 404);
}

#[test]
fn metrics_port_on_every_address_is_refused() {
    let d = tmp("metrics-any");
    let cfg = format!(
        "name: t\nsite: s\npacks_dir: {}\ninputs:\n  udp:\n    - listen: \"127.0.0.1:{}\"\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\nstatus_file: {}/status.json\napi:\n  metrics_listen: \"0.0.0.0:9464\"\n",
        repo().join("packs").display(),
        free_port(),
        d.display()
    );
    std::fs::write(d.join("r.yaml"), cfg).unwrap();
    let out = bin().args(["config", "check", "-c"]).arg(d.join("r.yaml")).output().unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains("mesh address"), "{}", String::from_utf8_lossy(&out.stdout));
}

#[test]
fn slow_callers_on_one_port_do_not_lock_out_the_local_api() {
    // Before each listener had its own budget, 32 connections held open on
    // any port (no certificate needed on the mesh port, no caller check on
    // the metrics port) filled the one shared budget, and the local API,
    // where `health` and the operator's verbs arrive, stopped answering.
    let port = free_port();
    let svc = Service::start("api-slow-callers", &format!("  metrics_listen: \"127.0.0.1:{port}\"\n"));
    let held: Vec<TcpStream> = (0..48)
        .map(|_| {
            let mut s = TcpStream::connect(format!("127.0.0.1:{port}")).unwrap();
            s.write_all(b"GET /met").unwrap(); // and nothing more
            s
        })
        .collect();
    std::thread::sleep(Duration::from_millis(300));
    for _ in 0..5 {
        assert_eq!(svc.raw("GET", "/v1/health", None, None).unwrap().0, 200);
    }
    let st = svc.get("/v1/status");
    assert_eq!(st.get("counters").unwrap().get("dropped_backlog").unwrap().as_i64(), Some(0));
    drop(held);
}

#[test]
fn hostile_reports_are_refused_and_the_runner_stays_up() {
    // The engine's parser descends once per bracket: one datagram or body of
    // open brackets used to overflow the stack and abort the runner.
    let svc = Service::start("api-deep-json", "");
    let deep = "[".repeat(200_000);
    UdpSocket::bind("127.0.0.1:0").unwrap().send_to("[".repeat(60_000).as_bytes(), &svc.udp).unwrap(); // under the datagram limit
    let _ = svc.raw("POST", "/mcp", None, Some(&deep));
    let _ = svc.raw("POST", "/v1/proposals", None, Some(&deep));
    // A longitude of 1e308 next to another track: the engines' longitude
    // wrap (add or subtract 360 until it fits) never ended, and the service
    // loop stopped answering.
    let sock = UdpSocket::bind("127.0.0.1:0").unwrap();
    for (uid, lat, lon) in [("A", "1.0", "1.0"), ("B", "1e308", "-1e308"), ("C", "1.0", "1e999")] {
        let r = format!("{{\"track.source_id\":\"x\",\"uid\":\"{uid}\",\"time_ms\":{},\"lat\":{lat},\"lon\":{lon},\"ce\":30.0}}", now_ms());
        sock.send_to(r.as_bytes(), &svc.udp).unwrap();
    }
    std::thread::sleep(Duration::from_millis(800));
    assert_eq!(svc.raw("GET", "/v1/health", None, None).unwrap().0, 200);
    let st = svc.get("/v1/status");
    assert!(st.get("counters").unwrap().get("unreadable").unwrap().as_i64().unwrap() >= 3, "{st:?}");
    assert_eq!(st.get("counters").unwrap().get("reports_in").unwrap().as_i64(), Some(1), "only A goes in");
}

#[test]
fn file_size_limits_are_checked() {
    let d = tmp("size-limits");
    let cfg = format!(
        "name: t\nsite: s\npacks_dir: {}\ninputs:\n  udp:\n    - listen: \"127.0.0.1:{}\"\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\noutputs:\n  file: {{path: {d}/out.jsonl, max_mb: 0}}\nrecord: {{path: {d}/rec.jsonl, max_mb: 5, keep: 10}}\nstatus_file: {d}/status.json\napi:\n  audit_max_mb: 16\n  audit_keep: 3\n",
        repo().join("packs").display(),
        free_port(),
        d = d.display()
    );
    std::fs::write(d.join("r.yaml"), cfg).unwrap();
    let out = bin().args(["config", "check", "-c"]).arg(d.join("r.yaml")).output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(!out.status.success(), "{text}");
    assert!(text.contains("outputs.file.max_mb: 0"), "{text}");
    assert!(text.contains("record.keep: 10"), "{text}");
    assert!(!text.contains("audit"), "the audit limits are valid: {text}");
}

#[test]
fn hosted_endpoint_over_plain_http_is_refused() {
    let d = tmp("hosted-http");
    let cfg = format!(
        "name: t\nsite: s\npacks_dir: {}\ninputs:\n  udp:\n    - listen: \"127.0.0.1:{}\"\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\nstatus_file: {}/status.json\nagents:\n  endpoints:\n    - {{name: provider, url: \"http://models.example.net/v1/chat/completions\", kind: hosted, data_level: public}}\n",
        repo().join("packs").display(),
        free_port(),
        d.display()
    );
    std::fs::write(d.join("r.yaml"), cfg).unwrap();
    let out = bin().args(["config", "check", "-c"]).arg(d.join("r.yaml")).output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(!out.status.success(), "{text}");
    assert!(text.contains("hosted endpoint over plain http"), "{text}");
}

/// One request with extra header lines; returns (status, head, body).
fn raw_with(api: &str, method: &str, path: &str, headers: &str, body: &str) -> (u16, String, String) {
    let mut s = TcpStream::connect(api).unwrap();
    let host = if headers.to_ascii_lowercase().contains("host:") { String::new() } else { format!("Host: {api}\r\n") };
    write!(s, "{method} {path} HTTP/1.1\r\n{host}{headers}Content-Length: {}\r\n\r\n{body}", body.len()).unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    let status = out.split(' ').nth(1).and_then(|c| c.parse().ok()).unwrap();
    let (head, body) = out.split_once("\r\n\r\n").map(|(h, b)| (h.to_string(), b.to_string())).unwrap();
    (status, head, body)
}

/// The operator page, its one read, the browser rules, and replay in the
/// form the page sends.
#[test]
fn operator_page_view_and_browser_rules() {
    let svc = Service::start("fieldkit", "");
    svc.feed(10);
    let token = svc.token();
    let auth = format!("Authorization: Bearer {token}\r\n");

    // GET /v1/view: everything the page shows.
    let v = svc.get("/v1/view");
    assert_eq!(s(v.get("you").unwrap(), "role"), "read");
    assert_eq!(s(v.get("status").unwrap(), "state"), "running");
    let pipe = v.get("pipeline").unwrap().as_array().unwrap();
    let corr = pipe.iter().find(|p| s(p, "function") == "correlate").unwrap();
    assert_eq!(s(corr, "pack"), "correlate-assign-time");
    let packs: Vec<&str> = corr.get("packs").unwrap().as_array().unwrap().iter().filter_map(|x| x.as_str()).collect();
    assert!(packs.contains(&"correlate-assign-time") && packs.contains(&"correlate-gnn") && packs.iter().all(|p| p.starts_with("correlate-")), "{packs:?}");
    let tracks = v.get("tracks").unwrap().as_array().unwrap();
    assert!(tracks.iter().any(|t| t.get("members").unwrap().as_array().unwrap().len() == 2), "{v}");
    let quality = v.get("quality").unwrap().as_array().unwrap();
    for src in ["adsb", "radar-1"] {
        let q = quality.iter().find(|q| s(q, "source") == src).unwrap_or_else(|| panic!("no quality for {src}: {v}"));
        assert!(matches!(q.get("reports"), Some(Json::Int(n)) if *n >= 10), "{q}");
        assert!(matches!(q.get("measures"), Some(Json::Obj(m)) if m.contains_key("reports")), "the latest source measures: {q}");
    }
    let (st, _, b) = raw_with(&svc.api, "GET", "/v1/view", &auth, "");
    assert_eq!(st, 200);
    assert_eq!(s(json::parse(&b).unwrap().get("you").unwrap(), "role"), "operate");
    let (ok, text) = svc.cli(&["view"]);
    assert!(ok && text.contains("pipeline:") && text.contains("quality per source:") && text.contains("radar-1"), "{text}");

    // GET /ui: one file, nothing from outside, no framing.
    let (st, head, page) = raw_with(&svc.api, "GET", "/ui", "", "");
    assert_eq!(st, 200);
    let head = head.to_ascii_lowercase();
    assert!(head.contains("content-type: text/html"));
    assert!(head.contains("content-security-policy: default-src 'none';") && head.contains("frame-ancestors 'none'") && head.contains("connect-src 'self'"), "{head}");
    assert!(head.contains("x-frame-options: deny"));
    assert!(page.contains("<title>Fieldkit Processors</title>") && page.contains("window.BE") && page.contains("data-action=\"view\""));
    assert!(!page.contains(" src=") && !page.contains("<link"), "the page loads nothing from outside");
    // JSON answers carry no page policy.
    let (_, head, _) = raw_with(&svc.api, "GET", "/v1/status", "", "");
    assert!(!head.to_ascii_lowercase().contains("content-security-policy"));

    // A page from another site may not call the API, even with the operate role.
    for h in ["Sec-Fetch-Site: cross-site\r\n", "Sec-Fetch-Site: same-site\r\n", "Origin: http://elsewhere.example\r\n", "Origin: null\r\n"] {
        let (st, _, b) = raw_with(&svc.api, "POST", "/v1/stop", &format!("{auth}{h}"), "");
        assert_eq!(st, 403, "{h}: {b}");
        assert!(b.contains("another site"), "{b}");
    }
    assert_eq!(s(&svc.get("/v1/status"), "state"), "running", "a refused stop changed nothing");
    assert!(svc.audit().iter().any(|a| s(a, "path") == "/v1/stop" && a.get("status") == Some(&Json::Int(403))));
    // The page itself (same origin) may, with the role.
    let same = format!("{auth}Sec-Fetch-Site: same-origin\r\nSec-Fetch-Mode: cors\r\nOrigin: http://{}\r\n", svc.api);
    let (st, _, b) = raw_with(&svc.api, "POST", "/v1/stop", &same, "");
    assert_eq!(st, 200, "{b}");
    let (st, _, _) = raw_with(&svc.api, "POST", "/v1/start", &same, "");
    assert_eq!(st, 200);
    // And without the role it may only read.
    let (st, _, _) = raw_with(&svc.api, "POST", "/v1/stop", "Sec-Fetch-Site: same-origin\r\n", "");
    assert_eq!(st, 403);

    // A browser that reached 127.0.0.1 under another site's name is refused.
    let (st, _, b) = raw_with(&svc.api, "GET", "/v1/tracks", "Host: rebound.example\r\nSec-Fetch-Site: same-origin\r\nSec-Fetch-Mode: cors\r\n", "");
    assert_eq!(st, 403, "{b}");
    let port = svc.api.rsplit(':').next().unwrap();
    let (st, _, _) = raw_with(&svc.api, "GET", "/v1/tracks", &format!("Host: localhost:{port}\r\nSec-Fetch-Site: same-origin\r\n"), "");
    assert_eq!(st, 200);
    // A program that names the host as it likes is not a browser.
    let (st, _, _) = raw_with(&svc.api, "GET", "/v1/tracks", "Host: any-name\r\n", "");
    assert_eq!(st, 200);

    // Replay as the page sends it: the file as one JSON string, a JSON answer.
    let file = std::fs::read_to_string(repo().join("packs/correlate-assign-time/vectors/56-assign-time-offset-fit.json")).unwrap();
    let body = Json::Str(file.clone()).to_string();
    let (st, _, b) = raw_with(&svc.api, "POST", "/v1/replay", "Accept: application/json\r\nContent-Type: application/json\r\n", &body);
    assert_eq!(st, 200, "{b}");
    let r = json::parse(&b).unwrap();
    assert!(matches!(r.get("lines"), Some(Json::Int(n)) if *n > 0), "{r}");
    assert!(!r.get("events").unwrap().as_object().unwrap().is_empty());
    // Without Accept JSON, the same lines the CLI prints.
    let (st, _, lines) = raw_with(&svc.api, "POST", "/v1/replay", "", &file);
    assert_eq!(st, 200);
    assert_eq!(lines.lines().count() as i64, match r.get("lines") { Some(Json::Int(n)) => *n, _ => 0 });
}
