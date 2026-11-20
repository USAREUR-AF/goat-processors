//! goat-processors: the runner and its command line.

mod config;
mod doctor;
mod fabric;
mod pipeline;
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
}

fn parse_args(argv: Vec<String>) -> Result<Args, String> {
    let mut a = Args { rest: vec![], config: None, output: None, packs: vec![], packs_dir: None, tick_ms: None, trace: false, snapshot: false, out: None };
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
            "--snapshot" => a.snapshot = true,
            "--out" => a.out = Some(val(&x)?.into()),
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
        ["replay", file] => cmd_replay(&a, file),
        ["pack", "ls"] => cmd_pack_ls(&a),
        ["selftest"] => cmd_selftest(&a),
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
    replay::run(&mut p, &rf, tick_ms, a.trace, |line| {
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
