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
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use goat_correlator::json::{self, Json};

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
    Tracks,
    Explain(String),
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
    ("GET", "/v1/tracks", Role::Read, "the system tracks of the latest tick"),
    ("GET", "/v1/explain/{track}", Role::Read, "the events and trace records behind one system track"),
    ("POST", "/v1/replay", Role::Read, "run a replay file (the body) through a separate copy of the pipeline"),
    ("GET", "/v1/audit", Role::Operate, "the latest audit lines; query limit (default 100)"),
    ("GET", "/v1/routes", Role::Read, "this table"),
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

pub fn error(status: u16, what: &str, fix: &str) -> Response {
    let mut m = BTreeMap::new();
    m.insert("error".to_string(), Json::Str(what.into()));
    if !fix.is_empty() {
        m.insert("fix".into(), Json::Str(fix.into()));
    }
    Response::json(status, Json::Obj(m).to_string())
}

pub struct Server {
    config: Config,
    tx: Mutex<Sender<Input>>,
    token: String,
    audit: Mutex<Option<std::fs::File>>,
    busy: AtomicUsize,
}

const MAX_CONNECTIONS: usize = 32;

impl Server {
    fn audit(&self, who: &Identity, req: &Request, status: u16) {
        let mut m = BTreeMap::new();
        m.insert("time_ms".to_string(), Json::Int(crate::service::wall_ms()));
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
                let _ = writeln!(f, "{}", Json::Obj(m));
            }
        }
    }

    /// Answers one request from one identity.
    pub fn handle(&self, req: &Request, who: Identity) -> Response {
        let (i, args) = match route(&req.method, &req.path) {
            Ok(r) => r,
            Err((s, e)) => return error(s, &e, ""),
        };
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
        if method != "GET" && ROUTES[i].1 != "/v1/replay" || resp.status == 403 || resp.status == 401 {
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
            "/v1/tracks" => Ask::Tracks,
            "/v1/explain/{track}" => Ask::Explain(args[0].clone()),
            "/v1/packs" => return self.packs(),
            "/v1/replay" => return self.replay(req),
            "/v1/audit" => return self.read_audit(req),
            "/v1/routes" => return routes_json(),
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
        let dir = &self.config.packs_dir;
        let mut names: Vec<String> = std::fs::read_dir(dir)
            .map(|rd| rd.flatten().filter(|e| e.path().join("pack.def").is_file()).filter_map(|e| e.file_name().into_string().ok()).collect())
            .unwrap_or_default();
        names.sort();
        let list = names
            .iter()
            .filter_map(|n| {
                let f = n.split('-').next()?;
                crate::config::FUNCTIONS.contains(&f).then(|| {
                    let mut m = BTreeMap::new();
                    m.insert("function".to_string(), Json::Str(f.into()));
                    m.insert("pack".into(), Json::Str(n.clone()));
                    Json::Obj(m)
                })
            })
            .collect();
        Response::json(200, Json::Arr(list).to_string())
    }

    fn replay(&self, req: &Request) -> Response {
        let text = String::from_utf8_lossy(&req.body);
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
        Response::text(200, "application/x-ndjson", out)
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
            o.insert("method".to_string(), Json::Str((*m).into()));
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
pub fn start(c: &Config, tx: Sender<Input>) -> Result<Arc<Server>, String> {
    let token = new_token()?;
    write_token(&c.api.token_file, &token)?;
    let audit = if let Some(d) = c.api.audit_file.parent() {
        let _ = std::fs::create_dir_all(d);
        OpenOptions::new().create(true).append(true).open(&c.api.audit_file).ok()
    } else {
        None
    };
    if audit.is_none() {
        eprintln!("warning: cannot open the audit file {}; requests are not audited", c.api.audit_file.display());
    }
    let server = Arc::new(Server { config: c.clone(), tx: Mutex::new(tx), token, audit: Mutex::new(audit), busy: AtomicUsize::new(0) });

    let local = TcpListener::bind(&c.api.listen).map_err(|e| format!("cannot listen for the API on {}: {e}", c.api.listen))?;
    let s = server.clone();
    std::thread::spawn(move || {
        for stream in local.incoming().flatten() {
            let s = s.clone();
            spawn_limited(&s.clone(), move || {
                let mut stream = stream;
                stream.set_read_timeout(Some(Duration::from_secs(10))).ok();
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

    if let Some(m) = &c.api.mesh {
        let tls = m.tls.clone().or_else(|| c.fabric.as_ref().and_then(|f| f.tls.clone())).ok_or("api.mesh has no certificates")?;
        let cfg = http::tls_config(&tls.root_ca, &tls.certificate, &tls.private_key)?;
        let allow: BTreeMap<String, Role> = m.allow.iter().map(|a| (a.name.clone(), a.role)).collect();
        let listener = TcpListener::bind(&m.listen).map_err(|e| format!("cannot listen for the mesh API on {}: {e}", m.listen))?;
        let s = server.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let (s, cfg, allow) = (s.clone(), cfg.clone(), allow.clone());
                spawn_limited(&s.clone(), move || {
                    let tcp = stream;
                    tcp.set_read_timeout(Some(Duration::from_secs(10))).ok();
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

fn spawn_limited(s: &Arc<Server>, f: impl FnOnce() + Send + 'static) {
    if s.busy.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
        s.busy.fetch_sub(1, Ordering::SeqCst);
        return; // dropped: the connection closes
    }
    let s = s.clone();
    std::thread::spawn(move || {
        f();
        s.busy.fetch_sub(1, Ordering::SeqCst);
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
