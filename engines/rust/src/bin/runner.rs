//! The command-line runner of tools/perf/README.md, "Runner contract":
//!
//! ```text
//! runner --function <correlate|filter|fuse|quality> --pack <dir> --steps <file>
//!        [--events <file>] [--trace]
//! ```
//!
//! Reads and parses the steps file, loads the pack, then calls `ingest` or
//! `tick` for each step in order and `snapshot()` after the last. Standard
//! output is one line of counters; diagnostics go to standard error.

use std::fs;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Instant;

use goat_correlator::{filter_fn, fuse, json, quality, Json, StepResult};

/// One of the four engines behind one set of calls.
enum Engine {
    Correlate(goat_correlator::Engine),
    Filter(filter_fn::Engine),
    Fuse(fuse::Engine),
    Quality(quality::Engine),
}

impl Engine {
    fn load(function: &str, pack: &Path) -> Result<Engine, String> {
        Ok(match function {
            "correlate" => Engine::Correlate(goat_correlator::Engine::new(goat_correlator::load_pack(pack)?)),
            "filter" => Engine::Filter(filter_fn::Engine::new(filter_fn::load_pack(pack)?)),
            "fuse" => Engine::Fuse(fuse::Engine::new(fuse::load_pack(pack)?)),
            "quality" => Engine::Quality(quality::Engine::new(quality::load_pack(pack)?)),
            other => return Err(format!("unknown function: {:?}", other)),
        })
    }

    fn ingest(&mut self, report: &Json) -> StepResult {
        match self {
            Engine::Correlate(e) => e.ingest(report),
            Engine::Filter(e) => e.ingest(report),
            Engine::Fuse(e) => e.ingest(report),
            Engine::Quality(e) => e.ingest(report),
        }
    }

    fn tick(&mut self, now_ms: i64) -> StepResult {
        match self {
            Engine::Correlate(e) => e.tick(now_ms),
            Engine::Filter(e) => e.tick(now_ms),
            Engine::Fuse(e) => e.tick(now_ms),
            Engine::Quality(e) => e.tick(now_ms),
        }
    }

    fn snapshot(&self) -> Json {
        match self {
            Engine::Correlate(e) => e.snapshot(),
            Engine::Filter(e) => e.snapshot(),
            Engine::Fuse(e) => e.snapshot(),
            Engine::Quality(e) => e.snapshot(),
        }
    }
}

struct Args {
    function: String,
    pack: PathBuf,
    steps: PathBuf,
    events: Option<PathBuf>,
    trace: bool,
}

fn parse_args() -> Result<Args, String> {
    let mut function = None;
    let mut pack = None;
    let mut steps = None;
    let mut events = None;
    let mut trace = false;
    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        let mut value = || it.next().ok_or_else(|| format!("{} needs a value", a));
        match a.as_str() {
            "--function" => function = Some(value()?),
            "--pack" => pack = Some(PathBuf::from(value()?)),
            "--steps" => steps = Some(PathBuf::from(value()?)),
            "--events" => events = Some(PathBuf::from(value()?)),
            "--trace" => trace = true,
            other => return Err(format!("unknown argument: {:?}", other)),
        }
    }
    Ok(Args {
        function: function.ok_or("--function is required")?,
        pack: pack.ok_or("--pack is required")?,
        steps: steps.ok_or("--steps is required")?,
        events,
        trace,
    })
}

/// A step: `ingest` (a report) or `tick` (an integer `now_ms`).
enum Step<'a> {
    Ingest(&'a Json),
    Tick(i64),
}

fn steps_of(doc: &Json) -> Result<Vec<Step<'_>>, String> {
    let steps = doc.get("steps").and_then(Json::as_array).ok_or("the steps file has no steps list")?;
    steps
        .iter()
        .enumerate()
        .map(|(i, s)| match (s.get("ingest"), s.get("tick")) {
            (Some(report), _) => Ok(Step::Ingest(report)),
            (None, Some(t)) => t.as_i64().map(Step::Tick).ok_or_else(|| format!("steps[{}]: tick is not an integer", i)),
            (None, None) => Err(format!("steps[{}]: needs ingest or tick", i)),
        })
        .collect()
}

fn nanos(start: Instant) -> u128 {
    start.elapsed().as_nanos()
}

fn run(args: &Args) -> Result<String, String> {
    let t0 = Instant::now();
    let text = fs::read_to_string(&args.steps).map_err(|e| format!("{}: {}", args.steps.display(), e))?;
    let doc = json::parse(&text).map_err(|e| format!("{}: {}", args.steps.display(), e))?;
    let steps = steps_of(&doc)?;
    let parse_ns = nanos(t0);

    let t1 = Instant::now();
    let mut engine = Engine::load(&args.function, &args.pack)?;
    let load_ns = nanos(t1);

    let (mut ingest, mut tick) = (0usize, 0usize);
    let mut results = Vec::with_capacity(steps.len());
    let t2 = Instant::now();
    for step in &steps {
        results.push(match step {
            Step::Ingest(report) => {
                ingest += 1;
                engine.ingest(report)
            }
            Step::Tick(now_ms) => {
                tick += 1;
                engine.tick(*now_ms)
            }
        });
    }
    let snapshot = engine.snapshot();
    let run_ns = nanos(t2);

    let events: usize = results.iter().map(|r| r.events.len()).sum();
    let trace_records: usize = results.iter().map(|r| r.trace.len()).sum();

    if let Some(path) = &args.events {
        let file = fs::File::create(path).map_err(|e| format!("{}: {}", path.display(), e))?;
        let mut w = BufWriter::new(file);
        let io = |e: std::io::Error| format!("{}: {}", path.display(), e);
        for (i, r) in results.into_iter().enumerate() {
            let mut line = vec![("step", Json::Int(i as i64)), ("events", Json::Arr(r.events))];
            if args.trace {
                line.push(("trace", Json::Arr(r.trace)));
            }
            writeln!(w, "{}", json::obj(line)).map_err(io)?;
        }
        writeln!(w, "{}", json::obj(vec![("snapshot", snapshot)])).map_err(io)?;
        w.flush().map_err(io)?;
    }

    let pack_name = args.pack.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let counters = json::obj(vec![
        ("engine", "rust".into()),
        ("function", args.function.as_str().into()),
        ("pack", pack_name.into()),
        ("steps", Json::Int(steps.len() as i64)),
        ("ingest", Json::Int(ingest as i64)),
        ("tick", Json::Int(tick as i64)),
        ("events", Json::Int(events as i64)),
        ("trace_records", Json::Int(trace_records as i64)),
        ("parse_ns", Json::Int(parse_ns as i64)),
        ("load_ns", Json::Int(load_ns as i64)),
        ("run_ns", Json::Int(run_ns as i64)),
    ]);
    Ok(counters.to_string())
}

fn main() -> ExitCode {
    let result = parse_args().and_then(|args| run(&args));
    match result {
        Ok(counters) => {
            println!("{}", counters);
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("runner: {}", e);
            ExitCode::FAILURE
        }
    }
}
