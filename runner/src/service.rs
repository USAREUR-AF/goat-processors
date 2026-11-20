//! The long-running service: inputs in, the pipeline, outputs out.
//!
//! **The clock.** The engines read no clock. The service is the one place a
//! clock enters, and the config states which:
//!
//! | `clock` | A tick happens | `now_ms` is |
//! |---|---|---|
//! | `wall` (default) | when this host's clock (UTC, ms since 1970) passes a multiple of `tick_ms` | that multiple |
//! | `input` | when a report's `time_ms` passes a multiple of `tick_ms` (replay::InputClock) | that multiple |
//!
//! With `wall`, a tick that falls more than one interval behind (the host
//! was suspended, or the clock stepped forward) is made once, at the latest
//! multiple; a clock that steps back makes no tick until it passes the last
//! tick again. Reports are ingested in the order they arrive between ticks.
//!
//! With `record`, every ingest and tick is written as it is made, so that
//! `goat-processors replay <record>` gives the same output.

use std::collections::{BTreeMap, VecDeque};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::net::UdpSocket;
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use goat_correlator::json::Json;

use crate::config::{Clock, Config};
use crate::fabric::{self, Input};
use crate::pipeline::{Output, Pipeline};
use crate::replay::{self, InputClock, Step};

pub fn wall_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn append(path: &std::path::Path) -> Result<File, String> {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    OpenOptions::new().create(true).append(true).open(path).map_err(|e| format!("cannot open {} for writing: {e}", path.display()))
}

struct Sinks {
    fabric: Option<fabric::Session>,
    prefix: String,
    fabric_trace: bool,
    file: Option<(File, bool)>,
    record: Option<File>,
    errors: u64,
    published: u64,
}

impl Sinks {
    fn emit(&mut self, n: usize, step: &Step, out: &Output) {
        if let Some(rec) = self.record.as_mut() {
            if writeln!(rec, "{}", step.to_line()).is_err() {
                self.errors += 1;
            }
        }
        if let Some((f, trace)) = self.file.as_mut() {
            for l in replay::output_lines(n, step, out, *trace) {
                if writeln!(f, "{l}").is_err() {
                    self.errors += 1;
                }
            }
        }
        let Some(fab) = self.fabric.as_ref() else { return };
        let mut puts: Vec<(String, Json)> = Vec::new();
        let now = match step {
            Step::Tick(t) => Some(*t),
            _ => None,
        };
        let track_stage = track_stage(out);
        for (i, s) in out.stages.iter().enumerate() {
            if !s.events.is_empty() {
                puts.push((format!("{}/events/{}", self.prefix, s.function), line_obj(&s.function, now, Json::Arr(s.events.clone()), "events")));
            }
            if self.fabric_trace && !s.trace.is_empty() {
                puts.push((format!("{}/trace/{}", self.prefix, s.function), line_obj(&s.function, now, Json::Arr(s.trace.clone()), "trace")));
            }
            for e in &s.events {
                let ev = e.get("ev").and_then(|v| v.as_str()).unwrap_or("");
                let field = |k: &str| e.get(k).and_then(|v| v.as_str()).map(fabric::key_chunk);
                if Some(i) == track_stage && (ev == "fused" || ev == "system") {
                    if let Some(id) = field("group").or_else(|| field("system")) {
                        puts.push((format!("{}/tracks/{}", self.prefix, id), with_now(e, now)));
                    }
                }
                if s.function == "quality" && matches!(ev, "quality" | "action-start" | "action-end") {
                    if let (Some(scope), Some(subject)) = (field("scope"), field("subject")) {
                        puts.push((format!("{}/quality/{}/{}", self.prefix, scope, subject), with_now(e, now)));
                    }
                }
            }
        }
        for (k, v) in puts {
            match fab.put(&k, &v) {
                Ok(()) => self.published += 1,
                Err(_) => self.errors += 1,
            }
        }
    }
}

/// The stage whose track events are the runner's tracks: the last one that makes tracks.
fn track_stage(out: &Output) -> Option<usize> {
    out.stages.iter().rposition(|s| s.function == "fuse" || s.function == "correlate")
}

/// The system tracks in one output: (id, event).
fn track_events(out: &Output) -> Vec<(String, Json)> {
    let Some(i) = track_stage(out) else { return vec![] };
    out.stages[i]
        .events
        .iter()
        .filter(|e| matches!(e.get("ev").and_then(|v| v.as_str()), Some("fused") | Some("system")))
        .filter_map(|e| {
            let id = e.get("group").or_else(|| e.get("system")).and_then(|v| v.as_str())?;
            Some((id.to_string(), e.clone()))
        })
        .collect()
}

fn line_obj(stage: &str, now: Option<i64>, list: Json, key: &str) -> Json {
    let mut m = BTreeMap::new();
    m.insert("stage".into(), Json::Str(stage.into()));
    if let Some(t) = now {
        m.insert("now_ms".into(), Json::Int(t));
    }
    m.insert(key.to_string().into(), list);
    Json::Obj(m)
}

fn with_now(e: &Json, now: Option<i64>) -> Json {
    let mut e = e.clone();
    if let (Json::Obj(m), Some(t)) = (&mut e, now) {
        m.insert("now_ms".into(), Json::Int(t));
    }
    e
}

fn spawn_udp(listen: &str, tx: Sender<Input>) -> Result<(), String> {
    let sock = UdpSocket::bind(listen).map_err(|e| format!("cannot listen on UDP {listen}: {e}"))?;
    let from = format!("udp/{listen}");
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 65536];
        while let Ok((n, _)) = sock.recv_from(&mut buf) {
            if tx.send(fabric::decode(&from, &buf[..n])).is_err() {
                break;
            }
        }
    });
    Ok(())
}

/// Plays a file into the service at `speed` times the pace of its report times.
fn spawn_file(path: &std::path::Path, speed: f64, tx: Sender<Input>) -> Result<(), String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let file = replay::read(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    std::thread::spawn(move || {
        let start = Instant::now();
        let mut first: Option<i64> = None;
        for step in file.steps {
            let Step::Ingest(r) = step else { continue };
            if let (Some(t), true) = (replay::report_time(&r), speed > 0.0) {
                let t0 = *first.get_or_insert(t);
                let due = Duration::from_secs_f64(((t - t0).max(0) as f64 / 1000.0) / speed);
                if let Some(wait) = due.checked_sub(start.elapsed()) {
                    std::thread::sleep(wait);
                }
            }
            if tx.send(Input::Reports(vec![r])).is_err() {
                return;
            }
        }
        let _ = tx.send(Input::Ended);
    });
    Ok(())
}


/// The state the service writes to `status_file` after every tick.
fn status(c: &Config, p: &Pipeline, started_ms: i64, sinks: &Sinks, unreadable: u64, fabric_routers: Option<usize>) -> Json {
    let mut m = BTreeMap::new();
    let s = |v: &str| Json::Str(v.into());
    m.insert("name".into(), s(&c.name));
    m.insert("site".into(), s(&c.site));
    m.insert("version".into(), s(env!("CARGO_PKG_VERSION")));
    m.insert("state".into(), s("running"));
    m.insert("pid".into(), Json::Int(std::process::id() as i64));
    m.insert("started_ms".into(), Json::Int(started_ms));
    m.insert("written_ms".into(), Json::Int(wall_ms()));
    m.insert("clock".into(), s(if c.clock == Clock::Wall { "wall" } else { "input" }));
    m.insert("tick_ms".into(), Json::Int(c.tick_ms));
    m.insert("last_tick_ms".into(), p.last_now_ms.map(Json::Int).unwrap_or(Json::Null));
    m.insert(
        "pipeline".into(),
        Json::Arr(
            p.stages
                .iter()
                .map(|st| {
                    let mut o = BTreeMap::new();
                    o.insert("function".into(), s(&st.function));
                    o.insert("pack".into(), s(&st.pack));
                    Json::Obj(o)
                })
                .collect(),
        ),
    );
    let k = &p.counters;
    let mut cnt = BTreeMap::new();
    cnt.insert("reports_in".into(), Json::Int(k.reports_in as i64));
    cnt.insert("reports_out".into(), Json::Int(k.reports_out as i64));
    cnt.insert("ticks".into(), Json::Int(k.ticks as i64));
    cnt.insert("unreadable".into(), Json::Int(unreadable as i64));
    cnt.insert("published".into(), Json::Int(sinks.published as i64));
    cnt.insert("output_errors".into(), Json::Int(sinks.errors as i64));
    cnt.insert("stopped".into(), Json::Obj(k.stopped.iter().map(|(a, b)| (a.clone().into(), Json::Int(*b as i64))).collect()));
    cnt.insert("per_source".into(), Json::Obj(k.per_source.iter().map(|(a, b)| (a.clone().into(), Json::Int(*b as i64))).collect()));
    m.insert("counters".into(), Json::Obj(cnt));
    m.insert("output_prefix".into(), s(&sinks.prefix));
    m.insert("fabric_routers".into(), fabric_routers.map(|n| Json::Int(n as i64)).unwrap_or(Json::Null));
    Json::Obj(m)
}

fn write_status(path: &std::path::Path, v: &Json) {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, format!("{v}\n")).is_ok() {
        // The status holds no secret: doctor reads it as any user.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644));
        }
        let _ = std::fs::rename(&tmp, path);
    }
}


/// Recent steps kept for `explain`: at most this many trace records in all.
const RECENT_TRACE: usize = 200_000;
/// Processing times kept for the latency figures.
const LATENCY_SAMPLES: usize = 2048;

struct Recent {
    step: usize,
    now_ms: Option<i64>,
    out: Output,
}

/// Everything the service loop holds.
struct Runner {
    c: Config,
    p: Pipeline,
    sinks: Sinks,
    started_ms: i64,
    n: usize,
    unreadable: u64,
    paused: bool,
    dropped_paused: u64,
    pipeline_changes: u64,
    /// The system tracks of the latest tick that made any, by id.
    tracks: BTreeMap<String, Json>,
    tracks_now_ms: Option<i64>,
    recent: VecDeque<Recent>,
    recent_records: usize,
    /// (second, reports ingested in it), for the last 10 s.
    rate: VecDeque<(i64, u64)>,
    /// Processing time of one report through every stage, microseconds.
    latency_us: VecDeque<u64>,
    /// Wall time minus report time at ingest, milliseconds (wall clock only).
    age_ms: VecDeque<i64>,
}

impl Runner {
    fn step(&mut self, step: Step) {
        let started = Instant::now();
        let out = match &step {
            Step::Ingest(r) => self.p.ingest(r),
            Step::Tick(t) => self.p.tick(*t),
            Step::Pack { .. } => Output::default(),
        };
        if let Step::Ingest(r) = &step {
            let us = started.elapsed().as_micros() as u64;
            push_capped(&mut self.latency_us, us, LATENCY_SAMPLES);
            let sec = wall_ms().div_euclid(1000);
            match self.rate.back_mut() {
                Some((s, n)) if *s == sec => *n += 1,
                _ => self.rate.push_back((sec, 1)),
            }
            while self.rate.front().is_some_and(|(s, _)| *s < sec - 10) {
                self.rate.pop_front();
            }
            if self.c.clock == Clock::Wall {
                if let Some(t) = replay::report_time(r) {
                    push_capped(&mut self.age_ms, wall_ms() - t, LATENCY_SAMPLES);
                }
            }
        }
        self.sinks.emit(self.n, &step, &out);
        let now = match &step {
            Step::Tick(t) => Some(*t),
            _ => None,
        };
        let tracks = track_events(&out);
        if now.is_some() && track_stage(&out).is_some() {
            self.tracks = tracks.into_iter().collect();
            self.tracks_now_ms = now;
        }
        let records: usize = out.stages.iter().map(|s| s.trace.len()).sum();
        if !out.stages.is_empty() {
            self.recent.push_back(Recent { step: self.n, now_ms: now, out });
            self.recent_records += records;
            while self.recent_records > RECENT_TRACE && self.recent.len() > 1 {
                let old = self.recent.pop_front().unwrap();
                self.recent_records -= old.out.stages.iter().map(|s| s.trace.len()).sum::<usize>();
            }
        }
        self.n += 1;
        if now.is_some() {
            write_status(&self.c.status_file, &self.status());
        }
    }

    fn status(&self) -> Json {
        let routers = self.sinks.fabric.as_ref().map(|f| f.routers());
        let mut v = status(&self.c, &self.p, self.started_ms, &self.sinks, self.unreadable, routers);
        if let Json::Obj(m) = &mut v {
            m.insert("state".into(), Json::Str(if self.paused { "paused" } else { "running" }.into()));
            if let Some(Json::Obj(cnt)) = m.get_mut("counters") {
                cnt.insert("dropped_paused".into(), Json::Int(self.dropped_paused as i64));
                cnt.insert("pipeline_changes".into(), Json::Int(self.pipeline_changes as i64));
            }
        }
        v
    }

    fn healthy(&self) -> (bool, String) {
        if self.paused {
            return (false, "paused: an operator stopped processing".into());
        }
        match self.p.last_now_ms {
            None => (false, "no tick yet".into()),
            Some(t) if self.c.clock == Clock::Wall && wall_ms() - t > 3 * self.c.tick_ms + 2000 => {
                (false, format!("the last tick was {} ms ago", wall_ms() - t))
            }
            Some(_) => (true, "running and ticking".into()),
        }
    }

    fn pipeline_json(&self) -> Json {
        let configured: Vec<(String, String)> = self.c.pipeline.iter().map(|s| (s.function.clone(), s.pack.clone())).collect();
        Json::Arr(
            self.p
                .stages
                .iter()
                .map(|st| {
                    let mut o = BTreeMap::new();
                    o.insert("function".into(), Json::Str(st.function.clone()));
                    o.insert("pack".into(), Json::Str(st.pack.clone()));
                    let conf = configured.iter().find(|(f, _)| *f == st.function).map(|(_, p)| p.clone()).unwrap_or_default();
                    o.insert("configured_pack".into(), Json::Str(conf.clone()));
                    o.insert("as_configured".into(), Json::Bool(conf == st.pack));
                    Json::Obj(o)
                })
                .collect(),
        )
    }

    fn metrics(&self) -> Json {
        let mut m = BTreeMap::new();
        let now_sec = wall_ms().div_euclid(1000);
        let last10: u64 = self.rate.iter().filter(|(s, _)| *s >= now_sec - 10 && *s < now_sec).map(|(_, n)| n).sum();
        m.insert("reports_per_second".into(), Json::Num(last10 as f64 / 10.0));
        m.insert("rate_window_s".into(), Json::Int(10));
        m.insert("processing_us".into(), quantiles(&self.latency_us.iter().map(|x| *x as i64).collect::<Vec<_>>()));
        m.insert("report_age_ms".into(), quantiles(&self.age_ms.iter().copied().collect::<Vec<_>>()));
        let k = &self.p.counters;
        m.insert("reports_in".into(), Json::Int(k.reports_in as i64));
        m.insert("reports_out".into(), Json::Int(k.reports_out as i64));
        m.insert("ticks".into(), Json::Int(k.ticks as i64));
        m.insert("per_source".into(), Json::Obj(k.per_source.iter().map(|(a, b)| (a.clone().into(), Json::Int(*b as i64))).collect()));
        m.insert("stopped".into(), Json::Obj(k.stopped.iter().map(|(a, b)| (a.clone().into(), Json::Int(*b as i64))).collect()));
        m.insert("tracks".into(), Json::Int(self.tracks.len() as i64));
        Json::Obj(m)
    }

    fn tracks_json(&self) -> Json {
        let mut m = BTreeMap::new();
        m.insert("now_ms".into(), self.tracks_now_ms.map(Json::Int).unwrap_or(Json::Null));
        m.insert("tracks".into(), Json::Arr(self.tracks.values().cloned().collect()));
        Json::Obj(m)
    }

    /// The events and trace records, among the recent steps, that name the
    /// track or one of its members.
    fn explain(&self, id: &str) -> Option<Json> {
        let track = self.tracks.get(id)?.clone();
        let mut names: Vec<String> = vec![id.to_string()];
        if let Some(Json::Arr(ms)) = track.get("members") {
            names.extend(ms.iter().filter_map(|v| v.as_str().map(str::to_string)));
        }
        let names_in = |v: &Json| -> bool {
            ["a", "b", "entity", "group", "system", "subject", "primary"]
                .iter()
                .any(|k| v.get(k).and_then(|x| x.as_str()).is_some_and(|x| names.iter().any(|n| n == x)))
                || matches!(v.get("members"), Some(Json::Arr(ms)) if ms.iter().any(|x| x.as_str().is_some_and(|x| names.iter().any(|n| n == x))))
        };
        let mut events = Vec::new();
        let mut trace = Vec::new();
        for r in &self.recent {
            for s in &r.out.stages {
                for e in s.events.iter().filter(|e| names_in(e)) {
                    events.push(cite(r, &s.function, e, "event"));
                }
                for t in s.trace.iter().filter(|t| names_in(t)) {
                    trace.push(cite(r, &s.function, t, "record"));
                }
            }
        }
        const MAX: usize = 1000;
        let cut = |v: Vec<Json>| -> (Vec<Json>, bool) {
            let more = v.len() > MAX;
            (v[v.len().saturating_sub(MAX)..].to_vec(), more)
        };
        let (events, ev_more) = cut(events);
        let (trace, tr_more) = cut(trace);
        let mut m = BTreeMap::new();
        m.insert("track".into(), track);
        m.insert("names".into(), Json::Arr(names.into_iter().map(Json::Str).collect()));
        m.insert("from_step".into(), self.recent.front().map(|r| Json::Int(r.step as i64)).unwrap_or(Json::Null));
        m.insert("events".into(), Json::Arr(events));
        m.insert("trace".into(), Json::Arr(trace));
        m.insert("truncated".into(), Json::Bool(ev_more || tr_more));
        Some(Json::Obj(m))
    }

    fn answer(&mut self, call: crate::api::Call) {
        use crate::api::{error, Ask};
        use crate::http::Response;
        let ok = |v: Json| Response::json(200, v.to_string());
        let resp = match call.ask {
            Ask::Status => ok(self.status()),
            Ask::Health => {
                let (good, why) = self.healthy();
                let mut m = BTreeMap::new();
                m.insert("healthy".into(), Json::Bool(good));
                m.insert("detail".into(), Json::Str(why));
                Response::json(if good { 200 } else { 503 }, Json::Obj(m).to_string())
            }
            Ask::Pipeline => ok(self.pipeline_json()),
            Ask::Metrics => ok(self.metrics()),
            Ask::Tracks => ok(self.tracks_json()),
            Ask::Explain(id) => match self.explain(&id) {
                Some(v) => ok(v),
                None => error(404, &format!("no system track {id:?} in the latest tick"), "goat-processors tracks lists them"),
            },
            Ask::Stop => {
                self.paused = true;
                write_status(&self.c.status_file, &self.status());
                eprintln!("stopped by {} ({})", call.who.name, call.who.via);
                ok(self.status())
            }
            Ask::Start => {
                self.paused = false;
                write_status(&self.c.status_file, &self.status());
                eprintln!("started by {} ({})", call.who.name, call.who.via);
                ok(self.status())
            }
            Ask::PackUse { function, pack } => match self.p.use_pack(&function, &pack, &self.c.packs_dir.clone()) {
                Ok(()) => {
                    self.pipeline_changes += 1;
                    self.step(Step::Pack { function: function.clone(), pack: pack.clone() });
                    eprintln!("{function} now runs pack {pack}, selected by {} ({})", call.who.name, call.who.via);
                    ok(self.pipeline_json())
                }
                Err(e) => error(409, &format!("{function}: {e}"), "goat-processors pack ls lists the packs; the function must be in the pipeline"),
            },
        };
        let _ = call.reply.send(resp);
    }
}

fn cite(r: &Recent, stage: &str, v: &Json, key: &str) -> Json {
    let mut m = BTreeMap::new();
    m.insert("step".into(), Json::Int(r.step as i64));
    m.insert("now_ms".into(), r.now_ms.map(Json::Int).unwrap_or(Json::Null));
    m.insert("stage".into(), Json::Str(stage.into()));
    m.insert(key.to_string().into(), v.clone());
    Json::Obj(m)
}

fn push_capped<T>(q: &mut VecDeque<T>, v: T, cap: usize) {
    if q.len() == cap {
        q.pop_front();
    }
    q.push_back(v);
}

fn quantiles(v: &[i64]) -> Json {
    let mut m = BTreeMap::new();
    if v.is_empty() {
        m.insert("samples".into(), Json::Int(0));
        return Json::Obj(m);
    }
    let mut s = v.to_vec();
    s.sort_unstable();
    let q = |f: f64| s[((s.len() - 1) as f64 * f).round() as usize];
    m.insert("samples".into(), Json::Int(s.len() as i64));
    m.insert("p50".into(), Json::Int(q(0.5)));
    m.insert("p99".into(), Json::Int(q(0.99)));
    m.insert("max".into(), Json::Int(*s.last().unwrap()));
    Json::Obj(m)
}

pub fn run(c: Config) -> Result<(), String> {
    let p = Pipeline::from_config(&c)?;
    let (tx, rx) = channel::<Input>();

    let session = match &c.fabric {
        Some(f) if c.inputs.fabric.is_some() || c.outputs.fabric.is_some() => {
            let keys = c.inputs.fabric.as_ref().map(|i| i.keys.clone()).unwrap_or_default();
            Some(fabric::open(f, &keys, tx.clone())?)
        }
        _ => None,
    };
    let sinks = Sinks {
        fabric: if c.outputs.fabric.is_some() { session } else { None },
        prefix: c.output_prefix(),
        fabric_trace: c.outputs.fabric.as_ref().is_some_and(|f| f.trace),
        file: match &c.outputs.file {
            Some(f) => Some((append(&f.path)?, f.trace)),
            None => None,
        },
        record: match &c.record {
            Some(r) => Some(append(&r.path)?),
            None => None,
        },
        errors: 0,
        published: 0,
    };
    for u in &c.inputs.udp {
        spawn_udp(&u.listen, tx.clone())?;
    }
    if let Some(f) = &c.inputs.file {
        spawn_file(&f.path, f.speed, tx.clone())?;
    }
    if c.api.enabled {
        crate::api::start(&c, tx.clone())?;
    }
    // Only a file input ends; with no other input, its end closes the run.
    let endless = c.inputs.fabric.is_some() || !c.inputs.udp.is_empty();
    drop(tx);

    eprintln!(
        "goat-processors {}: {} at {}, pipeline {}, output prefix {}, clock {:?}, tick {} ms, API {}",
        env!("CARGO_PKG_VERSION"),
        c.name,
        c.site,
        p.stages.iter().map(|s| format!("{}={}", s.function, s.pack)).collect::<Vec<_>>().join(", "),
        sinks.prefix,
        c.clock,
        c.tick_ms,
        if c.api.enabled { c.api.listen.as_str() } else { "off" },
    );

    let tick = c.tick_ms;
    let mut r = Runner {
        c,
        p,
        sinks,
        started_ms: wall_ms(),
        n: 0,
        unreadable: 0,
        paused: false,
        dropped_paused: 0,
        pipeline_changes: 0,
        tracks: BTreeMap::new(),
        tracks_now_ms: None,
        recent: VecDeque::new(),
        recent_records: 0,
        rate: VecDeque::new(),
        latency_us: VecDeque::new(),
        age_ms: VecDeque::new(),
    };
    let mut input_clock = InputClock::new(tick);
    let mut next_wall = (wall_ms().div_euclid(tick) + 1) * tick;
    let mut last_tick: Option<i64> = None;
    let mut inputs_open = true;
    let mut ended = false;
    let close = |r: &mut Runner, input_clock: &mut InputClock| {
        if r.c.clock == Clock::Input {
            if let Some(now) = input_clock.close() {
                r.step(Step::Tick(now));
            }
        }
        eprintln!("every input has ended; the runner stays up and idle");
    };
    loop {
        let timeout = match r.c.clock {
            Clock::Wall => Duration::from_millis((next_wall - wall_ms()).max(0) as u64),
            Clock::Input => Duration::from_millis(tick as u64),
        };
        let got = if inputs_open {
            rx.recv_timeout(timeout)
        } else {
            std::thread::sleep(timeout);
            Err(RecvTimeoutError::Timeout)
        };
        match got {
            Ok(Input::Reports(reports)) => {
                for rep in reports {
                    if r.paused {
                        r.dropped_paused += 1;
                        continue;
                    }
                    if r.c.clock == Clock::Input {
                        if let Some(t) = replay::report_time(&rep) {
                            for now in input_clock.before(t) {
                                r.step(Step::Tick(now));
                            }
                        }
                    }
                    r.step(Step::Ingest(rep));
                }
            }
            Ok(Input::Unreadable { from, why }) => {
                r.unreadable += 1;
                if r.unreadable <= 10 || r.unreadable % 1000 == 0 {
                    eprintln!("unreadable input from {from}: {why} ({} so far)", r.unreadable);
                }
            }
            Ok(Input::Api(call)) => r.answer(call),
            Ok(Input::Ended) => {
                if !endless && !ended {
                    ended = true;
                    close(&mut r, &mut input_clock);
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                inputs_open = false;
                if !ended {
                    ended = true;
                    close(&mut r, &mut input_clock);
                }
            }
        }
        if r.c.clock == Clock::Wall {
            let now = wall_ms();
            if now >= next_wall {
                let due = now.div_euclid(tick) * tick;
                if !r.paused && last_tick.map_or(true, |l| due > l) {
                    r.step(Step::Tick(due));
                    last_tick = Some(due);
                }
                next_wall = due + tick;
            }
        }
    }
}
