//! The runner's HTTP API (runner/openapi.yaml).
//!
//! **Who may call.** Every request has an identity and a role:
//!
//! | Listener | Identity | Role |
//! |---|---|---|
//! | local (loopback, plain HTTP) with the token from `api.token_file` | `local-admin` | `operate` |
//! | local without the token | `local` | `read` |
//! | mesh (mutual TLS) | the CN of the client certificate | the role `api.mesh.allow` gives that CN; a CN not listed is refused |
//!
//! The token file is readable by root only, so `sudo goat-processors ...` may
//! operate and a user without sudo may read. A route needs `read` or
//! `operate` (the table in `ROUTES`).
//!
//! **Audit.** Every request that changes something, and every refused
//! request, is appended to `api.audit_file` as one JSON line: time, identity,
//! listener, role, method, path, status.
//!
//! **Order.** A request that reads or changes the running pipeline is passed
//! to the service loop and answered between two reports, so it never sees a
//! half-processed step. Replay runs on its own pipeline, apart from the live one.

use std::collections::BTreeMap;
use std::fs::OpenOptions;
use std::io::Write;
use std::net::TcpListener;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Sender, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::json::{self, Json};

use crate::config::{Config, Role};
use crate::fabric::Input;
use crate::http::{self, Request, Response};

/// What the service loop is asked.
#[derive(Debug, Clone)]
pub enum Ask {
    Status,
    Health,
    Pipeline,
    PackUse { function: String, pack: String },
    Start,
    Stop,
    Metrics,
    Prometheus,
    Tracks,
    Explain(String),
    /// Everything the Fieldkit page shows, in one read.
    View,
    Propose { function: String, pack: String, reason: String },
    Proposals,
    Decide { id: String, verb: String },
}

#[derive(Debug, Clone)]
pub struct Identity {
    pub name: String,
    pub role: Role,
    pub via: &'static str,
}

pub struct Call {
    pub ask: Ask,
    pub who: Identity,
    pub reply: Sender<Response>,
}

/// Every route: method, path pattern (`{x}` is one segment), the role it
/// needs, and what it does. runner/openapi.yaml documents the same table;
/// a test checks that the two agree.
pub const ROUTES: &[(&str, &str, Role, &str)] = &[
    ("GET", "/v1/status", Role::Read, "the service's state, pipeline and counters"),
    ("GET", "/v1/health", Role::Read, "200 when running and ticking, else 503"),
    ("GET", "/v1/pipeline", Role::Read, "the running pipeline: each function and its pack"),
    ("PUT", "/v1/pipeline/{function}", Role::Operate, "select the pack of one function; body {\"pack\": NAME}"),
    ("GET", "/v1/packs", Role::Read, "every installed pack, and which are in use"),
    ("POST", "/v1/stop", Role::Operate, "pause: inputs are counted and dropped, no tick is made"),
    ("POST", "/v1/start", Role::Operate, "resume after a stop"),
    ("GET", "/v1/metrics", Role::Read, "reports per second, processing latency, counts per source"),
    ("GET", "/v1/metrics/prometheus", Role::Read, "the metrics in the Prometheus text format: reports per source, system tracks, multi-source tracks, events, quality per source, latency"),
    ("GET", "/v1/tracks", Role::Read, "the system tracks of the latest tick"),
    ("GET", "/v1/explain/{track}", Role::Read, "the events and trace records behind one system track"),
    ("POST", "/v1/replay", Role::Read, "run a replay file (the body) through a separate copy of the pipeline"),
    ("GET", "/v1/audit", Role::Operate, "the latest audit lines; query limit (default 100)"),
    ("GET", "/v1/routes", Role::Read, "this table"),
    ("GET", "/v1/view", Role::Read, "everything the operator page shows in one read: state, pipeline with the packs each function may use, system tracks, quality per source, proposals, and the caller's identity and role"),
    ("GET", "/ui", Role::Read, "the operator page (Fieldkit Processors): one HTML file, no outside assets"),
    ("GET", "/v1/proposals", Role::Read, "every proposal, pending and decided"),
    ("POST", "/v1/proposals", Role::Read, "propose a pack for a function; body {\"function\", \"pack\", \"reason\"}; nothing changes until it is applied"),
    ("POST", "/v1/proposals/{id}/approve", Role::Operate, "apply a pending proposal"),
    ("POST", "/v1/proposals/{id}/reject", Role::Operate, "reject a pending proposal"),
    ("POST", "/v1/proposals/{id}/revert", Role::Operate, "restore the pack an applied proposal replaced"),
    ("POST", "/v1/source", Role::Read, "publish reports as an agent source listed in agents.sources; the runner adds the agent's identity to their provenance"),
    ("GET", "/v1/why/{track}", Role::Read, "a plain explanation of one system track from a model endpoint; every sentence cites trace records; query endpoint"),
    ("POST", "/mcp", Role::Read, "the MCP endpoint: the routes above as tools for agents (JSON-RPC 2.0); each tool keeps its route's role"),
];

fn matches(pattern: &str, path: &str) -> Option<Vec<String>> {
    let p: Vec<&str> = pattern.trim_matches('/').split('/').collect();
    let a: Vec<&str> = path.trim_matches('/').split('/').collect();
    if p.len() != a.len() {
        return None;
    }
    let mut args = Vec::new();
    for (x, y) in p.iter().zip(&a) {
        if x.starts_with('{') {
            if y.is_empty() {
                return None;
            }
            args.push(http::decode(y));
        } else if x != y {
            return None;
        }
    }
    Some(args)
}

/// The route of a request: its index in ROUTES and its path arguments.
pub fn route(method: &str, path: &str) -> Result<(usize, Vec<String>), (u16, String)> {
    let mut path_found = false;
    for (i, (m, p, _, _)) in ROUTES.iter().enumerate() {
        if let Some(args) = matches(p, path) {
            path_found = true;
            if *m == method {
                return Ok((i, args));
            }
        }
    }
    if path_found {
        Err((405, format!("{method} is not allowed on {path}")))
    } else {
        Err((404, format!("no route {path}; GET /v1/routes lists them")))
    }
}

/// The answer to a replay asked for as JSON (the operator page): how many
/// output lines, the events per function and event, and the system tracks
/// of the last tick that made any.
fn replay_summary(out: &str) -> Json {
    let mut lines = 0i64;
    let mut events: BTreeMap<String, i64> = BTreeMap::new();
    let mut tracks = Json::Arr(vec![]);
    let mut now = Json::Null;
    for l in out.lines() {
        let Ok(v) = json::parse(l) else { continue };
        lines += 1;
        let stage = v.get("stage").and_then(|x| x.as_str()).unwrap_or("").to_string();
        let Some(evs) = v.get("events").and_then(|e| e.as_array()) else { continue };
        let mut sys = vec![];
        for e in evs {
            let ev = e.get("ev").and_then(|x| x.as_str()).unwrap_or("");
            *events.entry(format!("{stage} {ev}")).or_default() += 1;
            if ev == "system" || ev == "fused" {
                sys.push(e.clone());
            }
        }
        if !sys.is_empty() && v.get("call").and_then(|c| c.as_str()) == Some("tick") {
            tracks = Json::Arr(sys);
            now = v.get("now_ms").cloned().unwrap_or(Json::Null);
        }
    }
    let mut m = BTreeMap::new();
    m.insert("lines".into(), Json::Int(lines));
    m.insert("events".into(), Json::Obj(events.into_iter().map(|(k, n)| (k.into(), Json::Int(n))).collect()));
    m.insert("now_ms".into(), now);
    m.insert("tracks".into(), tracks);
    Json::Obj(m)
}

/// Every installed pack under `dir` as (function, pack), sorted by pack name.
pub fn installed_packs(dir: &Path) -> Vec<(String, String)> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| rd.flatten().filter(|e| e.path().join("pack.def").is_file()).filter_map(|e| e.file_name().into_string().ok()).collect())
        .unwrap_or_default();
    names.sort();
    names
        .into_iter()
        .filter_map(|n| {
            let f = n.split('-').next()?.to_string();
            crate::config::FUNCTIONS.contains(&f.as_str()).then_some((f, n))
        })
        .collect()
}

/// A browser sends its client certificate, and on the local listener reaches
/// the API, on requests that another site's page starts. Those are refused:
/// a request is accepted only when it carries no browser marks, or marks that
/// say the page came from this same origin. `Sec-Fetch-Site` is sent by every
/// current browser; `Origin` is the check for one that does not send it.
fn cross_site(req: &Request) -> Option<String> {
    if let Some(site) = req.headers.get("sec-fetch-site") {
        if site != "same-origin" && site != "none" {
            return Some(format!("Sec-Fetch-Site is {site}"));
        }
    }
    if let Some(origin) = req.headers.get("origin") {
        let host = req.headers.get("host").map(String::as_str).unwrap_or("");
        let o = origin.split_once("://").map(|(_, h)| h).unwrap_or(origin.as_str());
        if origin == "null" || !o.eq_ignore_ascii_case(host) {
            return Some(format!("Origin {origin} is not this API ({host})"));
        }
    }
    None
}

/// On the local listener, the Host a browser names must be this machine, so
/// a page whose own name was pointed at 127.0.0.1 cannot read the API. Only
/// a browser's request is checked (it carries `Sec-Fetch-*`): a program on
/// this host may name the host as it likes.
fn host_is_local(req: &Request, listen: &str) -> bool {
    if !req.headers.keys().any(|k| k.starts_with("sec-fetch-")) {
        return true;
    }
    let Some(host) = req.headers.get("host") else { return true };
    let name = match host.rsplit_once(':') {
        Some((n, port)) if port.bytes().all(|b| b.is_ascii_digit()) => n,
        _ => host.as_str(),
    };
    let name = name.trim_start_matches('[').trim_end_matches(']');
    let listen_name = listen.rsplit_once(':').map(|(n, _)| n.trim_start_matches('[').trim_end_matches(']')).unwrap_or(listen);
    let own = std::fs::read_to_string("/proc/sys/kernel/hostname").map(|h| h.trim().to_string()).unwrap_or_default();
    name.eq_ignore_ascii_case("localhost")
        || name == listen_name
        || (!own.is_empty() && name.eq_ignore_ascii_case(&own))
        || name.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
}

pub fn error(status: u16, what: &str, fix: &str) -> Response {
    let mut m = BTreeMap::new();
    m.insert("error".into(), Json::Str(what.into()));
    if !fix.is_empty() {
        m.insert("fix".into(), Json::Str(fix.into()));
    }
    Response::json(status, Json::Obj(m).to_string())
}

pub struct Server {
    config: Config,
    tx: Mutex<SyncSender<Input>>,
    token: String,
    audit: Mutex<Option<crate::rotate::Rotating>>,
}

/// Connections handled at once, per listener. Each listener has its own
/// budget, so callers on the mesh or the metrics port cannot use up the
/// local listener's (where `health` and the operator's verbs arrive).
const LOCAL_CONNECTIONS: usize = 16;
const MESH_CONNECTIONS: usize = 32;
const METRICS_CONNECTIONS: usize = 4;

impl Server {
    pub fn config(&self) -> &Config {
        &self.config
    }

    /// One agent call: identity, tool, the SHA-256 of its inputs, and the outcome.
    pub fn audit_agent(&self, who: &Identity, tool: &str, inputs_sha256: &str, outcome: &str) {
        let mut m = BTreeMap::new();
        m.insert("time_ms".into(), Json::Int(crate::service::wall_ms()));
        m.insert("who".into(), Json::Str(who.name.clone()));
        m.insert("via".into(), Json::Str(who.via.into()));
        m.insert("role".into(), Json::Str(who.role.name().into()));
        m.insert("agent_tool".into(), Json::Str(tool.into()));
        m.insert("inputs_sha256".into(), Json::Str(inputs_sha256.into()));
        m.insert("outcome".into(), Json::Str(outcome.into()));
        if let Ok(mut f) = self.audit.lock() {
            if let Some(f) = f.as_mut() {
                let _ = f.line(&Json::Obj(m).to_string());
            }
        }
    }

    fn audit(&self, who: &Identity, req: &Request, status: u16) {
        let mut m = BTreeMap::new();
        m.insert("time_ms".into(), Json::Int(crate::service::wall_ms()));
        m.insert("who".into(), Json::Str(who.name.clone()));
        m.insert("via".into(), Json::Str(who.via.into()));
        m.insert("role".into(), Json::Str(who.role.name().into()));
        m.insert("method".into(), Json::Str(req.method.clone()));
        m.insert("path".into(), Json::Str(req.path.clone()));
        if !req.body.is_empty() && req.body.len() <= 4096 {
            if let Ok(b) = json::parse(&String::from_utf8_lossy(&req.body)) {
                m.insert("body".into(), b);
            }
        }
        m.insert("status".into(), Json::Int(status as i64));
        if let Ok(mut f) = self.audit.lock() {
            if let Some(f) = f.as_mut() {
                let _ = f.line(&Json::Obj(m).to_string());
            }
        }
    }

    /// Answers one request from one identity.
    pub fn handle(&self, req: &Request, who: Identity) -> Response {
        let (i, args) = match route(&req.method, &req.path) {
            Ok(r) => r,
            Err((s, e)) => return error(s, &e, ""),
        };
        if let Some(why) = cross_site(req) {
            self.audit(&who, req, 403);
            return error(403, &format!("a page from another site may not call this API ({why})"), "open the operator page from the runner itself: /ui on this address");
        }
        if who.via == "local" && !host_is_local(req, &self.config.api.listen) {
            self.audit(&who, req, 403);
            return error(403, "the local API answers only requests addressed to this machine", "use http://localhost or 127.0.0.1 with the API port");
        }
        let (method, _, need, _) = ROUTES[i];
        if who.role < need {
            let r = error(
                403,
                &format!("{} {} needs the role {}; {} has {}", req.method, req.path, need.name(), who.name, who.role.name()),
                if who.via == "local" { "run the command with sudo" } else { "ask the runner's administrator to allow this certificate in api.mesh.allow" },
            );
            self.audit(&who, req, 403);
            return r;
        }
        let resp = self.dispatch(i, args, req, &who);
        // Agent calls are audited per tool, with their inputs digest (mcp.rs, agentic.rs).
        let agent_route = matches!(ROUTES[i].1, "/mcp" | "/v1/why/{track}" | "/v1/source");
        if (method != "GET" && ROUTES[i].1 != "/v1/replay" || resp.status == 403 || resp.status == 401) && !agent_route {
            self.audit(&who, req, resp.status);
        }
        resp
    }

    fn dispatch(&self, i: usize, args: Vec<String>, req: &Request, who: &Identity) -> Response {
        let ask = match ROUTES[i].1 {
            "/v1/status" => Ask::Status,
            "/v1/health" => Ask::Health,
            "/v1/pipeline" => Ask::Pipeline,
            "/v1/pipeline/{function}" => {
                let body = String::from_utf8_lossy(&req.body);
                let pack = json::parse(&body).ok().and_then(|v| v.get("pack").and_then(|p| p.as_str()).map(str::to_string));
                let Some(pack) = pack else {
                    return error(400, "the body must be {\"pack\": \"<pack name>\"}", "goat-processors pack ls lists the names");
                };
                Ask::PackUse { function: args[0].clone(), pack }
            }
            "/v1/stop" => Ask::Stop,
            "/v1/start" => Ask::Start,
            "/v1/metrics" => Ask::Metrics,
            "/v1/metrics/prometheus" => Ask::Prometheus,
            "/v1/tracks" => Ask::Tracks,
            "/v1/explain/{track}" => Ask::Explain(args[0].clone()),
            "/v1/view" => Ask::View,
            "/v1/proposals" if req.method == "GET" => Ask::Proposals,
            "/v1/proposals" => {
                let body = json::parse(&String::from_utf8_lossy(&req.body)).ok();
                let f = |k: &str| body.as_ref().and_then(|b| b.get(k)).and_then(|v| v.as_str()).map(str::to_string);
                match (f("function"), f("pack")) {
                    (Some(function), Some(pack)) => Ask::Propose { function, pack, reason: f("reason").unwrap_or_default() },
                    _ => return error(400, "the body must be {\"function\": ..., \"pack\": ..., \"reason\": ...}", ""),
                }
            }
            p if p.starts_with("/v1/proposals/{id}/") => Ask::Decide { id: args[0].clone(), verb: p.rsplit('/').next().unwrap_or("").to_string() },
            "/v1/packs" => return self.packs(),
            "/v1/replay" => return self.replay(req),
            "/v1/audit" => return self.read_audit(req),
            "/v1/routes" => return routes_json(),
            "/ui" => return crate::fieldkit::page(),
            "/v1/source" => return self.publish(req, who),
            "/v1/why/{track}" => return crate::agentic::why(self, who, &args[0], req.query.get("endpoint").map(String::as_str)),
            "/mcp" => {
                if !self.config.agents.mcp {
                    return error(404, "the MCP endpoint is off (agents.mcp: false)", "");
                }
                return crate::mcp::handle(self, req, who);
            }
            _ => return error(500, "unrouted", ""),
        };
        let (rtx, rrx) = channel();
        let sent = self.tx.lock().map(|tx| tx.send(Input::Api(Call { ask, who: who.clone(), reply: rtx })).is_ok()).unwrap_or(false);
        if !sent {
            return error(503, "the service loop has stopped", "sudo systemctl restart goat-processors");
        }
        rrx.recv_timeout(Duration::from_secs(10)).unwrap_or_else(|_| error(503, "the service loop did not answer within 10 s", "sudo journalctl -u goat-processors -n 50"))
    }

    fn packs(&self) -> Response {
        let list = installed_packs(&self.config.packs_dir)
            .into_iter()
            .map(|(f, n)| {
                let mut m = BTreeMap::new();
                m.insert("function".into(), Json::Str(f));
                m.insert("pack".into(), Json::Str(n));
                Json::Obj(m)
            })
            .collect();
        Response::json(200, Json::Arr(list).to_string())
    }

    fn replay(&self, req: &Request) -> Response {
        let mut text = String::from_utf8_lossy(&req.body).into_owned();
        // The operator page sends the file as one JSON string; a replay file
        // itself is never a bare JSON string, so this form is unambiguous.
        if text.trim_start().starts_with('"') {
            if let Ok(Json::Str(inner)) = json::parse(&text) {
                text = inner;
            }
        }
        let file = match crate::replay::read(&text) {
            Ok(f) => f,
            Err(e) => return error(400, &format!("the body is not a replay file: {e}"), "send a vector, JSON lines of reports, or JSON lines of ingest and tick steps"),
        };
        let mut p = match crate::pipeline::Pipeline::from_config(&self.config) {
            Ok(p) => p,
            Err(e) => return error(500, &e, ""),
        };
        let trace = req.query.get("trace").is_some_and(|v| v == "true" || v == "1");
        let mut out = String::new();
        crate::replay::run(&mut p, &file, self.config.tick_ms, &self.config.packs_dir, trace, |l| {
            out.push_str(&l);
            out.push('\n');
        });
        if req.headers.get("accept").is_some_and(|a| a.split(',').any(|x| x.trim().starts_with("application/json"))) {
            return Response::json(200, replay_summary(&out).to_string());
        }
        Response::text(200, "application/x-ndjson", out)
    }

    /// An agent publishes reports as its source (docs/design/agentic-ai.md 4.1).
    /// Each report must carry the source id `agents.sources` gives the caller
    /// and `provenance.model`; the runner sets `provenance.kind` to `agent`
    /// and `provenance.agent` to the caller's identity and `provenance.checked`
    /// to true (a report from any other input never carries it), and ingests them as
    /// any other input (recorded, so a replay is exact).
    pub fn publish(&self, req: &Request, who: &Identity) -> Response {
        let digest = crate::mcp::digest(&String::from_utf8_lossy(&req.body));
        let refuse = |status: u16, what: String, fix: &str| {
            self.audit_agent(who, "publish", &digest, &format!("refused: {what}"));
            error(status, &what, fix)
        };
        let Some(grant) = self.config.agents.sources.iter().find(|g| g.who == who.name) else {
            return refuse(403, format!("{} is not an agent source (agents.sources)", who.name), "the site lists each publishing identity and its source id in agents.sources");
        };
        let reports = match crate::fabric::decode("api/v1/source", &req.body) {
            crate::fabric::Input::Reports(r) if !r.is_empty() => r,
            _ => return refuse(400, "the body is not a report, a list of reports, or JSON lines of reports".into(), ""),
        };
        let mut stamped = Vec::new();
        for (i, r) in reports.into_iter().enumerate() {
            let src = r.get("track.source_id").and_then(|v| v.as_str()).unwrap_or("");
            if src != grant.source_id {
                return refuse(403, format!("report {i}: track.source_id is {src:?}; {} may publish only as {:?}", who.name, grant.source_id), "");
            }
            if r.get("provenance.model").and_then(|v| v.as_str()).is_none() {
                return refuse(400, format!("report {i}: no provenance.model"), "name the model and version that produced the report");
            }
            let mut r = r;
            if let Json::Obj(m) = &mut r {
                m.insert("provenance.kind".into(), Json::Str("agent".into()));
                m.insert("provenance.agent".into(), Json::Str(who.name.clone()));
                m.insert("provenance.checked".into(), Json::Bool(true));
            }
            stamped.push(r);
        }
        let n = stamped.len();
        let sent = self.tx.lock().map(|tx| tx.send(Input::Checked(stamped)).is_ok()).unwrap_or(false);
        if !sent {
            return error(503, "the service loop has stopped", "");
        }
        self.audit_agent(who, "publish", &digest, &format!("accepted {n} reports as {}", grant.source_id));
        let mut m = BTreeMap::new();
        m.insert("accepted".into(), Json::Int(n as i64));
        m.insert("source_id".into(), Json::Str(grant.source_id.clone()));
        Response::json(202, Json::Obj(m).to_string())
    }

    fn read_audit(&self, req: &Request) -> Response {
        let limit: usize = req.query.get("limit").and_then(|v| v.parse().ok()).unwrap_or(100).min(10_000);
        let text = std::fs::read_to_string(&self.config.api.audit_file).unwrap_or_default();
        let lines: Vec<&str> = text.lines().collect();
        let tail = &lines[lines.len().saturating_sub(limit)..];
        let list: Vec<Json> = tail.iter().filter_map(|l| json::parse(l).ok()).collect();
        Response::json(200, Json::Arr(list).to_string())
    }
}

pub fn routes_json() -> Response {
    let list = ROUTES
        .iter()
        .map(|(m, p, r, d)| {
            let mut o = BTreeMap::new();
            o.insert("method".into(), Json::Str((*m).into()));
            o.insert("path".into(), Json::Str((*p).into()));
            o.insert("role".into(), Json::Str(r.name().into()));
            o.insert("does".into(), Json::Str((*d).into()));
            Json::Obj(o)
        })
        .collect();
    Response::json(200, Json::Arr(list).to_string())
}

/// A fresh random token, from the kernel's random source.
fn new_token() -> Result<String, String> {
    use std::io::Read;
    let mut b = [0u8; 32];
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)).map_err(|e| format!("random token: {e}"))?;
    Ok(b.iter().map(|x| format!("{x:02x}")).collect())
}

fn write_token(path: &Path, token: &str) -> Result<(), String> {
    if let Some(d) = path.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let _ = std::fs::remove_file(path);
    let mut o = OpenOptions::new();
    o.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    let mut f = o.open(path).map_err(|e| format!("cannot write the API token {}: {e}", path.display()))?;
    f.write_all(token.as_bytes()).map_err(|e| e.to_string())
}

/// Reads the local token, when this user may (root, or the service user).
pub fn read_token(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty())
}

fn local_identity(server: &Server, req: &Request) -> Identity {
    let presented = req.headers.get("authorization").and_then(|a| a.strip_prefix("Bearer ")).map(str::trim);
    if presented.is_some_and(|t| constant_eq(t.as_bytes(), server.token.as_bytes())) {
        Identity { name: "local-admin".into(), role: Role::Operate, via: "local" }
    } else {
        Identity { name: "local".into(), role: Role::Read, via: "local" }
    }
}

fn constant_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Starts the listeners. Requests that need the service loop go to `tx`.
pub fn start(c: &Config, tx: SyncSender<Input>) -> Result<Arc<Server>, String> {
    let token = new_token()?;
    write_token(&c.api.token_file, &token)?;
    let audit = crate::rotate::Rotating::open(&c.api.audit_file, c.api.audit_max_mb, c.api.audit_keep).ok();
    if audit.is_none() {
        eprintln!("warning: cannot open the audit file {}; requests are not audited", c.api.audit_file.display());
    }
    let server = Arc::new(Server { config: c.clone(), tx: Mutex::new(tx), token, audit: Mutex::new(audit) });

    let local = TcpListener::bind(&c.api.listen).map_err(|e| format!("cannot listen for the API on {}: {e}", c.api.listen))?;
    let s = server.clone();
    let budget = Arc::new(AtomicUsize::new(0));
    std::thread::spawn(move || {
        for stream in local.incoming().flatten() {
            let s = s.clone();
            spawn_limited(&budget, LOCAL_CONNECTIONS, move || {
                let mut stream = http::Deadline::new(stream, http::REQUEST_DEADLINE);
                let resp = match http::read_request(&mut stream) {
                    Ok(req) => {
                        let who = local_identity(&s, &req);
                        s.handle(&req, who)
                    }
                    Err((st, e)) => error(st, &e, ""),
                };
                let _ = http::write_response(&mut stream, &resp);
            });
        }
    });

    if let Some(ml) = &c.api.metrics_listen {
        let listener = TcpListener::bind(ml).map_err(|e| format!("cannot listen for metrics on {ml}: {e}"))?;
        let s = server.clone();
        let budget = Arc::new(AtomicUsize::new(0));
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let s = s.clone();
                spawn_limited(&budget, METRICS_CONNECTIONS, move || {
                    let mut stream = http::Deadline::new(stream, http::REQUEST_DEADLINE);
                    // Only GET /metrics; every other request is refused here,
                    // so this port can never reach a route that reads tracks
                    // or changes anything.
                    let resp = match http::read_request(&mut stream) {
                        Ok(req) if req.method == "GET" && req.path == "/metrics" => {
                            let mut req = req;
                            req.path = "/v1/metrics/prometheus".into();
                            s.handle(&req, Identity { name: "metrics".into(), role: Role::Read, via: "metrics" })
                        }
                        Ok(_) => error(404, "this port serves only GET /metrics", "use the API for anything else"),
                        Err((st, e)) => error(st, &e, ""),
                    };
                    let _ = http::write_response(&mut stream, &resp);
                });
            }
        });
    }

    if let Some(m) = &c.api.mesh {
        let tls = m.tls.clone().or_else(|| c.fabric.as_ref().and_then(|f| f.tls.clone())).ok_or("api.mesh has no certificates")?;
        let cfg = http::tls_config(&tls.root_ca, &tls.certificate, &tls.private_key)?;
        let allow: BTreeMap<String, Role> = m.allow.iter().map(|a| (a.name.clone(), a.role)).collect();
        let listener = TcpListener::bind(&m.listen).map_err(|e| format!("cannot listen for the mesh API on {}: {e}", m.listen))?;
        let s = server.clone();
        let budget = Arc::new(AtomicUsize::new(0));
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let (s, cfg, allow) = (s.clone(), cfg.clone(), allow.clone());
                spawn_limited(&budget, MESH_CONNECTIONS, move || {
                    let tcp = http::Deadline::new(stream, http::REQUEST_DEADLINE);
                    let Ok(conn) = rustls::ServerConnection::new(cfg) else { return };
                    let mut tls = rustls::StreamOwned::new(conn, tcp);
                    // The handshake completes on the first read; a client
                    // without a certificate the CA signed fails here.
                    let req = http::read_request(&mut tls);
                    let name = http::peer_name(&tls.conn);
                    let resp = match (req, name) {
                        (Ok(req), Some(name)) => match allow.get(&name) {
                            Some(role) => s.handle(&req, Identity { name, role: *role, via: "mesh" }),
                            None => {
                                let who = Identity { name: name.clone(), role: Role::Read, via: "mesh" };
                                s.audit(&who, &req, 403);
                                error(403, &format!("the certificate {name:?} is not in api.mesh.allow"), "ask the runner's administrator to add it")
                            }
                        },
                        (Err((st, e)), _) => error(st, &e, ""),
                        (Ok(_), None) => error(401, "no client certificate", "connect with a certificate the site CA signed"),
                    };
                    let _ = http::write_response(&mut tls, &resp);
                    tls.conn.send_close_notify();
                    let _ = tls.flush();
                });
            }
        });
    }
    Ok(server)
}

fn spawn_limited(busy: &Arc<AtomicUsize>, max: usize, f: impl FnOnce() + Send + 'static) {
    if busy.fetch_add(1, Ordering::SeqCst) >= max {
        busy.fetch_sub(1, Ordering::SeqCst);
        return; // dropped: the connection closes
    }
    let busy = busy.clone();
    std::thread::spawn(move || {
        f();
        busy.fetch_sub(1, Ordering::SeqCst);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes() {
        assert!(matches!(route("GET", "/v1/status"), Ok((0, _))));
        assert_eq!(route("PUT", "/v1/pipeline/correlate").unwrap().1, vec!["correlate".to_string()]);
        assert_eq!(route("GET", "/v1/explain/s%201").unwrap().1, vec!["s 1".to_string()]);
        assert_eq!(route("DELETE", "/v1/status").unwrap_err().0, 405);
        assert_eq!(route("GET", "/v2/x").unwrap_err().0, 404);
        assert!(constant_eq(b"ab", b"ab") && !constant_eq(b"ab", b"ac") && !constant_eq(b"a", b"ab"));
    }
}
