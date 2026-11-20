//! Replay files, the input clock, and the output line format.
//!
//! A replay file is one of:
//!
//! | Form | How it is read |
//! |---|---|
//! | a vector (one JSON object with `steps`) | its steps, in order; the pipeline is the vector's `pack` unless one is given |
//! | JSON lines, each `{"ingest": <report>}`, `{"tick": <now_ms>}` or `{"pack": {"function", "pack"}}` | these steps, in order (the form `record` writes) |
//! | JSON lines, each a report | each report, with ticks from the input clock |
//!
//! Blank lines and lines starting with `#` are skipped. The forms may be mixed
//! line by line; when a file holds any `tick` step, or is a vector, the input
//! clock is not used.

use std::collections::BTreeMap;

use goat_correlator::json::{self, Json};

use crate::pipeline::{Output, Pipeline};

#[derive(Debug, Clone)]
pub enum Step {
    Ingest(Json),
    Tick(i64),
    /// An operator selected another pack for one function (API, `pack use`).
    Pack { function: String, pack: String },
}

impl Step {
    /// The line `record` writes.
    pub fn to_line(&self) -> String {
        match self {
            Step::Ingest(r) => format!("{{\"ingest\":{r}}}"),
            Step::Tick(t) => format!("{{\"tick\":{t}}}"),
            Step::Pack { function, pack } => {
                format!("{{\"pack\":{{\"function\":{},\"pack\":{}}}}}", Json::Str(function.clone()), Json::Str(pack.clone()))
            }
        }
    }
}

pub struct ReplayFile {
    pub steps: Vec<Step>,
    /// The `pack` a vector names.
    pub vector_pack: Option<String>,
    /// Whether the file states its own ticks (always, for a vector).
    pub has_ticks: bool,
}

pub fn read(text: &str) -> Result<ReplayFile, String> {
    let trimmed = text.trim_start();
    if trimmed.starts_with('{') {
        // A whole-file JSON object is a vector; otherwise fall through to lines.
        if let Ok(v) = json::parse(text) {
            if let Some(Json::Arr(steps)) = v.get("steps") {
                let mut out = Vec::new();
                for (i, s) in steps.iter().enumerate() {
                    out.push(step_of(s).ok_or_else(|| format!("steps[{i}] holds neither `ingest` nor `tick`"))?);
                }
                // A vector's steps are exact: the input clock adds no tick.
                return Ok(ReplayFile { steps: out, vector_pack: v.get("pack").and_then(|p| p.as_str()).map(str::to_string), has_ticks: true });
            }
        }
    }
    let mut steps = Vec::new();
    for (n, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let v = json::parse(line).map_err(|e| format!("line {}: not JSON ({e})", n + 1))?;
        match step_of(&v) {
            Some(s) => steps.push(s),
            None if matches!(v, Json::Obj(_)) => steps.push(Step::Ingest(v)),
            None => return Err(format!("line {}: not a report, an ingest step or a tick step", n + 1)),
        }
    }
    let has_ticks = steps.iter().any(|s| matches!(s, Step::Tick(_)));
    Ok(ReplayFile { steps, vector_pack: None, has_ticks })
}

fn step_of(v: &Json) -> Option<Step> {
    // A step holds `ingest` or `tick` (a vector step also carries `expect`
    // and `trace`, which replay does not read). A report holds neither key.
    let m = v.as_object()?;
    if let Some(r) = m.get("ingest") {
        return Some(Step::Ingest(r.clone()));
    }
    if let Some(Json::Obj(p)) = m.get("pack") {
        let function = p.get("function")?.as_str()?.to_string();
        let pack = p.get("pack")?.as_str()?.to_string();
        return Some(Step::Pack { function, pack });
    }
    if let Some(t) = m.get("tick") {
        return t.as_i64().map(Step::Tick).filter(|_| matches!(t, Json::Int(_)));
    }
    None
}

/// The input clock: ticks at every multiple of `tick_ms` that the latest
/// report time has reached. The first report sets the start; a report never
/// moves the clock back. When more than `MAX_CATCH_UP` ticks are due at once
/// (a gap in the input), only the last of them is made.
pub struct InputClock {
    pub tick_ms: i64,
    next: Option<i64>,
}

pub const MAX_CATCH_UP: i64 = 1000;

impl InputClock {
    pub fn new(tick_ms: i64) -> InputClock {
        InputClock { tick_ms, next: None }
    }

    /// The ticks due before a report with time `t` is ingested.
    pub fn before(&mut self, t: i64) -> Vec<i64> {
        let tick = self.tick_ms;
        let next = *self.next.get_or_insert_with(|| t.div_euclid(tick) * tick + tick);
        if t < next {
            return vec![];
        }
        let last = t.div_euclid(tick) * tick;
        let due = (last - next) / tick + 1;
        self.next = Some(last + tick);
        if due > MAX_CATCH_UP {
            vec![last]
        } else {
            (0..due).map(|i| next + i * tick).collect()
        }
    }

    /// The tick that closes the input: the next one due, if a report was read.
    pub fn close(&mut self) -> Option<i64> {
        let n = self.next?;
        self.next = Some(n + self.tick_ms);
        Some(n)
    }
}

/// Report time, when the report has an integer `time_ms`.
pub fn report_time(r: &Json) -> Option<i64> {
    match r.get("time_ms") {
        Some(Json::Int(t)) => Some(*t),
        _ => None,
    }
}

/// One output line per stage per call.
pub fn output_lines(step: usize, call: &Step, out: &Output, trace: bool) -> Vec<String> {
    out.stages
        .iter()
        .map(|s| {
            let mut m = BTreeMap::new();
            m.insert("step".to_string(), Json::Int(step as i64));
            match call {
                Step::Ingest(_) => m.insert("call".into(), Json::Str("ingest".into())),
                Step::Tick(t) => {
                    m.insert("now_ms".into(), Json::Int(*t));
                    m.insert("call".into(), Json::Str("tick".into()))
                }
                Step::Pack { .. } => m.insert("call".into(), Json::Str("pack".into())),
            };
            m.insert("stage".into(), Json::Str(s.function.clone()));
            m.insert("events".into(), Json::Arr(s.events.clone()));
            if trace {
                m.insert("trace".into(), Json::Arr(s.trace.clone()));
            }
            Json::Obj(m).to_string()
        })
        .collect()
}

/// Runs a replay file through a pipeline. `on_line` gets every output line.
/// With `tick_ms`, a file without ticks is ticked by the input clock.
pub fn run(p: &mut Pipeline, file: &ReplayFile, tick_ms: i64, packs_dir: &std::path::Path, trace: bool, mut on_line: impl FnMut(String)) {
    let mut clock = (!file.has_ticks).then(|| InputClock::new(tick_ms));
    let mut n = 0usize;
    let mut call = |p: &mut Pipeline, step: Step, on_line: &mut dyn FnMut(String)| {
        let out = match &step {
            Step::Ingest(r) => p.ingest(r),
            Step::Tick(t) => p.tick(*t),
            Step::Pack { function, pack } => {
                let mut m = BTreeMap::new();
                m.insert("step".to_string(), Json::Int(n as i64));
                m.insert("call".into(), Json::Str("pack".into()));
                m.insert("stage".into(), Json::Str(function.clone()));
                m.insert("pack".into(), Json::Str(pack.clone()));
                if let Err(e) = p.use_pack(function, pack, packs_dir) {
                    m.insert("error".into(), Json::Str(e));
                }
                on_line(Json::Obj(m).to_string());
                n += 1;
                return;
            }
        };
        for l in output_lines(n, &step, &out, trace) {
            on_line(l);
        }
        n += 1;
    };
    for step in &file.steps {
        if let (Some(c), Step::Ingest(r)) = (clock.as_mut(), step) {
            if let Some(t) = report_time(r) {
                for now in c.before(t) {
                    call(p, Step::Tick(now), &mut on_line);
                }
            }
        }
        call(p, step.clone(), &mut on_line);
    }
    if let Some(now) = clock.as_mut().and_then(|c| c.close()) {
        call(p, Step::Tick(now), &mut on_line);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_clock() {
        let mut c = InputClock::new(1000);
        assert_eq!(c.before(1500), Vec::<i64>::new());
        assert_eq!(c.before(1999), Vec::<i64>::new());
        assert_eq!(c.before(2000), vec![2000]);
        assert_eq!(c.before(4100), vec![3000, 4000]);
        assert_eq!(c.before(3000), Vec::<i64>::new());
        assert_eq!(c.before(10_000_000), vec![10_000_000]);
        assert_eq!(c.close(), Some(10_001_000));
    }

    #[test]
    fn line_forms() {
        let f = read("# c\n{\"ingest\":{\"uid\":\"a\"}}\n{\"tick\":5}\n{\"uid\":\"b\"}\n").unwrap();
        assert_eq!(f.steps.len(), 3);
        assert!(f.has_ticks);
        assert!(read("[1]\n").is_err());
    }
}
