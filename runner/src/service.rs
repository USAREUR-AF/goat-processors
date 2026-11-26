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
    batch: Option<Batch>,
    file: Option<(File, bool)>,
    record: Option<File>,
    errors: u64,
    published: u64,
}

/// State of `layout: batch`: what was last published, and when.
struct Batch {
    heartbeat_ms: i64,
    tracks: Option<(String, i64)>,
    quality: Option<(String, i64)>,
    /// A number 1 to 65535 per system track, held while the track lives, for
    /// formats whose track identifier is a number (ASTERIX I062/040).
    numbers: BTreeMap<String, u16>,
    next_number: u16,
}

impl Batch {
    /// Gives each track in `tracks` its number (`track_number`), keeping the
    /// number of a track seen before, and frees the numbers of tracks no
    /// longer in the set. A new track takes the next free number after the
    /// last one given, wrapping after 65535.
    fn number(&mut self, tracks: &mut [Json]) {
        let ids: Vec<String> = tracks.iter().map(|t| t.get("group").or_else(|| t.get("system")).and_then(|v| v.as_str()).unwrap_or("").to_string()).collect();
        self.numbers.retain(|id, _| ids.contains(id));
        for (t, id) in tracks.iter_mut().zip(ids) {
            let n = match self.numbers.get(&id) {
                Some(n) => *n,
                None => {
                    let used: std::collections::BTreeSet<u16> = self.numbers.values().copied().collect();
                    if used.len() >= 65535 {
                        continue;
                    }
                    let mut n = self.next_number;
                    while n == 0 || used.contains(&n) {
                        n = n.wrapping_add(1);
                    }
                    self.next_number = n.wrapping_add(1);
                    self.numbers.insert(id, n);
                    n
                }
            };
            if let Json::Obj(m) = t {
                m.insert("track_number".into(), Json::Int(n as i64));
            }
        }
    }

    /// Whether a set whose content is `body` is due at `now`: it differs from
    /// the last one published, or the heartbeat has passed.
    fn due(last: &mut Option<(String, i64)>, body: String, now: i64, heartbeat_ms: i64) -> bool {
        let due = match last {
            None => true,
            Some((b, t)) => *b != body || now - *t >= heartbeat_ms || now < *t,
        };
        if due {
            *last = Some((body, now));
        }
        due
    }
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
                if self.batch.is_some() {
                    continue;
                }
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
        let mut texts: Vec<(String, String)> = Vec::new();
        if let (Some(b), Some(t)) = (self.batch.as_mut(), now) {
            // Each set is JSON lines: one object per line, each with `now_ms`,
            // so a reader splits it with newline framing, and the runner's own
            // input reads it as a list of reports.
            let lines = |v: &[Json]| v.iter().map(|e| with_now(e, now).to_string() + "\n").collect::<String>();
            let mut tracks: Vec<Json> = track_events(out).into_iter().map(|(_, e)| e).collect();
            if track_stage.is_some() {
                b.number(&mut tracks);
            }
            let quality: Vec<Json> = out
                .stages
                .iter()
                .filter(|s| s.function == "quality")
                .flat_map(|s| s.events.iter())
                .filter(|e| matches!(e.get("ev").and_then(|v| v.as_str()), Some("quality" | "action-start" | "action-end")))
                .cloned()
                .collect();
            if track_stage.is_some() && Batch::due(&mut b.tracks, Json::Arr(tracks.clone()).to_string(), t, b.heartbeat_ms) {
                texts.push((format!("{}/tracks", self.prefix), lines(&tracks)));
            }
            if out.stages.iter().any(|s| s.function == "quality")
                && Batch::due(&mut b.quality, Json::Arr(quality.clone()).to_string(), t, b.heartbeat_ms)
            {
                texts.push((format!("{}/quality", self.prefix), lines(&quality)));
            }
        }
        for (k, v) in texts {
            match fab.put_text(&k, v) {
                Ok(()) => self.published += 1,
                Err(_) => self.errors += 1,
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
            let mut track = e.clone();
            if let (Json::Obj(m), Some(mono)) = (&mut track, mono(e)) {
                m.insert("mono".into(), Json::Int(mono));
            }
            Some((id.to_string(), track))
        })
        .collect()
}

/// 1 when a track's members come from one source, 0 when from more than one.
/// A member is `<source>/<uid>`.
fn mono(e: &Json) -> Option<i64> {
    let Some(Json::Arr(ms)) = e.get("members") else { return None };
    let sources: std::collections::BTreeSet<&str> = ms.iter().filter_map(|m| m.as_str()?.split('/').next()).collect();
    (!sources.is_empty()).then_some(i64::from(sources.len() == 1))
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
    /// Events returned, by (function, `ev`). Both are bounded by the specs.
    events: BTreeMap<(String, String), u64>,
    /// Quality events about a source, by (source, `ev`, measure or action).
    quality_sources: BTreeMap<(String, String, String), u64>,
    tracks_now_ms: Option<i64>,
    recent: VecDeque<Recent>,
    recent_records: usize,
    /// (second, reports ingested in it), for the last 10 s.
    rate: VecDeque<(i64, u64)>,
    /// Processing time of one report through every stage, microseconds.
    latency_us: VecDeque<u64>,
    /// Wall time minus report time at ingest, milliseconds (wall clock only).
    age_ms: VecDeque<i64>,
    /// Settings proposals (proposals.rs).
    book: crate::proposals::Book,
    /// For the policy gates, which report back to the loop.
    tx: Sender<Input>,
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
        for st in &out.stages {
            for e in &st.events {
                let txt = |k: &str| e.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
                let ev = txt("ev");
                if st.function == "quality" && txt("scope") == "source" {
                    if ev == "quality" {
                        // A quality event carries every measure in its `measures` object;
                        // count one per measure it states (a null measure is absent).
                        if let Some(goat_correlator::json::Json::Obj(ms)) = e.get("measures") {
                            for (name, value) in ms.iter() {
                                if !matches!(value, goat_correlator::json::Json::Null) {
                                    *self.quality_sources.entry((txt("subject"), ev.clone(), name.to_string())).or_default() += 1;
                                }
                            }
                        }
                    } else {
                        *self.quality_sources.entry((txt("subject"), ev.clone(), txt("action"))).or_default() += 1;
                    }
                }
                *self.events.entry((st.function.clone(), ev)).or_default() += 1;
            }
        }
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

    /// The metrics in the Prometheus text format, for a scraper.
    fn prometheus(&self) -> String {
        let mut o = String::new();
        let esc = |v: &str| v.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n");
        let mut metric = |name: &str, kind: &str, help: &str, rows: Vec<(String, f64)>| {
            o.push_str(&format!("# HELP goat_processors_{name} {help}\n# TYPE goat_processors_{name} {kind}\n"));
            for (labels, v) in rows {
                o.push_str(&format!("goat_processors_{name}{labels} {v}\n"));
            }
        };
        let k = &self.p.counters;
        let state = self.status();
        let running = state.get("state").and_then(|v| v.as_str()) == Some("running");
        metric("up", "gauge", "1 when the service is running and not paused", vec![(String::new(), if running && !self.paused { 1.0 } else { 0.0 })]);
        metric("reports_in_total", "counter", "reports read, per source (track.source_id)", k.per_source.iter().map(|(s, n)| (format!("{{source=\"{}\"}}", esc(s)), *n as f64)).collect());
        metric("reports_out_total", "counter", "reports passed by every stage", vec![(String::new(), k.reports_out as f64)]);
        metric("reports_stopped_total", "counter", "reports stopped, per stage", k.stopped.iter().map(|(s, n)| (format!("{{function=\"{}\"}}", esc(s)), *n as f64)).collect());
        metric("unreadable_total", "counter", "input samples that were not reports", vec![(String::new(), self.unreadable as f64)]);
        metric("ticks_total", "counter", "ticks made", vec![(String::new(), k.ticks as f64)]);
        metric("published_total", "counter", "values published to the fabric", vec![(String::new(), self.sinks.published as f64)]);
        metric("output_errors_total", "counter", "outputs that failed", vec![(String::new(), self.sinks.errors as f64)]);
        // The system tracks of the latest tick: how many, how many hold
        // members from more than one source, and members per source.
        let mut multi = 0u64;
        let mut per_source: BTreeMap<String, u64> = BTreeMap::new();
        for t in self.tracks.values() {
            let mut srcs = std::collections::BTreeSet::new();
            if let Some(Json::Arr(ms)) = t.get("members") {
                for m in ms.iter().filter_map(|m| m.as_str()) {
                    let src = m.rsplit_once('/').map(|(a, _)| a).unwrap_or(m).to_string();
                    *per_source.entry(src.clone()).or_default() += 1;
                    srcs.insert(src);
                }
            }
            if srcs.len() > 1 {
                multi += 1;
            }
        }
        metric("system_tracks", "gauge", "system tracks at the latest tick", vec![(String::new(), self.tracks.len() as f64)]);
        metric("system_tracks_multi_source", "gauge", "system tracks whose members come from more than one source", vec![(String::new(), multi as f64)]);
        metric("source_tracks", "gauge", "source tracks held in a system track at the latest tick, per source", per_source.iter().map(|(s, n)| (format!("{{source=\"{}\"}}", esc(s)), *n as f64)).collect());
        metric("events_total", "counter", "events returned, per function and event", self.events.iter().map(|((f, e), n)| (format!("{{function=\"{}\",ev=\"{}\"}}", esc(f), esc(e)), *n as f64)).collect());
        metric("quality_source_events_total", "counter", "quality events about a source, per source, event and measure or action", self.quality_sources.iter().map(|((s, e, w), n)| (format!("{{source=\"{}\",ev=\"{}\",what=\"{}\"}}", esc(s), esc(e), esc(w)), *n as f64)).collect());
        let summary = |v: Vec<i64>, scale: f64| -> Vec<(String, f64)> {
            if v.is_empty() {
                return vec![];
            }
            let mut s = v;
            s.sort_unstable();
            let q = |f: f64| s[((s.len() - 1) as f64 * f).round() as usize] as f64 * scale;
            vec![("{quantile=\"0.5\"}".into(), q(0.5)), ("{quantile=\"0.9\"}".into(), q(0.9)), ("{quantile=\"0.99\"}".into(), q(0.99))]
        };
        metric("processing_seconds", "gauge", "time to take one report through every stage, recent reports", summary(self.latency_us.iter().map(|x| *x as i64).collect(), 1e-6));
        metric("report_age_seconds", "gauge", "wall time minus report time at ingest, recent reports (wall clock only)", summary(self.age_ms.iter().copied().collect(), 1e-3));
        metric("last_tick_ms", "gauge", "input-clock time of the latest tick, epoch ms", self.p.last_now_ms.map(|t| vec![(String::new(), t as f64)]).unwrap_or_default());
        o
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
            Ask::Prometheus => crate::http::Response::text(200, "text/plain; version=0.0.4", self.prometheus()),
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
            Ask::Proposals => ok(self.book.to_json()),
            Ask::Propose { function, pack, reason } => self.propose(&call.who, function, pack, reason),
            Ask::Decide { id, verb } => self.decide(&call.who, &id, &verb),
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

impl Runner {
    fn save_book(&self) {
        if let Err(e) = self.book.save(&self.c.agents.proposals_file) {
            eprintln!("warning: cannot write the proposals file: {e}");
        }
    }

    /// Applies a pack selection as `pack use` does: recorded, logged.
    fn apply(&mut self, function: &str, pack: &str, by: &str) -> Result<(), String> {
        self.p.use_pack(function, pack, &self.c.packs_dir.clone())?;
        self.pipeline_changes += 1;
        self.step(Step::Pack { function: function.to_string(), pack: pack.to_string() });
        eprintln!("{function} now runs pack {pack} ({by})");
        Ok(())
    }

    fn propose(&mut self, who: &crate::api::Identity, function: String, pack: String, reason: String) -> crate::http::Response {
        use crate::api::error;
        let Some(stage) = self.p.stages.iter().find(|st| st.function == function) else {
            return error(409, &format!("the pipeline has no {function} stage"), "goat-processors pipeline lists the functions");
        };
        let previous = stage.pack.clone();
        if !pack.starts_with(&format!("{function}-")) || !self.c.packs_dir.join(&pack).join("pack.def").is_file() || pack.contains('/') {
            return error(409, &format!("{pack:?} is not an installed {function} pack"), "goat-processors pack ls lists them");
        }
        let id = self.book.new_id();
        let policy = self.c.agents.auto_approve.iter().find(|r| r.who == who.name && r.function == function && r.packs.iter().any(|p| *p == pack)).cloned();
        let mut prop = crate::proposals::Proposal {
            id: id.clone(),
            by: who.name.clone(),
            via: who.via.to_string(),
            at_ms: wall_ms(),
            function: function.clone(),
            pack: pack.clone(),
            previous_pack: previous,
            reason,
            state: crate::proposals::State::Pending,
            decided_by: None,
            gate: None,
        };
        if let Some(rule) = policy {
            prop.state = crate::proposals::State::Gating;
            let tx = self.tx.clone();
            let (id2, f2, p2) = (id.clone(), function.clone(), pack.clone());
            std::thread::spawn(move || {
                let (passed, gate) = crate::proposals::run_gate(&rule.gate, rule.gate_timeout_s, &f2, &p2);
                let _ = tx.send(Input::GateDone { id: id2, passed, gate });
            });
        }
        eprintln!("proposal {id} by {}: {function} -> {pack} ({})", who.name, prop.state.name());
        let out = prop.to_json();
        self.book.list.push(prop);
        self.save_book();
        crate::http::Response::json(202, out.to_string())
    }

    fn gate_done(&mut self, id: &str, passed: bool, gate: Json) {
        let Some(p) = self.book.get_mut(id) else { return };
        if p.state != crate::proposals::State::Gating {
            return;
        }
        p.gate = Some(gate);
        let (function, pack) = (p.function.clone(), p.pack.clone());
        if passed {
            p.decided_by = Some("policy".into());
            match self.apply(&function, &pack, &format!("proposal {id}, applied by the site policy")) {
                Ok(()) => self.book.get_mut(id).unwrap().state = crate::proposals::State::Applied,
                Err(e) => {
                    let p = self.book.get_mut(id).unwrap();
                    p.state = crate::proposals::State::GateFailed;
                    eprintln!("proposal {id}: the gate passed but the pack did not load: {e}");
                }
            }
        } else {
            p.state = crate::proposals::State::GateFailed;
            eprintln!("proposal {id}: the policy gate failed; it waits for a person");
        }
        self.save_book();
    }

    fn decide(&mut self, who: &crate::api::Identity, id: &str, verb: &str) -> crate::http::Response {
        use crate::api::error;
        use crate::proposals::State;
        let Some(p) = self.book.get_mut(id).cloned() else {
            return error(404, &format!("no proposal {id:?}"), "goat-processors proposals lists them");
        };
        let open = matches!(p.state, State::Pending | State::GateFailed);
        let result = match verb {
            "approve" if open => self.apply(&p.function, &p.pack, &format!("proposal {id}, approved by {}", who.name)).map(|_| State::Applied),
            "reject" if open => Ok(State::Rejected),
            "revert" if p.state == State::Applied => {
                let running = self.p.stages.iter().find(|s| s.function == p.function).map(|s| s.pack.clone()).unwrap_or_default();
                if running != p.pack {
                    return error(409, &format!("{} now runs {running}, not this proposal's {}; reverting would undo a later change", p.function, p.pack), "revert the later change first, or use pack use");
                }
                self.apply(&p.function, &p.previous_pack, &format!("proposal {id}, reverted by {}", who.name)).map(|_| State::Reverted)
            }
            _ => return error(409, &format!("proposal {id} is {}; {verb} does not apply", p.state.name()), "approve and reject apply to pending proposals, revert to applied ones"),
        };
        match result {
            Ok(st) => {
                let q = self.book.get_mut(id).unwrap();
                q.state = st;
                q.decided_by = Some(who.name.clone());
                let out = q.to_json();
                self.save_book();
                crate::http::Response::json(200, out.to_string())
            }
            Err(e) => error(409, &e, ""),
        }
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
        batch: c.outputs.fabric.as_ref().filter(|f| f.layout == crate::config::Layout::Batch).map(|f| Batch {
            heartbeat_ms: f.heartbeat_ms as i64,
            tracks: None,
            quality: None,
            numbers: BTreeMap::new(),
            next_number: 1,
        }),
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
    let gate_tx = tx.clone();
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
    let c_proposals = c.agents.proposals_file.clone();
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
        events: BTreeMap::new(),
        quality_sources: BTreeMap::new(),
        tracks_now_ms: None,
        recent: VecDeque::new(),
        recent_records: 0,
        rate: VecDeque::new(),
        latency_us: VecDeque::new(),
        age_ms: VecDeque::new(),
        book: crate::proposals::Book::load(&c_proposals),
        tx: gate_tx,
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
            Ok(input @ (Input::Reports(_) | Input::Checked(_))) => {
                let (reports, checked) = match input {
                    Input::Checked(r) => (r, true),
                    Input::Reports(r) => (r, false),
                    _ => unreachable!(),
                };
                for mut rep in reports {
                    if !checked {
                        if let Json::Obj(m) = &mut rep {
                            m.remove("provenance.checked");
                        }
                    }
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
            Ok(Input::GateDone { id, passed, gate }) => r.gate_done(&id, passed, gate),
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

#[cfg(test)]
mod batch_tests {
    use super::{mono, Batch};

    #[test]
    fn a_track_says_whether_its_members_come_from_one_source() {
        let m = |ms: &str| mono(&goat_correlator::json::parse(&format!(r#"{{"ev":"system","system":"S1","members":{ms}}}"#)).unwrap());
        assert_eq!(m(r#"["radar-1/T1"]"#), Some(1));
        assert_eq!(m(r#"["radar-1/a/1","radar-1/b/2"]"#), Some(1));
        assert_eq!(m(r#"["radar-1/T1","radar-2/R1"]"#), Some(0));
        assert_eq!(m("[]"), None);
    }

    #[test]
    fn a_set_is_published_on_change_or_at_the_heartbeat() {
        let mut last = None;
        assert!(Batch::due(&mut last, "a".into(), 0, 1000), "the first set is published");
        assert!(!Batch::due(&mut last, "a".into(), 200, 1000), "unchanged within the heartbeat");
        assert!(Batch::due(&mut last, "b".into(), 400, 1000), "changed");
        assert!(!Batch::due(&mut last, "b".into(), 1399, 1000));
        assert!(Batch::due(&mut last, "b".into(), 1400, 1000), "heartbeat");
        assert!(Batch::due(&mut last, "b".into(), 100, 1000), "the clock went back");
    }

    #[test]
    fn a_track_keeps_its_number_and_an_ended_track_frees_it() {
        use goat_correlator::json::{self, Json};
        let mut b = Batch { heartbeat_ms: 1000, tracks: None, quality: None, numbers: Default::default(), next_number: 1 };
        let set = |ids: &[&str]| -> Vec<Json> { ids.iter().map(|i| json::parse(&format!("{{\"group\":\"{i}\"}}")).unwrap()).collect() };
        let num = |t: &Json| t.get("track_number").and_then(|v| v.as_i64()).unwrap();
        let mut a = set(&["s1", "s2"]);
        b.number(&mut a);
        assert_eq!((num(&a[0]), num(&a[1])), (1, 2));
        let mut a = set(&["s2", "s3"]);
        b.number(&mut a);
        assert_eq!((num(&a[0]), num(&a[1])), (2, 3), "s2 keeps 2; s3 takes the next number");
        b.next_number = 65535;
        let mut a = set(&["s2", "s3", "s4", "s5"]);
        b.number(&mut a);
        assert_eq!((num(&a[2]), num(&a[3])), (65535, 1), "wraps past 65535, skipping 0; 1 is free again");
    }
}
