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
use std::net::UdpSocket;
use std::sync::mpsc::{sync_channel, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::json::Json;

use crate::config::{Clock, Config};
use crate::fabric::{self, Input};
use crate::pipeline::{Output, Pipeline};
use crate::replay::{self, InputClock, Step};

pub fn wall_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}


struct Sinks {
    fabric: Option<fabric::Session>,
    prefix: String,
    name: String,
    site: String,
    /// The input clock at the last tick.
    clock: i64,
    /// With `outputs.fabric.trace`: what bounds the trace on the fabric.
    trace: Option<TraceGate>,
    batch: Option<Batch>,
    file: Option<(crate::rotate::Rotating, bool)>,
    record: Option<crate::rotate::Rotating>,
    errors: u64,
    published: u64,
}

/// One second of the input clock: the window of the fabric's rate limits.
const WINDOW_MS: i64 = 1000;

/// Events the `events` key leaves out: track and quality events have their
/// own keys, and `keep` and `pass` repeat each report that went through.
const NOT_EVENTS: [&str; 7] = ["system", "fused", "quality", "action-start", "action-end", "keep", "pass"];

/// The source an event is about: the part of its entity before `/`.
fn event_source(e: &Json) -> String {
    let name = ["entity", "a", "subject"].iter().find_map(|k| e.get(k).and_then(|v| v.as_str())).unwrap_or("");
    name.split('/').next().filter(|s| !s.is_empty()).unwrap_or("-").to_string()
}

/// At most `per_s` events per source in each second of the input clock.
struct Limiter {
    per_s: u32,
    window: i64,
    counts: BTreeMap<String, u32>,
    dropped: BTreeMap<String, u64>,
    total: u64,
}

impl Limiter {
    fn new(per_s: u32) -> Limiter {
        Limiter { per_s, window: i64::MIN, counts: BTreeMap::new(), dropped: BTreeMap::new(), total: 0 }
    }

    /// Whether one more event from `source` may go out now.
    fn admit(&mut self, source: &str) -> bool {
        let n = self.counts.entry(source.to_string()).or_insert(0);
        if *n < self.per_s {
            *n += 1;
            return true;
        }
        *self.dropped.entry(source.to_string()).or_insert(0) += 1;
        self.total += 1;
        false
    }

    /// At a tick: when the window has passed, one `suppressed` line per
    /// source that went over, and a new window.
    fn roll(&mut self, now: i64) -> Vec<Json> {
        if self.window != i64::MIN && now >= self.window && now - self.window < WINDOW_MS {
            return vec![];
        }
        let from = self.window;
        self.window = now;
        self.counts.clear();
        std::mem::take(&mut self.dropped)
            .into_iter()
            .map(|(src, n)| {
                let mut m = BTreeMap::new();
                m.insert("ev".into(), Json::Str("suppressed".into()));
                m.insert("stage".into(), Json::Str("runner".into()));
                m.insert("source".into(), Json::Str(src));
                m.insert("count".into(), Json::Int(n as i64));
                m.insert("from_ms".into(), Json::Int(from));
                m.insert("limit_per_s".into(), Json::Int(self.per_s as i64));
                Json::Obj(m)
            })
            .collect()
    }
}

/// What bounds the trace on the fabric: the entities it names, an end, and
/// the most bytes in one second of the input clock.
struct TraceGate {
    entities: Vec<String>,
    end_wall_ms: i64,
    max_bytes: u64,
    window: i64,
    bytes: u64,
    dropped: u64,
    total_dropped: u64,
}

impl TraceGate {
    fn on(&self) -> bool {
        wall_ms() < self.end_wall_ms
    }

    /// Whether a record names one of the listed entities (any, with no list).
    fn wanted(&self, r: &Json) -> bool {
        if self.entities.is_empty() {
            return true;
        }
        let named = |v: &Json| v.as_str().is_some_and(|x| self.entities.iter().any(|e| e == x));
        ["entity", "a", "b", "system", "group", "subject"].iter().any(|k| r.get(k).is_some_and(named))
            || matches!(r.get("members"), Some(Json::Arr(ms)) if ms.iter().any(named))
    }

    /// Whether `len` more bytes fit in this second, at input-clock `now`.
    fn admit(&mut self, now: i64, len: usize) -> bool {
        if now < self.window || now.saturating_sub(self.window) >= WINDOW_MS {
            self.window = now;
            self.bytes = 0;
        }
        if self.bytes + len as u64 > self.max_bytes {
            self.dropped += 1;
            self.total_dropped += 1;
            return false;
        }
        self.bytes += len as u64;
        true
    }
}

/// State of `layout: batch`: what was last published, and when.
struct Batch {
    heartbeat_ms: i64,
    tracks: Option<(String, i64)>,
    /// The quality picture: each subject's latest measures, the marks in
    /// force (action-start until its action-end), the marks cleared since
    /// the last publish, and whether a mark was set or cleared since then.
    measures: BTreeMap<(String, String), Json>,
    marks: BTreeMap<(String, String, String, String), Json>,
    cleared: Vec<Json>,
    marks_changed: bool,
    quality_at: Option<i64>,
    status: Option<i64>,
    /// Events and trace records since the last tick, each with its stage.
    events: Vec<Json>,
    trace: Vec<Json>,
    limiter: Limiter,
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

    /// Takes one quality event into the picture.
    fn note_quality(&mut self, e: &Json) {
        let f = |k: &str| e.get(k).and_then(|v| v.as_str()).unwrap_or("").to_string();
        match e.get("ev").and_then(|v| v.as_str()) {
            Some("quality") => {
                self.measures.insert((f("scope"), f("subject")), e.clone());
            }
            Some("action-start") => {
                self.marks.insert((f("scope"), f("subject"), f("action"), f("rule")), e.clone());
                self.marks_changed = true;
            }
            Some("action-end") => {
                self.marks.remove(&(f("scope"), f("subject"), f("action"), f("rule")));
                self.cleared.push(e.clone());
                self.marks_changed = true;
            }
            Some("forget") => {
                for scope in ["entity", "source"] {
                    if let Some(x) = e.get(scope).and_then(|v| v.as_str()) {
                        self.measures.remove(&(scope.to_string(), x.to_string()));
                    }
                }
            }
            _ => {}
        }
    }

    /// The quality value, when it is due at `now`: a mark set or cleared
    /// since the last publish, or `heartbeat_ms` passed. It holds every
    /// subject's latest measures, the marks in force and the marks cleared
    /// since the last publish, so one value is the whole picture.
    fn quality_due(&mut self, now: i64) -> Option<Vec<Json>> {
        let due = self.marks_changed || match self.quality_at {
            None => true,
            Some(t) => now - t >= self.heartbeat_ms || now < t,
        };
        if !due {
            return None;
        }
        self.quality_at = Some(now);
        self.marks_changed = false;
        let mut v: Vec<Json> = self.measures.values().cloned().collect();
        v.extend(self.marks.values().cloned());
        v.append(&mut self.cleared);
        Some(v)
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
            if rec.line(&step.to_line()).is_err() {
                self.errors += 1;
            }
        }
        if let Some((f, trace)) = self.file.as_mut() {
            for l in replay::output_lines(n, step, out, *trace) {
                if f.line(&l).is_err() {
                    self.errors += 1;
                }
            }
        }
        if self.fabric.is_none() {
            return;
        }
        let now = match step {
            Step::Tick(t) => Some(*t),
            _ => None,
        };
        if let Some(t) = now {
            self.clock = t;
        }
        if self.batch.is_some() {
            self.emit_batch(out, now);
        } else {
            self.emit_per_entity(out, now);
        }
    }

    /// Trace records of one stage that pass the trace bounds.
    fn gate_trace(&mut self, stage: &str, records: &[Json]) -> Vec<Json> {
        let clock = self.clock;
        let Some(g) = self.trace.as_mut().filter(|g| g.on()) else { return vec![] };
        let mut kept = Vec::new();
        for r in records {
            if !g.wanted(r) {
                continue;
            }
            let mut r = r.clone();
            if let Json::Obj(m) = &mut r {
                m.insert("stage".into(), Json::Str(stage.into()));
            }
            if g.admit(clock, r.to_string().len() + 1) {
                kept.push(r);
            }
        }
        kept
    }

    /// `layout: batch`: events and trace are gathered at every step; on a
    /// tick each key of the fixed set is published at most once.
    fn emit_batch(&mut self, out: &Output, now: Option<i64>) {
        let track_stage = track_stage(out);
        let mut gathered_trace = Vec::new();
        for s in &out.stages {
            gathered_trace.extend(self.gate_trace(&s.function, &s.trace));
        }
        let b = self.batch.as_mut().expect("batch layout");
        b.trace.extend(gathered_trace);
        for s in &out.stages {
            for e in &s.events {
                let ev = e.get("ev").and_then(|v| v.as_str()).unwrap_or("");
                if NOT_EVENTS.contains(&ev) || !b.limiter.admit(&event_source(e)) {
                    continue;
                }
                let mut e = e.clone();
                if let Json::Obj(m) = &mut e {
                    m.insert("stage".into(), Json::Str(s.function.clone()));
                }
                b.events.push(e);
            }
        }
        for e in out.stages.iter().filter(|s| s.function == "quality").flat_map(|s| s.events.iter()) {
            b.note_quality(e);
        }
        let Some(t) = now else { return };
        // Each set is JSON lines: one object per line, each with `now_ms`,
        // so a reader splits it with newline framing, and the runner's own
        // input reads it as a list of reports.
        let lines = |v: &[Json]| v.iter().map(|e| with_now(e, now).to_string() + "\n").collect::<String>();
        let mut texts: Vec<(String, String)> = Vec::new();
        let mut tracks: Vec<Json> = track_events(out).into_iter().map(|(_, e)| e).collect();
        if track_stage.is_some() {
            b.number(&mut tracks);
        }
        if track_stage.is_some() && Batch::due(&mut b.tracks, Json::Arr(tracks.clone()).to_string(), t, b.heartbeat_ms) {
            texts.push((format!("{}/tracks", self.prefix), lines(&tracks)));
        }
        if out.stages.iter().any(|s| s.function == "quality") {
            if let Some(q) = b.quality_due(t) {
                texts.push((format!("{}/quality", self.prefix), lines(&q)));
            }
        }
        let mut events = std::mem::take(&mut b.events);
        events.extend(b.limiter.roll(t));
        if !events.is_empty() {
            texts.push((format!("{}/events", self.prefix), lines(&events)));
        }
        let mut trace = std::mem::take(&mut b.trace);
        if let Some(g) = self.trace.as_mut().filter(|g| g.dropped > 0 && (t < g.window || t.saturating_sub(g.window) >= WINDOW_MS)) {
            let mut m = BTreeMap::new();
            m.insert("stage".into(), Json::Str("runner".into()));
            m.insert("suppressed".into(), Json::Int(std::mem::take(&mut g.dropped) as i64));
            m.insert("limit_bytes_per_s".into(), Json::Int(g.max_bytes as i64));
            trace.push(Json::Obj(m));
        }
        if !trace.is_empty() {
            texts.push((format!("{}/trace", self.prefix), lines(&trace)));
        }
        let status_due = match b.status {
            None => true,
            Some(last) => t - last >= b.heartbeat_ms || t < last,
        };
        if status_due {
            b.status = Some(t);
            let mut m = BTreeMap::new();
            m.insert("name".into(), Json::Str(self.name.clone()));
            m.insert("site".into(), Json::Str(self.site.clone()));
            m.insert("version".into(), Json::Str(env!("CARGO_PKG_VERSION").into()));
            m.insert("tracks".into(), Json::Int(tracks.len() as i64));
            m.insert("published".into(), Json::Int(self.published as i64));
            m.insert("output_errors".into(), Json::Int(self.errors as i64));
            m.insert("events_suppressed".into(), Json::Int(b.limiter.total as i64));
            m.insert("trace_on".into(), Json::Bool(self.trace.as_ref().is_some_and(|g| g.on())));
            m.insert("trace_suppressed".into(), Json::Int(self.trace.as_ref().map_or(0, |g| g.total_dropped) as i64));
            texts.push((format!("{}/status", self.prefix), lines(&[Json::Obj(m)])));
        }
        let fab = self.fabric.as_ref().expect("fabric");
        for (k, v) in texts {
            match fab.put_text(&k, v) {
                Ok(()) => self.published += 1,
                Err(_) => self.errors += 1,
            }
        }
    }

    /// `layout: per-entity`, the layout before 0.6.0: a key per system track
    /// and per quality subject, events on every call.
    fn emit_per_entity(&mut self, out: &Output, now: Option<i64>) {
        let mut puts: Vec<(String, Json)> = Vec::new();
        let track_stage = track_stage(out);
        for (i, s) in out.stages.iter().enumerate() {
            if !s.events.is_empty() {
                puts.push((format!("{}/events/{}", self.prefix, s.function), line_obj(&s.function, now, Json::Arr(s.events.clone()), "events")));
            }
            let trace = self.gate_trace(&s.function, &s.trace);
            if !trace.is_empty() {
                puts.push((format!("{}/trace/{}", self.prefix, s.function), line_obj(&s.function, now, Json::Arr(trace), "trace")));
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
        let fab = self.fabric.as_ref().expect("fabric");
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
fn q_entry<'a>(sources: &'a mut BTreeMap<String, BTreeMap<String, Json>>, src: &str) -> &'a mut BTreeMap<String, Json> {
    sources.entry(src.to_string()).or_insert_with(|| {
        let mut m = BTreeMap::new();
        m.insert("measures".into(), Json::Null);
        m.insert("actions".into(), Json::Arr(vec![]));
        m.insert("entity_actions".into(), Json::Int(0));
        m.insert("reports".into(), Json::Int(0));
        m
    })
}

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

/// Inputs waiting for the service loop. A burst larger than this (the loop
/// is behind) is dropped at the fabric and UDP inputs and counted in
/// `counters.dropped_backlog`, so a flood of reports cannot use up memory.
/// The file input, the API and the agents wait instead.
pub const INPUT_QUEUE: usize = 65_536;

/// Reports dropped because the input queue was full.
pub static DROPPED_BACKLOG: AtomicU64 = AtomicU64::new(0);

/// Trace records `explain` does not keep because one step returned more than
/// it keeps in all (`store.max_records`).
pub static TRACE_NOT_KEPT: AtomicU64 = AtomicU64::new(0);

/// Trace records the pipeline returned, in all and in the largest single
/// step: how much trace the engines make, whatever is kept of it.
pub static TRACE_RECORDS: AtomicU64 = AtomicU64::new(0);
pub static TRACE_MAX_STEP: AtomicU64 = AtomicU64::new(0);

/// Sends an input from a source that must not wait (a fabric callback, a
/// UDP socket). Returns false when the service loop has ended.
pub fn offer(tx: &SyncSender<Input>, input: Input) -> bool {
    match tx.try_send(input) {
        Ok(()) => true,
        Err(TrySendError::Full(_)) => {
            DROPPED_BACKLOG.fetch_add(1, Ordering::Relaxed);
            true
        }
        Err(TrySendError::Disconnected(_)) => false,
    }
}

fn spawn_udp(listen: &str, tx: SyncSender<Input>) -> Result<(), String> {
    let sock = UdpSocket::bind(listen).map_err(|e| format!("cannot listen on UDP {listen}: {e}"))?;
    let from = format!("udp/{listen}");
    std::thread::spawn(move || {
        let mut buf = vec![0u8; 65536];
        while let Ok((n, _)) = sock.recv_from(&mut buf) {
            if !offer(&tx, fabric::decode(&from, &buf[..n])) {
                break;
            }
        }
    });
    Ok(())
}

/// Plays a file into the service at `speed` times the pace of its report times.
fn spawn_file(path: &std::path::Path, speed: f64, tx: SyncSender<Input>) -> Result<(), String> {
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


/// Processing times kept for the latency figures.
const LATENCY_SAMPLES: usize = 2048;

struct Recent {
    step: usize,
    now_ms: Option<i64>,
    /// The tick it belongs to: its own, or the latest before it (an ingest).
    at_ms: Option<i64>,
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
    /// The latest quality measures of each source, and the quality actions
    /// now active, by (subject, rule): what the operator page shows. Bounded
    /// by the quality engine, which forgets sources and ends their actions.
    quality_latest: BTreeMap<String, Json>,
    quality_active: BTreeMap<(String, String), Json>,
    tracks_now_ms: Option<i64>,
    recent: VecDeque<Recent>,
    /// `store.spill`: where steps that leave memory go.
    spill: Option<crate::store::SpillWriter>,
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
    tx: SyncSender<Input>,
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
                        if let Some(crate::json::Json::Obj(ms)) = e.get("measures") {
                            for (name, value) in ms.iter() {
                                if !matches!(value, crate::json::Json::Null) {
                                    *self.quality_sources.entry((txt("subject"), ev.clone(), name.to_string())).or_default() += 1;
                                }
                            }
                        }
                    } else {
                        *self.quality_sources.entry((txt("subject"), ev.clone(), txt("action"))).or_default() += 1;
                    }
                }
                if st.function == "quality" {
                    match ev.as_str() {
                        "quality" if txt("scope") == "source" => {
                            self.quality_latest.insert(txt("subject"), e.get("measures").cloned().unwrap_or(Json::Null));
                        }
                        "action-start" => {
                            self.quality_active.insert((txt("subject"), txt("rule")), e.clone());
                        }
                        "action-end" => {
                            self.quality_active.remove(&(txt("subject"), txt("rule")));
                        }
                        "forget" if !txt("source").is_empty() => {
                            self.quality_latest.remove(&txt("source"));
                        }
                        _ => {}
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
        let mut out = out;
        let mut records: usize = out.stages.iter().map(|s| s.trace.len()).sum();
        TRACE_RECORDS.fetch_add(records as u64, Ordering::Relaxed);
        TRACE_MAX_STEP.fetch_max(records as u64, Ordering::Relaxed);
        let cap = self.c.store.max_records;
        if records > cap {
            // One step larger than the whole store (correlate's tick at a
            // thousand objects returns millions of records): keep the first
            // records of each stage up to the bound and count the rest.
            let mut room = cap;
            for st in out.stages.iter_mut() {
                let keep = st.trace.len().min(room);
                st.trace.truncate(keep);
                st.trace.shrink_to_fit();
                room -= keep;
            }
            TRACE_NOT_KEPT.fetch_add((records - cap) as u64, Ordering::Relaxed);
            records = cap;
        }
        if !out.stages.is_empty() {
            let at_ms = now.or(self.p.last_now_ms);
            self.recent.push_back(Recent { step: self.n, now_ms: now, at_ms, out });
            self.recent_records += records;
            // Steps leave memory past the record bound or past the age bound
            // (input-clock seconds behind the latest tick); the newest stays.
            let oldest_kept = self.c.store.max_age_s.and_then(|a| self.p.last_now_ms.map(|t| t - a as i64 * 1000));
            while self.recent.len() > 1 {
                let front = self.recent.front().unwrap();
                let too_old = matches!((front.at_ms, oldest_kept), (Some(a), Some(o)) if a < o);
                if self.recent_records <= cap && !too_old {
                    break;
                }
                let old = self.recent.pop_front().unwrap();
                self.recent_records -= old.out.stages.iter().map(|s| s.trace.len()).sum::<usize>();
                // To the spill's own thread: the loop hands the step over
                // (no copy, no write here) and goes on.
                if let Some(sp) = self.spill.as_ref() {
                    sp.send(old.step, old.now_ms, old.out);
                }
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
                cnt.insert("dropped_backlog".into(), Json::Int(DROPPED_BACKLOG.load(Ordering::Relaxed) as i64));
                cnt.insert("trace_not_kept".into(), Json::Int(TRACE_NOT_KEPT.load(Ordering::Relaxed) as i64));
                cnt.insert("api_rate_limited".into(), Json::Int(crate::api::RATE_REFUSED.load(Ordering::Relaxed) as i64));
                let load = |f: fn(&crate::store::SpillWriter) -> u64| self.spill.as_ref().map_or(0, f) as i64;
                cnt.insert("store_spilled_steps".into(), Json::Int(load(|s| s.steps.load(Ordering::Relaxed))));
                cnt.insert("store_spill_dropped".into(), Json::Int(load(|s| s.dropped.load(Ordering::Relaxed))));
                cnt.insert("store_spill_errors".into(), Json::Int(load(|s| s.errors.load(Ordering::Relaxed))));
                cnt.insert("trace_records".into(), Json::Int(TRACE_RECORDS.load(Ordering::Relaxed) as i64));
                cnt.insert("trace_max_step".into(), Json::Int(TRACE_MAX_STEP.load(Ordering::Relaxed) as i64));
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
        metric("api_rate_limited_total", "counter", "API requests refused because their caller was over api.rate_per_s", vec![(String::new(), crate::api::RATE_REFUSED.load(Ordering::Relaxed) as f64)]);
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

    /// Everything the operator page shows (GET /v1/view).
    fn view(&self, who: &crate::api::Identity) -> Json {
        let installed = crate::api::installed_packs(&self.c.packs_dir);
        let pipeline: Vec<Json> = self
            .p
            .stages
            .iter()
            .map(|st| {
                let mut m = BTreeMap::new();
                m.insert("function".into(), Json::Str(st.function.clone()));
                m.insert("pack".into(), Json::Str(st.pack.clone()));
                m.insert("packs".into(), Json::Arr(installed.iter().filter(|(f, _)| *f == st.function).map(|(_, n)| Json::Str(n.clone())).collect()));
                Json::Obj(m)
            })
            .collect();
        // Quality per source: its latest measures, its own active actions, and
        // how many of its entities have an active action.
        let mut sources: BTreeMap<String, BTreeMap<String, Json>> = BTreeMap::new();
        for (src, measures) in &self.quality_latest {
            q_entry(&mut sources, src).insert("measures".into(), measures.clone());
        }
        for ((subject, _), e) in &self.quality_active {
            if e.get("scope").and_then(|v| v.as_str()) == Some("source") {
                if let Some(Json::Arr(a)) = q_entry(&mut sources, subject).get_mut("actions") {
                    a.push(e.clone());
                }
            } else {
                let src = subject.split('/').next().unwrap_or(subject);
                if let Some(Json::Int(n)) = q_entry(&mut sources, src).get_mut("entity_actions") {
                    *n += 1;
                }
            }
        }
        for (src, n) in &self.p.counters.per_source {
            q_entry(&mut sources, src).insert("reports".into(), Json::Int(*n as i64));
        }
        let quality: Vec<Json> = sources
            .into_iter()
            .map(|(src, m)| {
                let mut m: BTreeMap<_, _> = m.into_iter().map(|(k, v)| (k.into(), v)).collect();
                m.insert("source".into(), Json::Str(src));
                Json::Obj(m)
            })
            .collect();
        let mut you = BTreeMap::new();
        you.insert("name".into(), Json::Str(who.name.clone()));
        you.insert("role".into(), Json::Str(who.role.name().into()));
        you.insert("via".into(), Json::Str(who.via.into()));
        let mut m = BTreeMap::new();
        m.insert("status".into(), self.status());
        m.insert("health".into(), {
            let (good, why) = self.healthy();
            let mut h = BTreeMap::new();
            h.insert("healthy".into(), Json::Bool(good));
            h.insert("detail".into(), Json::Str(why));
            Json::Obj(h)
        });
        m.insert("pipeline".into(), Json::Arr(pipeline));
        m.insert("now_ms".into(), self.tracks_now_ms.map(Json::Int).unwrap_or(Json::Null));
        // The page needs every track to draw the plan, up to the API's most.
        m.insert("tracks".into(), Json::Arr(self.tracks.values().take(crate::api::PAGE_MAX).cloned().collect()));
        m.insert("tracks_total".into(), Json::Int(self.tracks.len() as i64));
        m.insert("quality".into(), Json::Arr(quality));
        m.insert("proposals".into(), self.book.newest(crate::api::PAGE_DEFAULT));
        m.insert("you".into(), Json::Obj(you));
        Json::Obj(m)
    }

    /// One page of the system tracks (GET /v1/tracks), with how many there
    /// are and, when more follow, the `next` to ask with.
    fn tracks_json(&self, page: &crate::api::Page) -> Json {
        let (tracks, next) = page.cut(self.tracks.iter());
        let mut m = BTreeMap::new();
        m.insert("now_ms".into(), self.tracks_now_ms.map(Json::Int).unwrap_or(Json::Null));
        m.insert("tracks".into(), Json::Arr(tracks));
        m.insert("total".into(), Json::Int(self.tracks.len() as i64));
        m.insert("next".into(), next.map(Json::Str).unwrap_or(Json::Null));
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
        let names_in = |v: &Json| crate::store::names_in(v, &names);
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
            Ask::Tracks(page) => match page.at {
                Some(at) if Some(at) != self.tracks_now_ms => error(
                    409,
                    &format!("the tracks of tick {at} are gone: tick {} replaced them", self.tracks_now_ms.map(|t| t.to_string()).unwrap_or("-".into())),
                    "start again from the first page (without after and at)",
                ),
                _ => ok(self.tracks_json(&page)),
            },
            Ask::View => ok(self.view(&call.who)),
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
            Ask::Proposals(page) => ok(self.book.newest(page.limit)),
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
    let spill = match &c.store.spill {
        Some(sp) => Some(crate::store::SpillWriter::open(sp)?),
        None => None,
    };
    let p = Pipeline::from_config(&c)?;
    // A certificate that names another peer than the output prefix: the
    // fabric may drop everything published. Say so where the log is read.
    if let Some(x) = crate::doctor::output_peer_check(&c).filter(|x| x.level != crate::doctor::Level::Ok) {
        eprintln!("{}: {}; fix: {}", if x.level == crate::doctor::Level::Fail { "ERROR" } else { "warning" }, x.detail, x.fix);
    }
    let (tx, rx) = sync_channel::<Input>(INPUT_QUEUE);

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
        name: c.name.clone(),
        site: c.site.clone(),
        clock: 0,
        trace: c.outputs.fabric.as_ref().filter(|f| f.trace).map(|f| TraceGate {
            entities: f.trace_entities.clone(),
            end_wall_ms: wall_ms().saturating_add(f.trace_for_s as i64 * 1000),
            max_bytes: f.trace_max_bytes_per_s,
            window: i64::MIN,
            bytes: 0,
            dropped: 0,
            total_dropped: 0,
        }),
        batch: c.outputs.fabric.as_ref().filter(|f| f.layout == crate::config::Layout::Batch).map(|f| Batch {
            heartbeat_ms: f.heartbeat_ms as i64,
            tracks: None,
            measures: BTreeMap::new(),
            marks: BTreeMap::new(),
            cleared: Vec::new(),
            marks_changed: false,
            quality_at: None,
            status: None,
            events: Vec::new(),
            trace: Vec::new(),
            limiter: Limiter::new(f.events_per_source_per_s),
            numbers: BTreeMap::new(),
            next_number: 1,
        }),
        file: match &c.outputs.file {
            Some(f) => Some((crate::rotate::Rotating::open(&f.path, f.max_mb, f.keep)?, f.trace)),
            None => None,
        },
        record: match &c.record {
            Some(r) => Some(crate::rotate::Rotating::open(&r.path, r.max_mb, r.keep)?),
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
        quality_latest: BTreeMap::new(),
        quality_active: BTreeMap::new(),
        tracks_now_ms: None,
        recent: VecDeque::new(),
        spill,
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
                    if let Err(why) = fabric::in_range(&rep) {
                        r.unreadable += 1;
                        if r.unreadable <= 10 || r.unreadable % 1000 == 0 {
                            eprintln!("refused a report out of range: {why} ({} unreadable so far)", r.unreadable);
                        }
                        continue;
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
    use super::{event_source, Batch, Limiter, TraceGate};
    use crate::json::{parse, Json};

    #[test]
    fn quality_goes_out_when_a_mark_changes_else_at_the_heartbeat() {
        let mut b = Batch { heartbeat_ms: 5000, tracks: None, measures: Default::default(), marks: Default::default(), cleared: vec![], marks_changed: false, quality_at: None, status: None, events: vec![], trace: vec![], limiter: Limiter::new(20), numbers: Default::default(), next_number: 1 };
        let q = |subject: &str, n: i64| parse(&format!(r#"{{"ev":"quality","scope":"entity","subject":"{subject}","measures":{{"reports":{n}}}}}"#)).unwrap();
        b.note_quality(&q("r/T1", 1));
        assert_eq!(b.quality_due(0).map(|v| v.len()), Some(1), "the first tick publishes");
        b.note_quality(&q("r/T1", 2));
        assert!(b.quality_due(1000).is_none(), "new measures alone wait for the heartbeat");
        let start = parse(r#"{"ev":"action-start","scope":"entity","subject":"r/T1","action":"alert","rule":"silent"}"#).unwrap();
        b.note_quality(&start);
        let v = b.quality_due(2000).expect("a mark set goes out at once");
        assert_eq!(v.len(), 2, "latest measures and the mark: {v:?}");
        assert!(v[0].to_string().contains(r#""reports":2"#));
        assert!(b.quality_due(3000).is_none());
        let v = b.quality_due(7000).expect("the heartbeat");
        assert!(v.iter().any(|e| e.get("ev").and_then(Json::as_str) == Some("action-start")), "a mark in force stays in every value");
        b.note_quality(&parse(r#"{"ev":"action-end","scope":"entity","subject":"r/T1","action":"alert","rule":"silent","reason":"clear"}"#).unwrap());
        let v = b.quality_due(8000).expect("a mark cleared goes out at once");
        assert!(v.iter().any(|e| e.get("ev").and_then(Json::as_str) == Some("action-end")) && !v.iter().any(|e| e.get("ev").and_then(Json::as_str) == Some("action-start")));
        b.note_quality(&parse(r#"{"ev":"forget","entity":"r/T1"}"#).unwrap());
        assert_eq!(b.quality_due(13000).map(|v| v.len()), Some(0), "a forgotten subject leaves the picture; the cleared mark was sent once");
    }

    #[test]
    fn events_over_the_limit_are_counted_and_summarized_once_a_second() {
        let mut l = Limiter::new(2);
        l.roll(0);
        assert!(l.admit("radar-1") && l.admit("radar-1") && !l.admit("radar-1") && !l.admit("radar-1"));
        assert!(l.admit("adsb"), "each source has its own limit");
        assert!(l.roll(500).is_empty(), "within the second");
        assert!(!l.admit("radar-1"));
        let s = l.roll(1000);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].get("source").and_then(Json::as_str), Some("radar-1"));
        assert_eq!(s[0].get("count").and_then(Json::as_i64), Some(3));
        assert!(l.admit("radar-1"), "a new second");
        assert_eq!(l.total, 3);
        assert_eq!(event_source(&parse(r#"{"entity":"radar-1/T1"}"#).unwrap()), "radar-1");
        assert_eq!(event_source(&parse(r#"{"a":"adsb/A7","b":"x/y"}"#).unwrap()), "adsb");
        assert_eq!(event_source(&parse(r#"{"system":"S1"}"#).unwrap()), "-");
    }

    #[test]
    fn the_trace_names_listed_entities_ends_and_has_a_byte_ceiling() {
        let mut g = TraceGate { entities: vec!["radar-1/T1".into()], end_wall_ms: i64::MAX, max_bytes: 100, window: i64::MIN, bytes: 0, dropped: 0, total_dropped: 0 };
        assert!(g.wanted(&parse(r#"{"entity":"radar-1/T1"}"#).unwrap()));
        assert!(g.wanted(&parse(r#"{"a":"adsb/A7","b":"radar-1/T1"}"#).unwrap()));
        assert!(g.wanted(&parse(r#"{"members":["radar-1/T1"]}"#).unwrap()));
        assert!(!g.wanted(&parse(r#"{"entity":"adsb/A7"}"#).unwrap()));
        assert!(g.admit(0, 60) && !g.admit(10, 60) && g.admit(20, 40));
        assert!(g.admit(1000, 60), "a new second");
        assert_eq!(g.total_dropped, 1);
        assert!(g.on());
        g.end_wall_ms = 0;
        assert!(!g.on(), "past its end");
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
        use crate::json::{self, Json};
        let mut b = Batch { heartbeat_ms: 1000, tracks: None, measures: Default::default(), marks: Default::default(), cleared: vec![], marks_changed: false, quality_at: None, status: None, events: vec![], trace: vec![], limiter: Limiter::new(20), numbers: Default::default(), next_number: 1 };
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

#[cfg(test)]
mod input_queue_tests {
    use super::*;

    #[test]
    fn a_full_input_queue_drops_and_counts_instead_of_growing() {
        let (tx, rx) = sync_channel::<Input>(1);
        let before = DROPPED_BACKLOG.load(Ordering::Relaxed);
        assert!(offer(&tx, Input::Ended));
        assert!(offer(&tx, Input::Ended), "full: dropped, but the input keeps running");
        assert!(DROPPED_BACKLOG.load(Ordering::Relaxed) > before);
        drop(rx);
        assert!(!offer(&tx, Input::Ended), "the service loop has ended: the input stops");
    }
}
