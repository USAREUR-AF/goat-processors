//! Input and output around the engines: the steps file of
//! spec/vector-format.md, the events file and counters of the runner
//! contract (tools/perf/README.md, "Runner contract"). The engines never
//! read a file or a clock; only this module does.

use std::fs;
use std::io::{BufWriter, Write};
use std::path::{Path, PathBuf};
use std::time::Instant;

use crate::function::Function;
use crate::model::json::{self, obj, Json};
use crate::trace::StepResult;
use crate::{correlate, filter, fuse, quality};

/// One step of a steps file: `ingest` (a report) or `tick` (an integer `now_ms`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Step<'a> {
    Ingest(&'a Json),
    Tick(i64),
}

/// The steps of a parsed steps file. Any key besides `ingest` and `tick`, in
/// the file or in a step, is ignored; a step with `ingest` is an ingest.
pub fn steps_of(doc: &Json) -> Result<Vec<Step<'_>>, String> {
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

/// Runs `steps` on `engine` in order: the result of each step, then the
/// snapshot after the last.
pub fn run_steps<F: Function>(engine: &mut F, steps: &[Step]) -> (Vec<StepResult>, Json) {
    let results = steps
        .iter()
        .map(|step| match step {
            Step::Ingest(report) => engine.ingest(report),
            Step::Tick(now_ms) => engine.tick(*now_ms),
        })
        .collect();
    (results, engine.snapshot())
}

/// Writes the events file: one line per step, `{"events", "step"}` and
/// `"trace"` with `trace`, then `{"snapshot"}`.
pub fn write_events(w: &mut impl Write, results: Vec<StepResult>, snapshot: Json, trace: bool) -> std::io::Result<()> {
    for (i, r) in results.into_iter().enumerate() {
        let mut line = vec![("step", Json::Int(i as i64)), ("events", Json::Arr(r.events))];
        if trace {
            line.push(("trace", Json::Arr(r.trace)));
        }
        writeln!(w, "{}", obj(line))?;
    }
    writeln!(w, "{}", obj(vec![("snapshot", snapshot)]))
}

/// The runner's arguments.
#[derive(Debug, Clone, PartialEq)]
pub struct Args {
    pub function: String,
    pub pack: PathBuf,
    pub steps: PathBuf,
    pub events: Option<PathBuf>,
    pub trace: bool,
}

impl Args {
    /// `--function F --pack DIR --steps FILE [--events FILE] [--trace]`.
    pub fn parse(args: impl IntoIterator<Item = String>) -> Result<Args, String> {
        let (mut function, mut pack, mut steps, mut events, mut trace) = (None, None, None, None, false);
        let mut it = args.into_iter();
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
}

/// The runner: the counters line on success, the message on failure.
pub fn run(args: &Args) -> Result<String, String> {
    match args.function.as_str() {
        correlate::Engine::NAME => run_function::<correlate::Engine>(args),
        filter::Engine::NAME => run_function::<filter::Engine>(args),
        fuse::Engine::NAME => run_function::<fuse::Engine>(args),
        quality::Engine::NAME => run_function::<quality::Engine>(args),
        other => Err(format!("unknown function: {:?}", other)),
    }
}

fn run_function<F: Function>(args: &Args) -> Result<String, String> {
    let at = |p: &Path, e: &dyn std::fmt::Display| format!("{}: {}", p.display(), e);
    let t0 = Instant::now();
    let text = fs::read_to_string(&args.steps).map_err(|e| at(&args.steps, &e))?;
    let doc = json::parse(&text).map_err(|e| at(&args.steps, &e))?;
    let steps = steps_of(&doc)?;
    let parse_ns = t0.elapsed().as_nanos();

    let t1 = Instant::now();
    let mut engine = F::new(F::load_pack(&args.pack)?);
    let load_ns = t1.elapsed().as_nanos();

    let t2 = Instant::now();
    let (results, snapshot) = run_steps(&mut engine, &steps);
    let run_ns = t2.elapsed().as_nanos();

    let count = |pick: fn(&StepResult) -> usize| results.iter().map(pick).sum::<usize>() as i64;
    let (events, trace_records) = (count(|r| r.events.len()), count(|r| r.trace.len()));
    let ingest = steps.iter().filter(|s| matches!(s, Step::Ingest(_))).count() as i64;

    if let Some(path) = &args.events {
        let file = fs::File::create(path).map_err(|e| at(path, &e))?;
        let mut w = BufWriter::new(file);
        write_events(&mut w, results, snapshot, args.trace).and_then(|_| w.flush()).map_err(|e| at(path, &e))?;
    }

    let pack_name = args.pack.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let counters = obj(vec![
        ("engine", "rust".into()),
        ("function", args.function.as_str().into()),
        ("pack", pack_name.into()),
        ("steps", Json::Int(steps.len() as i64)),
        ("ingest", Json::Int(ingest)),
        ("tick", Json::Int(steps.len() as i64 - ingest)),
        ("events", Json::Int(events)),
        ("trace_records", Json::Int(trace_records)),
        ("parse_ns", Json::Int(parse_ns as i64)),
        ("load_ns", Json::Int(load_ns as i64)),
        ("run_ns", Json::Int(run_ns as i64)),
    ]);
    Ok(counters.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Result<Args, String> {
        Args::parse(list.iter().map(|s| s.to_string()))
    }

    #[test]
    fn arguments() {
        let a = args(&["--function", "fuse", "--pack", "p", "--steps", "s.json", "--trace", "--events", "e"]).unwrap();
        assert_eq!((a.function.as_str(), a.trace, a.events.is_some()), ("fuse", true, true));
        assert!(args(&["--function", "fuse", "--pack", "p"]).unwrap_err().contains("--steps"));
        assert!(args(&["--function"]).unwrap_err().contains("needs a value"));
        assert!(args(&["--verbose"]).unwrap_err().contains("unknown argument"));
    }

    #[test]
    fn steps_files() {
        let doc = json::parse(r#"{"name":"x","steps":[{"ingest":{"a":1},"expect":[]},{"tick":5,"trace":[]}]}"#).unwrap();
        let steps = steps_of(&doc).unwrap();
        assert_eq!(steps.len(), 2);
        assert_eq!(steps[1], Step::Tick(5));
        for bad in [r#"{}"#, r#"{"steps":[{}]}"#, r#"{"steps":[{"tick":1.5}]}"#] {
            assert!(steps_of(&json::parse(bad).unwrap()).is_err(), "{}", bad);
        }
    }

    #[test]
    fn events_file_lines() {
        let r = StepResult { events: vec![Json::Int(1)], trace: vec![Json::Null] };
        let mut out = Vec::new();
        write_events(&mut out, vec![r.clone()], Json::Null, true).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "{\"events\":[1],\"step\":0,\"trace\":[null]}\n{\"snapshot\":null}\n");
        let mut out = Vec::new();
        write_events(&mut out, vec![r], Json::Null, false).unwrap();
        assert_eq!(String::from_utf8(out).unwrap(), "{\"events\":[1],\"step\":0}\n{\"snapshot\":null}\n");
    }

    #[test]
    fn the_runner_end_to_end() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let dir = std::env::temp_dir().join(format!("goat-rust-io-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let events = dir.join("events.jsonl");
        let mut a = Args {
            function: "correlate".into(),
            pack: root.join("packs/correlate-gnn"),
            steps: root.join("packs/correlate-gnn/vectors/01-two-sources-one-object.json"),
            events: Some(events.clone()),
            trace: true,
        };
        let counters = json::parse(&run(&a).unwrap()).unwrap();
        assert_eq!(counters.get("engine"), Some(&Json::from("rust")));
        assert_eq!(counters.get("pack"), Some(&Json::from("correlate-gnn")));
        let text = fs::read_to_string(&events).unwrap();
        let steps = counters.get("steps").and_then(Json::as_i64).unwrap() as usize;
        assert_eq!(text.lines().count(), steps + 1);
        assert!(text.lines().last().unwrap().starts_with("{\"snapshot\":"));
        a.function = "nothing".into();
        assert!(run(&a).unwrap_err().contains("unknown function"));
        a.function = "filter".into();
        assert!(run(&a).is_err(), "a correlate pack is not a filter pack");
        a.steps = dir.join("missing.json");
        assert!(run(&a).is_err());
        fs::write(dir.join("bad.json"), "{").unwrap();
        a.steps = dir.join("bad.json");
        assert!(run(&a).unwrap_err().contains("json"));
        a.steps = root.join("packs/filter-area/vectors").read_dir().unwrap().next().unwrap().unwrap().path();
        a.pack = root.join("packs/filter-area");
        a.events = Some(dir.join("unwritable/x/events"));
        assert!(run(&a).is_err());
        a.events = None;
        for (function, pack) in [("filter", "filter-area"), ("fuse", "fuse-best"), ("quality", "quality-feed")] {
            a.function = function.into();
            a.pack = root.join("packs").join(pack);
            a.steps = a.pack.join("vectors").read_dir().unwrap().next().unwrap().unwrap().path();
            assert!(run(&a).is_ok(), "{}", pack);
        }
        fs::remove_dir_all(&dir).unwrap();
    }
}
