//! goat-processors: the runner and its command line.

mod agentic;
mod api;
mod config;
mod doctor;
mod fabric;
mod fieldkit;
mod http;
mod mcp;
mod model;
mod pipeline;
mod proposals;
mod replay;
mod selftest;
mod service;

use std::io::Write;
use std::path::PathBuf;
use std::process::ExitCode;

const USAGE: &str = "goat-processors: runs a declared pipeline of processing functions on the goat fabric

usage:
  goat-processors run            [-c CONFIG]           run the service (systemd runs this)
  goat-processors config check   [-c CONFIG]           check the config file; exit 1 with what to fix
  goat-processors doctor         [-c CONFIG] [-o json] report what is wrong with the host and the service
  goat-processors replay FILE    [-c CONFIG] [--pack FUNCTION=PACK ...] [--packs-dir DIR]
                                 [--tick-ms N] [--trace] [--snapshot] [--out FILE]
                                 run a file through the pipeline, offline; one JSON line per stage per step;
                                 --snapshot ends with one line holding every stage's whole state
  goat-processors selftest       [-c CONFIG | --packs-dir DIR] [-o json]
                                 replay every vector shipped with the packs; exit 1 on any difference
  goat-processors pack ls        [-c CONFIG | --packs-dir DIR] [-o json]
  goat-processors version

The running service, through its API (each verb is one API route; -o json prints the API's reply):
  goat-processors status                       state, pipeline and counters        GET  /v1/status
  goat-processors view                         what the operator page shows: state, packs per function,
                                               tracks, quality per source, proposals, your role  GET  /v1/view
  goat-processors health                       exit 0 when running and ticking     GET  /v1/health
  goat-processors pipeline                     each function and its running pack  GET  /v1/pipeline
  goat-processors pack use FUNCTION PACK       select a function's pack (sudo)     PUT  /v1/pipeline/FUNCTION
  goat-processors stop                         pause processing (sudo)             POST /v1/stop
  goat-processors start                        resume processing (sudo)            POST /v1/start
  goat-processors metrics                      rate, latency, counts per source    GET  /v1/metrics
  goat-processors tracks                       the system tracks of the last tick  GET  /v1/tracks
  goat-processors explain TRACK                what led to one system track        GET  /v1/explain/TRACK
  goat-processors replay FILE --api            run a file on a copy of the running pipeline  POST /v1/replay
  goat-processors audit                        the latest audit lines (sudo)       GET  /v1/audit
  goat-processors proposals                    every settings proposal              GET  /v1/proposals
  goat-processors propose FUNCTION PACK --reason TEXT   propose a pack; nothing changes yet  POST /v1/proposals
  goat-processors proposal approve|reject|revert ID     decide a proposal (sudo)   POST /v1/proposals/ID/VERB
  goat-processors why TRACK [--endpoint NAME]  a model explains one track, citing trace records  GET /v1/why/TRACK
  goat-processors mcp                          an MCP server on stdin and stdout, for agents on this host  POST /mcp
  The operator page (Fieldkit Processors) is at http://API/ui: each of its actions is one of these verbs.
  options: [-c CONFIG] [--api HOST:PORT] [-o json]. The API address and the token file come from
  CONFIG's api section. Changing anything needs the token, which only root can read: use sudo.

CONFIG defaults to /etc/goat-processors/runner.yaml.";

struct Args {
    rest: Vec<String>,
    config: Option<PathBuf>,
    output: Option<String>,
    packs: Vec<(String, String)>,
    packs_dir: Option<PathBuf>,
    tick_ms: Option<i64>,
    trace: bool,
    snapshot: bool,
    out: Option<PathBuf>,
    api: Option<String>,
    use_api: bool,
    endpoint: Option<String>,
    reason: Option<String>,
}

fn parse_args(argv: Vec<String>) -> Result<Args, String> {
    let mut a = Args { rest: vec![], config: None, output: None, packs: vec![], packs_dir: None, tick_ms: None, trace: false, snapshot: false, out: None, api: None, use_api: false, endpoint: None, reason: None };
    let mut it = argv.into_iter();
    while let Some(x) = it.next() {
        let mut val = |name: &str| it.next().ok_or(format!("{name} needs a value"));
        match x.as_str() {
            "-c" | "--config" => a.config = Some(val(&x)?.into()),
            "-o" | "--output" => a.output = Some(val(&x)?),
            "--pack" => {
                let v = val(&x)?;
                let (f, p) = v.split_once('=').ok_or(format!("--pack {v}: write it as FUNCTION=PACK, for example correlate=correlate-assign-time"))?;
                a.packs.push((f.into(), p.into()));
            }
            "--packs-dir" => a.packs_dir = Some(val(&x)?.into()),
            "--tick-ms" => a.tick_ms = Some(val(&x)?.parse().map_err(|_| "--tick-ms needs a whole number")?),
            "--trace" => a.trace = true,
            "--endpoint" => a.endpoint = Some(val(&x)?),
            "--reason" => a.reason = Some(val(&x)?),
            "--snapshot" => a.snapshot = true,
            "--out" => a.out = Some(val(&x)?.into()),
            "--api" => {
                a.use_api = true;
                // An address may follow: HOST:PORT.
                if let Some(next) = it.clone().next() {
                    if next.contains(':') && !next.starts_with('-') {
                        a.api = it.next();
                    }
                }
            }
            "-h" | "--help" => a.rest.push("help".into()),
            _ if x.starts_with('-') && x.len() > 1 => return Err(format!("unknown option {x}")),
            _ => a.rest.push(x),
        }
    }
    if let Some(o) = &a.output {
        if o != "json" && o != "text" {
            return Err(format!("-o {o}: use json or text"));
        }
    }
    Ok(a)
}

fn config_path(a: &Args) -> PathBuf {
    a.config.clone().unwrap_or_else(|| PathBuf::from(config::DEFAULT_PATH))
}

fn main() -> ExitCode {
    let a = match parse_args(std::env::args().skip(1).collect()) {
        Ok(a) => a,
        Err(e) => {
            eprintln!("{e}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let words: Vec<&str> = a.rest.iter().map(String::as_str).collect();
    let result = match words.as_slice() {
        ["run"] => cmd_run(&a),
        ["config", "check"] => cmd_config_check(&a, None),
        ["config", "check", path] => cmd_config_check(&a, Some(path)),
        ["doctor"] => cmd_doctor(&a),
        ["replay", file] if a.use_api => {
            let body = std::fs::read(file).map_err(|e| format!("cannot read {file}: {e}"));
            match body {
                Ok(b) => api_verb(&a, "POST", format!("/v1/replay{}", if a.trace { "?trace=true" } else { "" }), Some(b), None),
                Err(e) => Err(e),
            }
        }
        ["replay", file] => cmd_replay(&a, file),
        ["pack", "ls"] => cmd_pack_ls(&a),
        ["selftest"] => cmd_selftest(&a),
        ["status"] => api_verb(&a, "GET", "/v1/status".into(), None, Some(show_status)),
        ["view"] => api_verb(&a, "GET", "/v1/view".into(), None, Some(show_view)),
        ["health"] => api_verb(&a, "GET", "/v1/health".into(), None, Some(show_kv)),
        ["pipeline"] => api_verb(&a, "GET", "/v1/pipeline".into(), None, Some(show_pipeline)),
        ["pack", "use", function, pack] => {
            let body = format!("{{\"pack\":{}}}", goat_correlator::json::Json::Str(pack.to_string()));
            api_verb(&a, "PUT", format!("/v1/pipeline/{}", http::encode(function)), Some(body.into_bytes()), Some(show_pipeline))
        }
        ["stop"] => api_verb(&a, "POST", "/v1/stop".into(), None, Some(show_status)),
        ["start"] => api_verb(&a, "POST", "/v1/start".into(), None, Some(show_status)),
        ["metrics"] => api_verb(&a, "GET", "/v1/metrics".into(), None, Some(show_kv)),
        ["tracks"] => api_verb(&a, "GET", "/v1/tracks".into(), None, Some(show_tracks)),
        ["explain", track] => api_verb(&a, "GET", format!("/v1/explain/{}", http::encode(track)), None, Some(show_explain)),
        ["audit"] => api_verb(&a, "GET", "/v1/audit".into(), None, Some(show_lines)),
        ["why", track] => {
            let q = a.endpoint.as_ref().map(|e| format!("?endpoint={}", http::encode(e))).unwrap_or_default();
            api_verb(&a, "GET", format!("/v1/why/{}{q}", http::encode(track)), None, Some(show_why))
        }
        ["mcp"] => cmd_mcp(&a),
        ["proposals"] => api_verb(&a, "GET", "/v1/proposals".into(), None, Some(show_proposals)),
        ["propose", function, pack] => {
            let mut m = std::collections::BTreeMap::new();
            m.insert("function".into(), Json::Str(function.to_string()));
            m.insert("pack".into(), Json::Str(pack.to_string()));
            m.insert("reason".into(), Json::Str(a.reason.clone().unwrap_or_default()));
            api_verb(&a, "POST", "/v1/proposals".into(), Some(Json::Obj(m).to_string().into_bytes()), Some(show_proposal))
        }
        ["proposal", verb @ ("approve" | "reject" | "revert"), id] => {
            api_verb(&a, "POST", format!("/v1/proposals/{}/{verb}", http::encode(id)), None, Some(show_proposal))
        }
        ["version"] | ["--version"] => {
            println!("goat-processors {}", env!("CARGO_PKG_VERSION"));
            Ok(ExitCode::SUCCESS)
        }
        ["help"] | [] => {
            println!("{USAGE}");
            Ok(ExitCode::SUCCESS)
        }
        _ => Err(format!("unknown command: {}\n\n{USAGE}", a.rest.join(" "))),
    };
    match result {
        Ok(code) => code,
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::from(1)
        }
    }
}

fn cmd_run(a: &Args) -> Result<ExitCode, String> {
    let path = config_path(a);
    let c = config::load(&path).map_err(|p| format!("{} is not valid:\n  {}", path.display(), p.join("\n  ")))?;
    service::run(c)?;
    Ok(ExitCode::SUCCESS)
}

fn cmd_config_check(a: &Args, path: Option<&&str>) -> Result<ExitCode, String> {
    let path = path.map(PathBuf::from).unwrap_or_else(|| config_path(a));
    let json = a.output.as_deref() == Some("json");
    let res = config::load(&path);
    if json {
        let problems = res.as_ref().err().cloned().unwrap_or_default();
        let list = goat_correlator::json::Json::Arr(problems.iter().map(|p| goat_correlator::json::Json::Str(p.clone())).collect());
        println!("{{\"file\":{},\"valid\":{},\"problems\":{}}}", goat_correlator::json::Json::Str(path.display().to_string()), res.is_ok(), list);
    }
    match res {
        Ok(c) => {
            if !json {
                println!("{}: valid", path.display());
                for s in &c.pipeline {
                    println!("  {:<10} {}", s.function, c.pack_dir(s).display());
                }
            }
            Ok(ExitCode::SUCCESS)
        }
        Err(problems) => {
            if !json {
                println!("{}: NOT valid, {} problem(s):", path.display(), problems.len());
                for p in problems {
                    println!("  - {p}");
                }
            }
            Ok(ExitCode::from(1))
        }
    }
}

fn cmd_doctor(a: &Args) -> Result<ExitCode, String> {
    let findings = doctor::run(&config_path(a));
    if a.output.as_deref() == Some("json") {
        println!("{}", doctor::to_json(&findings));
    } else {
        print!("{}", doctor::to_text(&findings));
    }
    Ok(if doctor::worst(&findings) == doctor::Level::Fail { ExitCode::from(1) } else { ExitCode::SUCCESS })
}

/// The packs directory: `--packs-dir`, else the config's, else the installed one.
fn packs_dir(a: &Args, c: Option<&config::Config>) -> PathBuf {
    a.packs_dir.clone().or_else(|| c.map(|c| c.packs_dir.clone())).unwrap_or_else(|| PathBuf::from(config::DEFAULT_PACKS_DIR))
}

fn cmd_replay(a: &Args, file: &str) -> Result<ExitCode, String> {
    let text = std::fs::read_to_string(file).map_err(|e| format!("cannot read {file}: {e}"))?;
    let rf = replay::read(&text).map_err(|e| format!("{file}: {e}"))?;
    let c = match &a.config {
        Some(p) => Some(config::load(p).map_err(|e| format!("{} is not valid:\n  {}", p.display(), e.join("\n  ")))?),
        None => None,
    };
    let dir = packs_dir(a, c.as_ref());
    // The pipeline: --pack lines; else the config's; else the vector's own pack.
    let stages: Vec<(String, String)> = if !a.packs.is_empty() {
        a.packs.clone()
    } else if let Some(c) = &c {
        c.pipeline.iter().map(|s| (s.function.clone(), s.pack.clone())).collect()
    } else if let Some(p) = &rf.vector_pack {
        let function = p.split('-').next().unwrap_or("").to_string();
        vec![(function, p.clone())]
    } else {
        return Err("no pipeline: give -c CONFIG or --pack FUNCTION=PACK (the file is not a vector naming its pack)".into());
    };
    let mut built = Vec::new();
    for (function, pack) in &stages {
        let pdir = if pack.contains('/') { PathBuf::from(pack) } else { dir.join(pack) };
        let engine = pipeline::load_stage(function, &pdir).map_err(|e| format!("{function} pack {pack} ({}): {e}", pdir.display()))?;
        built.push(pipeline::Stage { function: function.clone(), pack: pack.clone(), engine });
    }
    let mut p = pipeline::Pipeline::new(built);
    let tick_ms = a.tick_ms.or(c.as_ref().map(|c| c.tick_ms)).unwrap_or(1000);
    let mut sink: Box<dyn Write> = match &a.out {
        Some(path) => Box::new(std::fs::File::create(path).map_err(|e| format!("cannot write {}: {e}", path.display()))?),
        None => Box::new(std::io::stdout().lock()),
    };
    let mut err = None;
    replay::run(&mut p, &rf, tick_ms, &dir, a.trace, |line| {
        if err.is_none() {
            if let Err(e) = writeln!(sink, "{line}") {
                err = Some(e);
            }
        }
    });
    if a.snapshot && err.is_none() {
        if let Err(e) = writeln!(sink, "{{\"snapshot\":{}}}", p.snapshot()) {
            err = Some(e);
        }
    }
    if let Some(e) = err {
        if e.kind() != std::io::ErrorKind::BrokenPipe {
            return Err(format!("writing output: {e}"));
        }
    }
    eprintln!(
        "replayed {} step(s) from {file}: {} report(s), {} tick(s), {} passed every stage",
        rf.steps.len(),
        p.counters.reports_in,
        p.counters.ticks,
        p.counters.reports_out
    );
    Ok(ExitCode::SUCCESS)
}

fn cmd_pack_ls(a: &Args) -> Result<ExitCode, String> {
    let c = a.config.as_ref().and_then(|p| config::load(p).ok());
    let dir = packs_dir(a, c.as_ref());
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .map_err(|e| format!("cannot list {}: {e}", dir.display()))?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().join("pack.def").is_file())
        .filter_map(|e| e.file_name().into_string().ok())
        .collect();
    names.sort();
    let in_use = |n: &str| c.as_ref().is_some_and(|c| c.pipeline.iter().any(|s| s.pack == n));
    let rows: Vec<(String, String, bool)> = names
        .iter()
        .filter_map(|n| {
            let f = n.split('-').next()?.to_string();
            config::FUNCTIONS.contains(&f.as_str()).then(|| (f, n.clone(), in_use(n)))
        })
        .collect();
    if a.output.as_deref() == Some("json") {
        use goat_correlator::json::Json;
        let list = rows
            .iter()
            .map(|(f, n, u)| {
                let mut m = std::collections::BTreeMap::new();
                m.insert("function".into(), Json::Str(f.clone()));
                m.insert("pack".into(), Json::Str(n.clone()));
                m.insert("in_use".into(), Json::Bool(*u));
                Json::Obj(m)
            })
            .collect();
        println!("{}", Json::Arr(list));
    } else {
        for (f, n, u) in rows {
            println!("{:<10} {:<28} {}", f, n, if u { "in use" } else { "" });
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn cmd_selftest(a: &Args) -> Result<ExitCode, String> {
    let c = a.config.as_ref().and_then(|p| config::load(p).ok());
    let dir = packs_dir(a, c.as_ref());
    let (passed, failed) = selftest::run(&dir);
    let total = passed + failed.len();
    if a.output.as_deref() == Some("json") {
        use goat_correlator::json::Json;
        let list = Json::Arr(failed.iter().map(|f| Json::Str(f.clone())).collect());
        println!("{{\"packs_dir\":{},\"vectors\":{total},\"passed\":{passed},\"failed\":{list}}}", Json::Str(dir.display().to_string()));
    } else {
        for f in &failed {
            println!("FAIL {f}");
        }
        println!("{passed} of {total} vectors under {} replay exactly", dir.display());
    }
    if total == 0 {
        return Err(format!("no vectors under {}; check --packs-dir", dir.display()));
    }
    Ok(if failed.is_empty() { ExitCode::SUCCESS } else { ExitCode::from(1) })
}

use goat_correlator::json::Json;

/// The API address and the token, from the config when it can be read.
fn api_target(a: &Args) -> (String, Option<String>) {
    let c = config::load(&config_path(a)).ok();
    let api = c.as_ref().map(|c| c.api.clone()).unwrap_or_default();
    let addr = a.api.clone().unwrap_or(api.listen);
    (addr, api::read_token(&api.token_file))
}

/// Calls one API route. `show` formats a success for a person; None prints the reply as it is.
fn api_verb(a: &Args, method: &str, path: String, body: Option<Vec<u8>>, show: Option<fn(&Json) -> String>) -> Result<ExitCode, String> {
    let (addr, token) = api_target(a);
    let (status, raw) = http::call(&addr, method, &path, token.as_deref(), body.as_deref())?;
    let text = String::from_utf8_lossy(&raw).to_string();
    if a.output.as_deref() == Some("json") || show.is_none() {
        print!("{text}");
        if !text.ends_with('\n') {
            println!();
        }
    } else if let Ok(v) = goat_correlator::json::parse(&text) {
        if (200..300).contains(&status) {
            print!("{}", show.map(|f| f(&v)).unwrap_or_default());
        } else {
            let field = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
            if status == 503 && path == "/v1/health" {
                print!("{}", show.map(|f| f(&v)).unwrap_or_default());
            } else {
                eprintln!("error: {} (HTTP {status})", field("error"));
                if !field("fix").is_empty() {
                    eprintln!("fix: {}", field("fix"));
                }
            }
        }
    }
    Ok(if (200..300).contains(&status) { ExitCode::SUCCESS } else { ExitCode::from(1) })
}

fn s_of(v: &Json, k: &str) -> String {
    match v.get(k) {
        Some(Json::Str(s)) => s.clone(),
        Some(Json::Null) | None => "-".into(),
        Some(x) => x.to_string(),
    }
}

fn show_kv(v: &Json) -> String {
    let mut out = String::new();
    if let Some(m) = v.as_object() {
        for (k, x) in m {
            out.push_str(&format!("{k:<20} {}\n", match x { Json::Str(s) => s.clone(), _ => x.to_string() }));
        }
    }
    out
}

fn show_status(v: &Json) -> String {
    let mut out = format!(
        "{} at {}: {} (version {}, clock {}, tick {} ms)\n",
        s_of(v, "name"), s_of(v, "site"), s_of(v, "state"), s_of(v, "version"), s_of(v, "clock"), s_of(v, "tick_ms")
    );
    if let Some(Json::Arr(p)) = v.get("pipeline") {
        out.push_str(&format!("pipeline: {}\n", p.iter().map(|s| format!("{} = {}", s_of(s, "function"), s_of(s, "pack"))).collect::<Vec<_>>().join(", ")));
    }
    if let Some(c) = v.get("counters") {
        out.push_str(&format!(
            "reports in {}, passed {}, ticks {}, published {}, unreadable {}, dropped while stopped {}\n",
            s_of(c, "reports_in"), s_of(c, "reports_out"), s_of(c, "ticks"), s_of(c, "published"), s_of(c, "unreadable"), s_of(c, "dropped_paused")
        ));
        if let Some(Json::Obj(ps)) = c.get("per_source") {
            for (k, n) in ps {
                out.push_str(&format!("  {k:<24} {n}\n"));
            }
        }
    }
    out.push_str(&format!("output prefix {}, fabric routers {}\n", s_of(v, "output_prefix"), s_of(v, "fabric_routers")));
    out
}

/// `view`: the operator page's one read, as text.
fn show_view(v: &Json) -> String {
    let st = v.get("status").cloned().unwrap_or(Json::Null);
    let hl = v.get("health").cloned().unwrap_or(Json::Null);
    let you = v.get("you").cloned().unwrap_or(Json::Null);
    let mut out = format!(
        "{} at {}: {} ({})\nyou: {} via {}, role {}\n\npipeline:\n",
        s_of(&st, "name"), s_of(&st, "site"), s_of(&st, "state"), s_of(&hl, "detail"), s_of(&you, "name"), s_of(&you, "via"), s_of(&you, "role")
    );
    for p in v.get("pipeline").and_then(|x| x.as_array()).cloned().unwrap_or_default() {
        let packs = p.get("packs").and_then(|x| x.as_array()).map(|a| a.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(" ")).unwrap_or_default();
        out.push_str(&format!("  {:<10} {}  (installed: {packs})\n", s_of(&p, "function"), s_of(&p, "pack")));
    }
    out.push('\n');
    out.push_str(&show_tracks(v));
    out.push_str("\nquality per source:\n");
    for q in v.get("quality").and_then(|x| x.as_array()).cloned().unwrap_or_default() {
        let active = q.get("actions").and_then(|x| x.as_array()).map(|a| a.iter().map(|e| format!("{} ({})", s_of(e, "action"), s_of(e, "rule"))).collect::<Vec<_>>().join(", ")).unwrap_or_default();
        out.push_str(&format!(
            "  {:<24} reports {}, objects with an action {}{}\n",
            s_of(&q, "source"), s_of(&q, "reports"), s_of(&q, "entity_actions"), if active.is_empty() { String::new() } else { format!(", active: {active}") }
        ));
    }
    let waiting: Vec<Json> = v.get("proposals").and_then(|x| x.as_array()).cloned().unwrap_or_default().into_iter().filter(|p| s_of(p, "state") == "pending").collect();
    out.push_str(&format!("\nproposals waiting: {}\n", waiting.len()));
    for p in waiting {
        out.push_str(&format!("  {} {}: {} -> {} by {}: {}\n", s_of(&p, "id"), s_of(&p, "function"), s_of(&p, "previous_pack"), s_of(&p, "pack"), s_of(&p, "by"), s_of(&p, "reason")));
    }
    out
}

fn show_pipeline(v: &Json) -> String {
    let mut out = String::new();
    for s in v.as_array().cloned().unwrap_or_default() {
        let note = if matches!(s.get("as_configured"), Some(Json::Bool(false))) { format!("  (config file: {})", s_of(&s, "configured_pack")) } else { String::new() };
        out.push_str(&format!("{:<10} {}{}\n", s_of(&s, "function"), s_of(&s, "pack"), note));
    }
    out
}

fn show_tracks(v: &Json) -> String {
    let list = v.get("tracks").and_then(|t| t.as_array()).cloned().unwrap_or_default();
    let mut out = format!("{} system tracks at now_ms {}\n", list.len(), s_of(v, "now_ms"));
    if !list.is_empty() {
        out.push_str(&format!("{:<10} {:>11} {:>12} {:>8} {:>8}  members\n", "id", "lat", "lon", "course", "speed"));
    }
    for t in list {
        let id = t.get("system").or_else(|| t.get("group")).and_then(|x| x.as_str()).unwrap_or("-");
        let num = |k: &str, d: usize| t.get(k).and_then(|x| x.as_f64()).map(|x| format!("{x:.d$}")).unwrap_or("-".into());
        let members = t.get("members").and_then(|m| m.as_array()).map(|m| m.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(" ")).unwrap_or_default();
        out.push_str(&format!("{:<10} {:>11} {:>12} {:>8} {:>8}  {}\n", id, num("lat", 5), num("lon", 5), num("course", 0), num("speed_ms", 1), members));
    }
    out
}

fn show_explain(v: &Json) -> String {
    let t = v.get("track").cloned().unwrap_or(Json::Null);
    let id = t.get("system").or_else(|| t.get("group")).and_then(|x| x.as_str()).unwrap_or("-").to_string();
    let mut out = format!("system track {id}: members {}\n", s_of(&t, "members"));
    let events = v.get("events").and_then(|e| e.as_array()).cloned().unwrap_or_default();
    let trace = v.get("trace").and_then(|e| e.as_array()).cloned().unwrap_or_default();
    out.push_str(&format!("{} events and {} trace records name it or its members, from step {}\n\n", events.len(), trace.len(), s_of(v, "from_step")));
    out.push_str("events (step, stage, event):\n");
    for e in events.iter().rev().take(20).collect::<Vec<_>>().into_iter().rev() {
        out.push_str(&format!("  {:>6} {:<9} {}\n", s_of(e, "step"), s_of(e, "stage"), e.get("event").map(|x| x.to_string()).unwrap_or_default()));
    }
    out.push_str("latest trace records (step, stage, record):\n");
    for r in trace.iter().rev().take(20).collect::<Vec<_>>().into_iter().rev() {
        out.push_str(&format!("  {:>6} {:<9} {}\n", s_of(r, "step"), s_of(r, "stage"), r.get("record").map(|x| x.to_string()).unwrap_or_default()));
    }
    if events.len() > 20 || trace.len() > 20 {
        out.push_str("(the 20 latest of each; -o json gives all)\n");
    }
    out
}

fn show_lines(v: &Json) -> String {
    v.as_array().cloned().unwrap_or_default().iter().map(|x| format!("{x}\n")).collect()
}

fn show_why(v: &Json) -> String {
    let mut out = format!(
        "why {}: {} sentences from model endpoint {} ({}), {} records sent, {} uncited sentences removed\n\n",
        s_of(v, "track"),
        v.get("sentences").and_then(|x| x.as_array()).map(|x| x.len()).unwrap_or(0),
        s_of(v, "endpoint"),
        s_of(v, "endpoint_kind"),
        s_of(v, "records_sent"),
        s_of(v, "sentences_removed")
    );
    for snt in v.get("sentences").and_then(|x| x.as_array()).cloned().unwrap_or_default() {
        out.push_str(&format!("{}\n", s_of(&snt, "text")));
        for (c, r) in snt.get("cites").and_then(|x| x.as_array()).cloned().unwrap_or_default().iter().zip(snt.get("records").and_then(|x| x.as_array()).cloned().unwrap_or_default()) {
            let what = r.get("record").or_else(|| r.get("event")).map(|x| x.to_string()).unwrap_or_default();
            out.push_str(&format!("    {} step {} {}: {}\n", c.as_str().unwrap_or(""), s_of(&r, "step"), s_of(&r, "stage"), what));
        }
    }
    out
}

/// An MCP server on stdin and stdout: each JSON-RPC line is posted to the
/// runner's /mcp, as this user (with the token when this user can read it).
fn cmd_mcp(a: &Args) -> Result<ExitCode, String> {
    use std::io::BufRead;
    let (addr, token) = api_target(a);
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    for line in stdin.lock().lines() {
        let line = line.map_err(|e| e.to_string())?;
        if line.trim().is_empty() {
            continue;
        }
        match http::call(&addr, "POST", "/mcp", token.as_deref(), Some(line.as_bytes())) {
            Ok((202, _)) => {}
            Ok((_, body)) => {
                let text = String::from_utf8_lossy(&body);
                if !text.trim().is_empty() {
                    writeln!(stdout, "{}", text.trim()).map_err(|e| e.to_string())?;
                    stdout.flush().ok();
                }
            }
            Err(e) => {
                let id = goat_correlator::json::parse(&line).ok().and_then(|v| v.get("id").cloned()).unwrap_or(Json::Null);
                writeln!(stdout, "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"error\":{{\"code\":-32000,\"message\":{}}}}}", Json::Str(e)).map_err(|e| e.to_string())?;
                stdout.flush().ok();
            }
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn show_proposal(p: &Json) -> String {
    format!(
        "{:<5} {:<12} {:<10} {} -> {}  by {}{}  {}\n",
        s_of(p, "id"),
        s_of(p, "state"),
        s_of(p, "function"),
        s_of(p, "previous_pack"),
        s_of(p, "pack"),
        s_of(p, "by"),
        p.get("decided_by").and_then(|d| d.as_str()).map(|d| format!(", decided by {d}")).unwrap_or_default(),
        s_of(p, "reason")
    )
}

fn show_proposals(v: &Json) -> String {
    let list = v.as_array().cloned().unwrap_or_default();
    if list.is_empty() {
        return "no proposals\n".into();
    }
    list.iter().map(show_proposal).collect()
}
