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

use std::collections::BTreeMap;
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
        // The track output comes from the last stage that makes tracks.
        let track_stage = out.stages.iter().rposition(|s| s.function == "fuse" || s.function == "correlate");
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
                break;
            }
        }
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

pub fn run(c: Config) -> Result<(), String> {
    let mut p = Pipeline::from_config(&c)?;
    let (tx, rx) = channel::<Input>();
    let started_ms = wall_ms();

    let session = match &c.fabric {
        Some(f) if c.inputs.fabric.is_some() || c.outputs.fabric.is_some() => {
            let keys = c.inputs.fabric.as_ref().map(|i| i.keys.clone()).unwrap_or_default();
            Some(fabric::open(f, &keys, tx.clone())?)
        }
        _ => None,
    };
    let mut sinks = Sinks {
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
    drop(tx);

    eprintln!(
        "goat-processors {}: {} at {}, pipeline {}, output prefix {}, clock {:?}, tick {} ms",
        env!("CARGO_PKG_VERSION"),
        c.name,
        c.site,
        p.stages.iter().map(|s| format!("{}={}", s.function, s.pack)).collect::<Vec<_>>().join(", "),
        sinks.prefix,
        c.clock,
        c.tick_ms
    );

    let tick = c.tick_ms;
    let mut n = 0usize;
    let mut unreadable = 0u64;
    let mut input_clock = InputClock::new(tick);
    let mut next_wall = (wall_ms().div_euclid(tick) + 1) * tick;
    let mut last_tick: Option<i64> = None;
    let mut call = |p: &mut Pipeline, sinks: &mut Sinks, step: Step, unreadable: u64| {
        let out = match &step {
            Step::Ingest(r) => p.ingest(r),
            Step::Tick(t) => p.tick(*t),
        };
        sinks.emit(n, &step, &out);
        n += 1;
        if matches!(step, Step::Tick(_)) {
            let routers = sinks.fabric.as_ref().map(|f| f.routers());
            write_status(&c.status_file, &status(&c, p, started_ms, sinks, unreadable, routers));
        }
    };
    let mut inputs_open = true;
    loop {
        let timeout = match c.clock {
            Clock::Wall => Duration::from_millis((next_wall - wall_ms()).max(0) as u64),
            Clock::Input => Duration::from_millis(tick as u64),
        };
        let got = if inputs_open { rx.recv_timeout(timeout) } else {
            std::thread::sleep(timeout);
            Err(RecvTimeoutError::Timeout)
        };
        match got {
            Ok(Input::Reports(reports)) => {
                for r in reports {
                    if c.clock == Clock::Input {
                        if let Some(t) = replay::report_time(&r) {
                            for now in input_clock.before(t) {
                                call(&mut p, &mut sinks, Step::Tick(now), unreadable);
                            }
                        }
                    }
                    call(&mut p, &mut sinks, Step::Ingest(r), unreadable);
                }
            }
            Ok(Input::Unreadable { from, why }) => {
                unreadable += 1;
                if unreadable <= 10 || unreadable % 1000 == 0 {
                    eprintln!("unreadable input from {from}: {why} ({unreadable} so far)");
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => {
                // Every input has ended (a file input played out, with no fabric
                // or UDP input). With the input clock, close with one tick.
                inputs_open = false;
                if c.clock == Clock::Input {
                    if let Some(now) = input_clock.close() {
                        call(&mut p, &mut sinks, Step::Tick(now), unreadable);
                    }
                    eprintln!("every input has ended; the runner stays up and idle");
                }
            }
        }
        if c.clock == Clock::Wall {
            let now = wall_ms();
            if now >= next_wall {
                let due = now.div_euclid(tick) * tick;
                if last_tick.map_or(true, |l| due > l) {
                    call(&mut p, &mut sinks, Step::Tick(due), unreadable);
                    last_tick = Some(due);
                }
                next_wall = due + tick;
            }
        }
    }
}
