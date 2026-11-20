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
