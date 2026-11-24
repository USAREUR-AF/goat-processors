//! The agent interfaces (docs/design/agentic-ai.md), against a running
//! service and deterministic stub models: the MCP server and its reference
//! client (A1), the model endpoints and the data-level check (A2), the audit
//! of agent calls (A6), the "why?" explainer (A7), and outputs unchanged with
//! every agent interface on and no agent connected (A9).

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

use goat_correlator::json::{self, Json};

/// How long a test waits for the service to start (or a state to change).
/// Normally under a second; generous because CI and shared hosts run many
/// builds at once, and at a load average near 15 a start took over 20 s.
const START_WAIT: Duration = Duration::from_secs(60);

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
    TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}
fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as i64
}
fn s<'a>(v: &'a Json, k: &str) -> &'a str {
    v.get(k).and_then(|x| x.as_str()).unwrap_or("")
}

// ---------- stub models ----------

/// The stub's answer: two sentences citing records it was sent, one with no
/// citation, one citing a record that does not exist.
fn stub_answer(request: &str) -> String {
    let v = json::parse(request).unwrap();
    let user = v.get("messages").and_then(|m| m.as_array()).and_then(|m| m.last()).map(|m| s(m, "content").to_string()).unwrap_or_default();
    let n = user.lines().filter(|l| l.starts_with('R') && l[1..].starts_with(|c: char| c.is_ascii_digit())).count();
    let text = format!(
        "The track's members were assigned together [R1]. The last record shows the latest decision [R{n}, R1]. This sentence has no citation. This one cites a record that was never sent [R{}].",
        n + 50
    );
    let mut msg = std::collections::BTreeMap::new();
    msg.insert("role".into(), Json::Str("assistant".into()));
    msg.insert("content".into(), Json::Str(text));
    let mut choice = std::collections::BTreeMap::new();
    choice.insert("message".into(), Json::Obj(msg));
    let mut out = std::collections::BTreeMap::new();
    out.insert("choices".into(), Json::Arr(vec![Json::Obj(choice)]));
    Json::Obj(out).to_string()
}

fn serve_one(stream: &mut dyn ReadWrite) {
    let mut r = BufReader::new(&mut *stream as &mut dyn ReadWrite);
    let mut len = 0usize;
    loop {
        let mut line = String::new();
        if r.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        if line == "\r\n" {
            break;
        }
        if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
            len = v.trim().parse().unwrap_or(0);
        }
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body).unwrap();
    let answer = stub_answer(&String::from_utf8_lossy(&body));
    let resp = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{answer}", answer.len());
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.flush();
}

trait ReadWrite: Read + Write {}
impl<T: Read + Write> ReadWrite for T {}

/// A local model over plain http. Returns its URL.
fn stub_http() -> String {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://127.0.0.1:{}/v1/chat/completions", l.local_addr().unwrap().port());
    std::thread::spawn(move || {
        for mut s in l.incoming().flatten() {
            serve_one(&mut s);
        }
    });
    url
}

fn openssl(args: &[&str], dir: &Path) {
    assert!(Command::new("openssl").args(args).current_dir(dir).stderr(Stdio::null()).status().unwrap().success(), "openssl {args:?}");
}

/// A test CA and a certificate for `localhost` signed by it, in `dir`.
fn certs(dir: &Path) {
    openssl(&["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca.key"], dir);
    openssl(&["req", "-x509", "-new", "-key", "ca.key", "-sha256", "-days", "2", "-subj", "/CN=test-ca", "-out", "ca.pem", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"], dir);
    openssl(&["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "server.key"], dir);
    openssl(&["req", "-new", "-key", "server.key", "-subj", "/CN=localhost", "-out", "server.csr"], dir);
    std::fs::write(dir.join("server.ext"), "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n").unwrap();
    openssl(&["x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", "2", "-sha256", "-extfile", "server.ext", "-out", "server.pem"], dir);
}

/// A hosted model over https, with a certificate from the test CA in `dir`. Returns its URL.
fn stub_https(dir: &Path) -> String {
    use rustls_pki_types::pem::PemObject;
    use rustls_pki_types::{CertificateDer, PrivateKeyDer};
    let chain: Vec<CertificateDer<'static>> = CertificateDer::pem_file_iter(dir.join("server.pem")).unwrap().map(|c| c.unwrap()).collect();
    let key = PrivateKeyDer::from_pem_file(dir.join("server.key")).unwrap();
    let cfg = Arc::new(
        rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(chain, key)
            .unwrap(),
    );
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("https://localhost:{}/v1/chat/completions", l.local_addr().unwrap().port());
    std::thread::spawn(move || {
        for tcp in l.incoming().flatten() {
            let conn = rustls::ServerConnection::new(cfg.clone()).unwrap();
            let mut s = rustls::StreamOwned::new(conn, tcp);
            serve_one(&mut s);
            s.conn.send_close_notify();
            let _ = s.flush();
        }
    });
    url
}

// ---------- the service ----------

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
    fn start(name: &str, agents: &str) -> Service {
        let dir = tmp(name);
        let api = format!("127.0.0.1:{}", free_port());
        let udp = format!("127.0.0.1:{}", free_port());
        let cfg = format!(
            "name: t\nsite: s\npacks_dir: {packs}\ntick_ms: 200\ninputs:\n  udp:\n    - listen: \"{udp}\"\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\n  - {{function: quality, pack: quality-feed}}\nstatus_file: {d}/status.json\napi:\n  listen: \"{api}\"\n  token_file: {d}/api.token\n  audit_file: {d}/audit.jsonl\n{agents}{pf}",
            pf = if agents.contains("agents:") { format!("  proposals_file: {}/proposals.json\n", dir.display()) } else { format!("agents:\n  proposals_file: {}/proposals.json\n", dir.display()) },
            packs = repo().join("packs").display(),
            d = dir.display(),
        );
        std::fs::write(dir.join("r.yaml"), &cfg).unwrap();
        let check = bin().args(["config", "check", "-c"]).arg(dir.join("r.yaml")).output().unwrap();
        assert!(check.status.success(), "{}", String::from_utf8_lossy(&check.stdout));
        let child = bin().args(["run", "-c"]).arg(dir.join("r.yaml")).stderr(Stdio::null()).spawn().unwrap();
        let svc = Service { child, dir, api, udp };
        let deadline = Instant::now() + START_WAIT;
        while Instant::now() < deadline {
            if TcpStream::connect(&svc.api).is_ok() && svc.dir.join("status.json").exists() {
                return svc;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        panic!("the service did not start");
    }

    fn token(&self) -> String {
        std::fs::read_to_string(self.dir.join("api.token")).unwrap()
    }

    fn feed(&self, n: usize) {
        let sock = UdpSocket::bind("127.0.0.1:0").unwrap();
        for i in 0..n {
            let t = now_ms();
            for (src, d) in [("radar-1", 0.0), ("adsb", 0.00005)] {
                let r = format!("{{\"track.source_id\":\"{src}\",\"uid\":\"T1\",\"time_ms\":{t},\"lat\":{},\"lon\":1.0,\"ce\":30.0,\"course\":0.0,\"speed_ms\":11.0,\"type\":\"a-f-S\"}}", 1.0 + d + i as f64 * 2e-5);
                sock.send_to(r.as_bytes(), &self.udp).unwrap();
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        std::thread::sleep(Duration::from_millis(500));
    }

    /// One MCP call; returns the JSON-RPC reply.
    fn mcp(&self, token: Option<&str>, method: &str, params: &str) -> Json {
        let body = format!("{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{method}\",\"params\":{params}}}");
        let mut s = TcpStream::connect(&self.api).unwrap();
        let auth = token.map(|t| format!("Authorization: Bearer {t}\r\n")).unwrap_or_default();
        write!(s, "POST /mcp HTTP/1.1\r\nHost: x\r\n{auth}Content-Length: {}\r\n\r\n{body}", body.len()).unwrap();
        let mut out = String::new();
        s.read_to_string(&mut out).unwrap();
        json::parse(out.split_once("\r\n\r\n").unwrap().1).unwrap()
    }

    fn tool(&self, token: Option<&str>, name: &str, args: &str) -> (bool, String) {
        let r = self.mcp(token, "tools/call", &format!("{{\"name\":\"{name}\",\"arguments\":{args}}}"));
        let res = r.get("result").unwrap_or_else(|| panic!("{name}: {r}"));
        let text = res.get("content").unwrap().as_array().unwrap()[0].get("text").unwrap().as_str().unwrap().to_string();
        (res.get("isError") == Some(&Json::Bool(true)), text)
    }

    fn audit(&self) -> Vec<Json> {
        std::fs::read_to_string(self.dir.join("audit.jsonl")).unwrap_or_default().lines().map(|l| json::parse(l).unwrap()).collect()
    }

    fn agent_audit(&self, tool: &str) -> Vec<Json> {
        self.audit().into_iter().filter(|a| s(a, "agent_tool") == tool).collect()
    }
}

fn joined_track(svc: &Service) -> String {
    let (_, text) = svc.tool(None, "tracks", "{}");
    let v = json::parse(&text).unwrap();
    v.get("tracks").unwrap().as_array().unwrap().iter().find(|t| t.get("members").map(|m| m.to_string()) == Some("[\"adsb/T1\",\"radar-1/T1\"]".into())).map(|t| s(t, "system").to_string()).expect("a joined track")
}

const POLICY: &str = "  actions:\n    - {who: local-admin, actions: [use_pack, stop, start, approve, reject, revert]}\n";

#[test]
fn a1_reference_client_lists_and_calls_every_tool() {
    let local = stub_http();
    let agents = format!("agents:\n  endpoints:\n    - {{name: local-stub, url: \"{local}\", kind: local, data_level: site}}\n  sources:\n    - {{who: local-admin, source_id: agent-example}}\n{POLICY}");
    let svc = Service::start("agents-a1", &agents);
    svc.feed(10);
    let out = Command::new("python3")
        .args(["-I", repo().join("runner/examples/mcp_client.py").to_str().unwrap(), "--url", &format!("http://{}/mcp", svc.api), "--token-file"])
        .arg(svc.dir.join("api.token"))
        .args(["--actions", "--json"])
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    assert!(out.status.success(), "{text}{}", String::from_utf8_lossy(&out.stderr));
    let calls: Vec<Json> = text.lines().filter(|l| l.starts_with('{')).map(|l| json::parse(l).unwrap()).collect();
    let listed = svc.mcp(None, "tools/list", "{}");
    let names: Vec<String> = listed.get("result").unwrap().get("tools").unwrap().as_array().unwrap().iter().map(|t| s(t, "name").to_string()).collect();
    assert!(names.len() >= 13, "{names:?}");
    for n in &names {
        let c = calls.iter().find(|c| s(c, "tool") == n).unwrap_or_else(|| panic!("the client did not call {n}"));
        assert_eq!(c.get("error"), Some(&Json::Bool(false)), "{n}: {}", s(c, "text"));
    }
    // The tracks tool pages: limit (a number or a string) goes to the query.
    let (err, text) = svc.tool(None, "tracks", "{\"limit\": 1}");
    let page = json::parse(&text).unwrap();
    assert!(!err && page.get("tracks").and_then(|t| t.as_array()).map(|a| a.len()) == Some(1) && page.get("total").is_some(), "{text}");
    let (err, text) = svc.tool(None, "tracks", "{\"limit\": \"0\"}");
    assert!(err && text.contains("not a number of 1 or more"), "{text}");
    // A6: every call is audited with identity, tool, inputs digest and result.
    for n in &names {
        let a = svc.agent_audit(n);
        assert!(!a.is_empty(), "{n} not audited");
        assert_eq!(s(&a[0], "who"), "local-admin");
        assert_eq!(s(&a[0], "inputs_sha256").len(), 64);
        assert!(!s(&a[0], "outcome").is_empty());
    }
}

#[test]
fn a1_a6_no_tool_exceeds_the_callers_cli_authority() {
    // The policy names the read-only local identity too: the role still refuses.
    let agents = "agents:\n  actions:\n    - {who: local, actions: [use_pack, stop, start]}\n    - {who: local-admin, actions: [stop]}\n";
    let svc = Service::start("agents-authority", agents);
    let token = svc.token();
    let (err, text) = svc.tool(None, "stop", "{}");
    assert!(err && text.contains("needs the role operate"), "{text}");
    let (err, text) = svc.tool(None, "use_pack", "{\"function\":\"quality\",\"pack\":\"quality-time\"}");
    assert!(err && text.contains("needs the role operate"), "{text}");
    // With the role but without the policy: refused by the policy.
    let (err, text) = svc.tool(Some(&token), "use_pack", "{\"function\":\"quality\",\"pack\":\"quality-time\"}");
    assert!(err && text.contains("site policy"), "{text}");
    // With both: allowed, exactly as `sudo goat-processors stop`.
    let (err, text) = svc.tool(Some(&token), "stop", "{}");
    assert!(!err && text.contains("paused"), "{text}");
    for (who, outcome) in [("local", "HTTP 403"), ("local-admin", "refused: the site policy"), ("local-admin", "HTTP 200")] {
        assert!(svc.audit().iter().any(|a| s(a, "who") == who && s(a, "outcome").starts_with(outcome)), "no audit line {who} {outcome}");
    }
    // The CLI refuses the same thing to the same identity.
    let api = svc.api.clone();
    let out = bin().args(["stop", "--api", &api, "-c", "/nonexistent"]).output().unwrap();
    assert!(!out.status.success());
}

#[test]
fn a2_data_level_refusals() {
    let local = stub_http();
    let certs_dir = tmp("agents-a2-certs");
    certs(&certs_dir);
    let hosted = stub_https(&certs_dir);
    // The hosted endpoint is declared for public data only.
    let agents = format!(
        "agents:\n  data_levels: [public, site]\n  local_level: site\n  endpoints:\n    - {{name: hosted, url: \"{hosted}\", kind: hosted, data_level: public, ca_file: {}}}\n    - {{name: local, url: \"{local}\", kind: local, data_level: site}}\n",
        certs_dir.join("ca.pem").display()
    );
    let svc = Service::start("agents-a2", &agents);
    svc.feed(10);
    let id = joined_track(&svc);
    // A call that would send site data to the public endpoint is refused, and nothing is sent.
    let (err, text) = svc.tool(None, "why", &format!("{{\"track\":\"{id}\",\"endpoint\":\"hosted\"}}"));
    assert!(err && text.contains("refused: this call sends site data"), "{text}");
    // The local endpoint, declared for site data, is used.
    let (err, text) = svc.tool(None, "why", &format!("{{\"track\":\"{id}\"}}"));
    assert!(!err, "{text}");
    assert_eq!(s(&json::parse(&text).unwrap(), "endpoint"), "local");

    // A caller whose level is public cannot receive site data through MCP.
    let agents2 = "agents:\n  data_levels: [public, site]\n  local_level: public\n";
    let svc2 = Service::start("agents-a2-caller", agents2);
    let (err, text) = svc2.tool(None, "tracks", "{}");
    assert!(err && text.contains("returns site data"), "{text}");
    let (err, _) = svc2.tool(None, "packs", "{}");
    assert!(!err);
    assert!(svc2.agent_audit("tracks").iter().any(|a| s(a, "outcome").starts_with("refused")));
}

#[test]
fn a2_hosted_endpoint_over_https() {
    let certs_dir = tmp("agents-hosted-certs");
    certs(&certs_dir);
    let hosted = stub_https(&certs_dir);
    // This site approved its site data for this provider.
    let agents = format!("agents:\n  endpoints:\n    - {{name: provider, url: \"{hosted}\", kind: hosted, data_level: site, model: stub-1, ca_file: {}}}\n", certs_dir.join("ca.pem").display());
    let svc = Service::start("agents-hosted", &agents);
    svc.feed(10);
    let id = joined_track(&svc);
    let (err, text) = svc.tool(None, "why", &format!("{{\"track\":\"{id}\"}}"));
    assert!(!err, "{text}");
    let v = json::parse(&text).unwrap();
    assert_eq!(s(&v, "endpoint_kind"), "hosted");
    assert_eq!(s(&v, "model"), "stub-1");
}

#[test]
fn a7_every_sentence_cites_a_record_that_exists() {
    let local = stub_http();
    let agents = format!("agents:\n  endpoints:\n    - {{name: local-stub, url: \"{local}\", kind: local, data_level: site}}\n");
    let svc = Service::start("agents-a7", &agents);
    svc.feed(10);
    let id = joined_track(&svc);
    let (err, text) = svc.tool(None, "why", &format!("{{\"track\":\"{id}\"}}"));
    assert!(!err, "{text}");
    let v = json::parse(&text).unwrap();
    let sentences = v.get("sentences").unwrap().as_array().unwrap();
    assert_eq!(sentences.len(), 2, "{text}");
    assert_eq!(v.get("sentences_removed").unwrap().as_i64(), Some(2));
    // Every cited record is one the runner holds for this track.
    let (_, ex) = svc.tool(None, "explain", &format!("{{\"track\":\"{id}\"}}"));
    let ex = json::parse(&ex).unwrap();
    let known: Vec<String> = ["events", "trace"].iter().flat_map(|k| ex.get(k).unwrap().as_array().unwrap().iter().map(|r| r.to_string()).collect::<Vec<_>>()).collect();
    for snt in sentences {
        let cites = snt.get("cites").unwrap().as_array().unwrap();
        let records = snt.get("records").unwrap().as_array().unwrap();
        assert!(!cites.is_empty() && cites.len() == records.len());
        for r in records {
            assert!(known.contains(&r.to_string()), "a cited record the runner does not hold: {r}");
        }
    }
    // The CLI verb gives the same answer.
    let out = bin().args(["why", &id, "-c"]).arg(svc.dir.join("r.yaml")).output().unwrap();
    let t = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success() && t.contains("2 sentences") && t.contains("[R1]"), "{t}");
    assert!(svc.agent_audit("why").iter().any(|a| s(a, "outcome").contains("2 sentences kept, 2 removed")));
}

#[test]
fn a1_stdio_bridge() {
    let svc = Service::start("agents-stdio", "");
    let mut child = bin().args(["mcp", "-c"]).arg(svc.dir.join("r.yaml")).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    writeln!(stdin, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{}}}}").unwrap();
    writeln!(stdin, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}}").unwrap();
    writeln!(stdin, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":\"health\",\"arguments\":{{}}}}}}").unwrap();
    drop(stdin);
    let out = child.wait_with_output().unwrap();
    let lines: Vec<Json> = String::from_utf8_lossy(&out.stdout).lines().map(|l| json::parse(l).unwrap()).collect();
    assert_eq!(lines.len(), 2, "one reply per request, none for the notification");
    assert_eq!(s(lines[0].get("result").unwrap().get("serverInfo").unwrap(), "name"), "goat-processors");
    assert!(lines[1].get("result").unwrap().to_string().contains("healthy"));
}

/// The output of one run over a recorded file, with the given extra config.
fn run_file(name: &str, extra: &str) -> String {
    let dir = tmp(name);
    let mut lines = Vec::new();
    let v = json::parse(&std::fs::read_to_string(repo().join("packs/correlate-assign-time/vectors/56-assign-time-offset-fit.json")).unwrap()).unwrap();
    for st in v.get("steps").unwrap().as_array().unwrap() {
        if let Some(r) = st.get("ingest") {
            lines.push(r.to_string());
        }
    }
    std::fs::write(dir.join("in.jsonl"), lines.join("\n") + "\n").unwrap();
    let cfg = format!(
        "name: t\nsite: s\npacks_dir: {}\nclock: input\ninputs:\n  file:\n    path: {d}/in.jsonl\n    speed: 0\npipeline:\n  - {{function: correlate, pack: correlate-assign-time}}\n  - {{function: quality, pack: quality-feed}}\noutputs:\n  file:\n    path: {d}/out.jsonl\n    trace: true\nstatus_file: {d}/status.json\n{extra}",
        repo().join("packs").display(),
        d = dir.display()
    );
    std::fs::write(dir.join("r.yaml"), cfg).unwrap();
    let mut child = bin().args(["run", "-c"]).arg(dir.join("r.yaml")).stderr(Stdio::piped()).spawn().unwrap();
    let err = child.stderr.take().unwrap();
    for l in BufReader::new(err).lines().map_while(Result::ok) {
        if l.contains("every input has ended") {
            break;
        }
    }
    child.kill().unwrap();
    child.wait().unwrap();
    std::fs::read_to_string(dir.join("out.jsonl")).unwrap()
}

#[test]
fn a9_outputs_are_byte_identical_with_agent_interfaces_on_and_no_agent() {
    let off = run_file("agents-a9-off", "api:\n  enabled: false\nagents:\n  mcp: false\n");
    let api = format!("127.0.0.1:{}", free_port());
    let dir = tmp("agents-a9-on-files");
    let on = run_file(
        "agents-a9-on",
        &format!(
            "api:\n  listen: \"{api}\"\n  token_file: {d}/api.token\n  audit_file: {d}/audit.jsonl\nagents:\n  mcp: true\n  data_levels: [public, recorded, site]\n  endpoints:\n    - {{name: local, url: \"http://127.0.0.1:9/v1\", kind: local, data_level: site}}\n  actions:\n    - {{who: local-admin, actions: [use_pack, stop, start]}}\n",
            d = dir.display()
        ),
    );
    assert!(on.lines().count() > 20);
    assert_eq!(on, off);
}

fn proposals(svc: &Service) -> Vec<Json> {
    let (_, text) = svc.tool(None, "proposals", "{}");
    json::parse(&text).unwrap().as_array().unwrap().clone()
}

fn wait_state(svc: &Service, id: &str, state: &str) -> Json {
    let deadline = Instant::now() + START_WAIT;
    loop {
        if let Some(p) = proposals(svc).into_iter().find(|p| s(p, "id") == id) {
            if s(&p, "state") == state {
                return p;
            }
            assert!(Instant::now() < deadline, "{id} is {}, not {state}", s(&p, "state"));
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn running_pack(svc: &Service, function: &str) -> String {
    let (_, text) = svc.tool(None, "pipeline", "{}");
    json::parse(&text).unwrap().as_array().unwrap().iter().find(|st| s(st, "function") == function).map(|st| s(st, "pack").to_string()).unwrap()
}

#[test]
fn a5_proposals_policy_approval_and_revert() {
    // The policy: the agent (here the local read-only identity) may move
    // quality between quality-feed and quality-time once `true` passes, and
    // may move correlate to assign-full only if `false` passes (it never does).
    let agents = "agents:\n  auto_approve:\n    - {who: local, function: quality, packs: [quality-feed, quality-time], gate: [\"true\"]}\n    - {who: local, function: correlate, packs: [correlate-assign-full], gate: [\"false\"]}\n";
    let svc = Service::start("agents-a5", &format!("record:\n  path: {}/record.jsonl\n{agents}", tmp("agents-a5-rec").display()));
    let token = svc.token();

    // Inside the policy: applied after the gate.
    let (err, text) = svc.tool(None, "propose", "{\"function\":\"quality\",\"pack\":\"quality-time\",\"reason\":\"sources report their clock state\"}");
    assert!(!err, "{text}");
    let p1 = json::parse(&text).unwrap();
    assert_eq!(s(&p1, "state"), "gating");
    let p1 = wait_state(&svc, s(&p1, "id"), "applied");
    assert_eq!(s(&p1, "decided_by"), "policy");
    assert_eq!(p1.get("gate").unwrap().get("passed"), Some(&Json::Bool(true)));
    assert_eq!(running_pack(&svc, "quality"), "quality-time");

    // Outside the policy (a pack not in its bounds): waits for a person.
    let (_, text) = svc.tool(None, "propose", "{\"function\":\"quality\",\"pack\":\"quality-edge\",\"reason\":\"try the edge rules\"}");
    let p2 = json::parse(&text).unwrap();
    let id2 = s(&p2, "id").to_string();
    assert_eq!(s(&p2, "state"), "pending");
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(s(&wait_state(&svc, &id2, "pending"), "state"), "pending");
    assert_eq!(running_pack(&svc, "quality"), "quality-time");

    // A failing gate: not applied, waits for a person.
    let (_, text) = svc.tool(None, "propose", "{\"function\":\"correlate\",\"pack\":\"correlate-assign-full\",\"reason\":\"x\"}");
    let p3 = json::parse(&text).unwrap();
    let p3 = wait_state(&svc, s(&p3, "id"), "gate-failed");
    assert_eq!(p3.get("gate").unwrap().get("passed"), Some(&Json::Bool(false)));
    assert_eq!(running_pack(&svc, "correlate"), "correlate-assign-time");

    // The read-only proposer cannot approve its own proposal.
    let out = bin().args(["proposal", "approve", &id2, "--api", &svc.api, "-c", "/nonexistent"]).output().unwrap();
    assert!(!out.status.success());
    // A person with the role operate approves it (the CLI, with the token).
    let out = bin().args(["proposal", "approve", &id2, "-c"]).arg(svc.dir.join("r.yaml")).output().unwrap();
    let t = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success() && t.contains("applied") && t.contains("decided by local-admin"), "{t}");
    assert_eq!(running_pack(&svc, "quality"), "quality-edge");

    // Revert restores the previous pack, in one step.
    let out = bin().args(["proposal", "revert", &id2, "-c"]).arg(svc.dir.join("r.yaml")).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(running_pack(&svc, "quality"), "quality-time");
    assert_eq!(s(&wait_state(&svc, &id2, "reverted"), "decided_by"), "local-admin");
    // The revert action tool, like every action tool, needs the site policy.
    let r = svc.mcp(Some(&token), "tools/call", &format!("{{\"name\":\"revert\",\"arguments\":{{\"id\":\"{}\"}}}}", s(&p1, "id")));
    assert!(r.to_string().contains("site policy"), "the revert action tool needs the policy: {r}");

    // Every step is audited and recorded.
    assert!(svc.agent_audit("propose").len() >= 3);
    assert!(svc.audit().iter().any(|a| s(a, "path") == format!("/v1/proposals/{id2}/approve") && s(a, "who") == "local-admin"));
    let rec = std::fs::read_to_string(tmp_path("agents-a5-rec").join("record.jsonl")).unwrap();
    for pack in ["quality-time", "quality-edge"] {
        assert!(rec.contains(&format!("{{\"pack\":{{\"function\":\"quality\",\"pack\":\"{pack}\"}}}}")), "{pack} not recorded");
    }
    // The proposals are kept in the proposals file.
    let saved = json::parse(&std::fs::read_to_string(svc.dir.join("proposals.json")).unwrap()).unwrap();
    assert!(saved.as_array().unwrap().iter().any(|p| s(p, "id") == id2 && s(p, "state") == "reverted"));
}

fn tmp_path(name: &str) -> PathBuf {
    Path::new(env!("CARGO_TARGET_TMPDIR")).join(name)
}

#[test]
fn a3_agent_as_a_source() {
    let dir = tmp("agents-a3-files");
    let agents = format!(
        "outputs:\n  file:\n    path: {d}/out.jsonl\n    trace: true\nrecord:\n  path: {d}/record.jsonl\nagents:\n  sources:\n    - {{who: local, source_id: agent-vision}}\n",
        d = dir.display()
    );
    let svc = Service::start("agents-a3", &agents);
    let token = svc.token();
    // Refusals: another source id, no model, an identity not listed.
    let report = |src: &str, model: bool, t: i64, lat: f64| {
        format!(
            "{{\"track.source_id\":\"{src}\",\"uid\":\"V1\",\"time_ms\":{t},\"lat\":{lat},\"lon\":1.0,\"ce\":40.0,\"course\":0.0,\"speed_ms\":11.0,\"type\":\"a-f-S\"{}}}",
            if model { ",\"provenance.model\":\"vision-stub-1\",\"provenance.inputs\":\"camera-3 frames\"" } else { "" }
        )
    };
    let publish = |tok: Option<&str>, body: &str| svc.tool(tok, "publish", &format!("{{\"reports\":{}}}", Json::Str(body.into())));
    let (err, text) = publish(None, &report("radar-1", true, now_ms(), 1.0));
    assert!(err && text.contains("may publish only as \\\"agent-vision\\\""), "{text}");
    let (err, text) = publish(None, &report("agent-vision", false, now_ms(), 1.0));
    assert!(err && text.contains("no provenance.model"), "{text}");
    let (err, text) = publish(Some(&token), &report("agent-vision", true, now_ms(), 1.0));
    assert!(err && text.contains("is not an agent source"), "{text}");

    // The agent reports the same object as the two sensors.
    let sock = UdpSocket::bind("127.0.0.1:0").unwrap();
    for i in 0..10 {
        let t = now_ms();
        let lat = 1.0 + i as f64 * 2e-5;
        for (src, d) in [("radar-1", 0.0), ("adsb", 0.00005)] {
            let r = format!("{{\"track.source_id\":\"{src}\",\"uid\":\"T1\",\"time_ms\":{t},\"lat\":{},\"lon\":1.0,\"ce\":30.0,\"course\":0.0,\"speed_ms\":11.0,\"type\":\"a-f-S\"}}", lat + d);
            sock.send_to(r.as_bytes(), &svc.udp).unwrap();
        }
        let (err, text) = publish(None, &report("agent-vision", true, t, lat + 0.00002));
        assert!(!err, "{text}");
        std::thread::sleep(Duration::from_millis(200));
    }
    std::thread::sleep(Duration::from_millis(500));

    // A report over UDP that claims to be a checked agent report: the runner
    // keeps the claim as written but marks it not checked.
    let t = now_ms();
    let forged = format!("{{\"track.source_id\":\"agent-forged\",\"uid\":\"F1\",\"time_ms\":{t},\"lat\":1.0002,\"lon\":1.0,\"ce\":40.0,\"course\":0.0,\"speed_ms\":11.0,\"type\":\"a-f-S\",\"provenance.kind\":\"agent\",\"provenance.agent\":\"local\",\"provenance.checked\":true,\"provenance.model\":\"x\"}}");
    sock.send_to(forged.as_bytes(), &svc.udp).unwrap();
    std::thread::sleep(Duration::from_millis(300));
    let outf = std::fs::read_to_string(dir.join("out.jsonl")).unwrap();
    assert!(outf.contains("\"provenance\":{\"agent\":\"local\",\"checked\":false,\"model\":\"x\"}"), "the forged claim was not marked unchecked");

    // The processors took it as a source: it is a member, with its provenance.
    let (_, text) = svc.tool(None, "tracks", "{}");
    let v = json::parse(&text).unwrap();
    let t = v.get("tracks").unwrap().as_array().unwrap().iter().find(|t| t.get("members").unwrap().to_string().contains("agent-vision/V1")).cloned().unwrap_or_else(|| panic!("no track with the agent: {text}"));
    let prov = t.get("agent_provenance").unwrap().get("agent-vision/V1").unwrap();
    assert_eq!(s(prov, "agent"), "local");
    assert_eq!(prov.get("checked"), Some(&Json::Bool(true)));
    assert_eq!(s(prov, "model"), "vision-stub-1");
    let (_, st) = svc.tool(None, "status", "{}");
    assert!(st.contains("\"agent-vision\":10"), "{st}");
    // The provenance is in the output lines and the trace sits beside it.
    let out = std::fs::read_to_string(dir.join("out.jsonl")).unwrap();
    assert!(out.lines().any(|l| l.contains("\"provenance\":{\"agent\":\"local\",\"checked\":true,\"inputs\":\"camera-3 frames\",\"model\":\"vision-stub-1\"}") && l.contains("\"trace\":")));
    assert!(out.contains("\"agent_provenance\""));
    // Audited.
    assert!(svc.agent_audit("publish").iter().any(|a| s(a, "outcome") == "accepted 1 reports as agent-vision"));
    assert!(svc.agent_audit("publish").iter().any(|a| s(a, "outcome").starts_with("refused")));
    // Recorded: a replay of the record gives the same output.
    let replay = bin().arg("replay").arg(dir.join("record.jsonl")).args(["--trace", "-c"]).arg(svc.dir.join("r.yaml")).output().unwrap();
    let replayed = String::from_utf8(replay.stdout).unwrap();
    let out = std::fs::read_to_string(dir.join("out.jsonl")).unwrap();
    let a: Vec<&str> = replayed.lines().collect();
    let b: Vec<&str> = out.lines().collect();
    let n = a.len().min(b.len());
    assert!(n > 40);
    assert_eq!(&a[..n], &b[..n]);
}

fn example(name: &str, svc: &Service, args: &[&str]) -> (bool, String) {
    let out = Command::new("python3")
        .args(["-I", repo().join("runner/examples").join(name).to_str().unwrap(), "--url", &format!("http://{}/mcp", svc.api)])
        .args(args)
        .output()
        .unwrap();
    (out.status.success(), format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr)))
}

#[test]
fn a8_every_guide_example_runs() {
    let local = stub_http();
    let agents = format!("agents:\n  endpoints:\n    - {{name: local, url: \"{local}\", kind: local, data_level: site}}\n  sources:\n    - {{who: local, source_id: agent-example}}\n  auto_approve:\n    - {{who: local, function: quality, packs: [quality-time], gate: [\"true\"]}}\n");
    let svc = Service::start("agents-a8", &agents);
    svc.feed(8);
    // A1: the reference MCP client (read tools).
    let (ok, out) = example("mcp_client.py", &svc, &[]);
    assert!(ok && out.contains("tools"), "{out}");
    // A3: publish as an agent source.
    let (ok, out) = example("publish_source.py", &svc, &["--source-id", "agent-example", "--model", "example-1", "--demo", "3"]);
    assert!(ok && out.contains("published 3 reports as agent-example"), "{out}");
    let (ok, out) = example("publish_source.py", &svc, &["--source-id", "radar-1", "--model", "example-1", "--demo", "1"]);
    assert!(!ok && out.contains("may publish only as"), "{out}");
    // A5: propose a pack; inside the policy it applies after the gate.
    let (ok, out) = example("propose_pack.py", &svc, &["quality", "quality-time", "--reason", "example"]);
    assert!(ok && out.contains("quality-feed -> quality-time: applied, decided by policy"), "{out}");
    let (ok, out) = example("propose_pack.py", &svc, &["quality", "quality-edge", "--reason", "example"]);
    assert!(ok && out.contains(": pending") && out.contains("proposal approve"), "{out}");
}
