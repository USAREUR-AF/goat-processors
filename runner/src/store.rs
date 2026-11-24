//! The decision store's spill file: what `explain` can still find once a
//! step has left memory.
//!
//! When a step leaves the in-memory store (`store.max_records` or
//! `store.max_age_s`), its events and trace records are appended here as the
//! same cited lines `explain` returns: `{step, now_ms, stage, event}` or
//! `{step, now_ms, stage, record}`. The file is size-limited and rotated like
//! the other files (`max_mb`, `keep`), and older copies are removed once
//! their last write is `max_age_s` old. `explain` reads it in the API's own
//! thread, never in the service loop, so a long read cannot stall a tick.

use std::path::Path;
use std::time::{Duration, Instant};

use crate::config::Spill;
use crate::json::{self, Json};
use crate::rotate::Rotating;

/// Whether an event or trace record names one of `names` (a track and its
/// members).
pub fn names_in(v: &Json, names: &[String]) -> bool {
    ["a", "b", "entity", "group", "system", "subject", "primary"]
        .iter()
        .any(|k| v.get(k).and_then(|x| x.as_str()).is_some_and(|x| names.iter().any(|n| n == x)))
        || matches!(v.get("members"), Some(Json::Arr(ms)) if ms.iter().any(|x| x.as_str().is_some_and(|x| names.iter().any(|n| n == x))))
}

/// How many records may wait for the writer thread; a step that would go
/// past it is dropped and counted (`counters.store_spill_dropped`), so a
/// slow disk never holds up the service loop or fills memory.
pub const QUEUE_RECORDS: usize = 200_000;

/// The spill, written by its own thread: the service loop hands over each
/// step that leaves memory and goes on.
pub struct SpillWriter {
    tx: std::sync::mpsc::SyncSender<(usize, Option<i64>, crate::pipeline::Output)>,
    queued: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    /// Steps written, dropped (queue full) and write errors.
    pub steps: std::sync::Arc<std::sync::atomic::AtomicU64>,
    pub dropped: std::sync::Arc<std::sync::atomic::AtomicU64>,
    pub errors: std::sync::Arc<std::sync::atomic::AtomicU64>,
}

/// One cited line, as `explain` returns it.
pub fn cited(step: usize, now_ms: Option<i64>, stage: &str, key: &str, v: &Json) -> Json {
    let mut m = json::Map::new();
    m.insert("step".into(), Json::Int(step as i64));
    m.insert("now_ms".into(), now_ms.map(Json::Int).unwrap_or(Json::Null));
    m.insert("stage".into(), Json::Str(stage.into()));
    m.insert(key.to_string().into(), v.clone());
    Json::Obj(m)
}

fn records(out: &crate::pipeline::Output) -> usize {
    out.stages.iter().map(|s| s.events.len() + s.trace.len()).sum()
}

impl SpillWriter {
    pub fn open(sp: &Spill) -> Result<SpillWriter, String> {
        use std::sync::atomic::Ordering::Relaxed;
        let mut file = Rotating::open(&sp.path, Some(sp.max_mb), sp.keep)?;
        let max_age = Duration::from_secs(sp.max_age_s);
        file.prune_older_than(max_age);
        let (tx, rx) = std::sync::mpsc::sync_channel::<(usize, Option<i64>, crate::pipeline::Output)>(4096);
        let w = SpillWriter { tx, queued: Default::default(), steps: Default::default(), dropped: Default::default(), errors: Default::default() };
        let (queued, steps, errors) = (w.queued.clone(), w.steps.clone(), w.errors.clone());
        std::thread::spawn(move || {
            let mut pruned_at = Instant::now();
            loop {
                match rx.recv_timeout(Duration::from_secs(60)) {
                    Ok((step, now_ms, out)) => {
                        let mut bad = false;
                        for st in &out.stages {
                            for (key, list) in [("event", &st.events), ("record", &st.trace)] {
                                for v in list {
                                    bad |= file.line(&cited(step, now_ms, &st.function, key, v).to_string()).is_err();
                                }
                            }
                        }
                        queued.fetch_sub(records(&out), Relaxed);
                        steps.fetch_add(1, Relaxed);
                        if bad {
                            errors.fetch_add(1, Relaxed);
                        }
                    }
                    Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                    Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
                }
                // Copies past their age go, at most once a minute.
                if pruned_at.elapsed() >= Duration::from_secs(60) {
                    pruned_at = Instant::now();
                    file.prune_older_than(max_age);
                }
            }
        });
        Ok(w)
    }

    /// Hands one step that left memory to the writer, or drops and counts it
    /// when the queue is full.
    pub fn send(&self, step: usize, now_ms: Option<i64>, out: crate::pipeline::Output) {
        use std::sync::atomic::Ordering::Relaxed;
        let n = records(&out);
        if self.queued.load(Relaxed) + n > QUEUE_RECORDS {
            self.dropped.fetch_add(1, Relaxed);
            return;
        }
        self.queued.fetch_add(n, Relaxed);
        if self.tx.try_send((step, now_ms, out)).is_err() {
            self.queued.fetch_sub(n, Relaxed);
            self.dropped.fetch_add(1, Relaxed);
        }
    }
}

/// The most of the spill one `explain` reads: past it the search stops and
/// says so, so an explain of a track with few records never reads gigabytes.
pub const SEARCH_BYTES: u64 = 256 * 1024 * 1024;

/// The spill's events and trace records that name one of `names`: at most
/// `max` of each, the newest, oldest first. Reads the current file, then the
/// older copies, and stops once both are full or `budget` bytes are read.
/// Returns them, the bytes read, and whether the budget stopped it.
pub fn search(sp: &Spill, names: &[String], max: usize, budget: u64) -> (Vec<Json>, Vec<Json>, u64, bool) {
    let mut events: Vec<Json> = Vec::new();
    let mut trace: Vec<Json> = Vec::new();
    let mut read = 0u64;
    let mut stopped = false;
    for path in Rotating::files(&sp.path, sp.keep) {
        if events.len() >= max && trace.len() >= max {
            break;
        }
        if read >= budget {
            stopped = true;
            break;
        }
        let (e, t, n, cut) = search_file(&path, names, max, budget - read);
        read += n;
        stopped |= cut;
        // An older file's lines go before what the newer files gave.
        events = take_newest([e, events].concat(), max);
        trace = take_newest([t, trace].concat(), max);
        if cut {
            break;
        }
    }
    (events, trace, read, stopped)
}

fn take_newest(v: Vec<Json>, max: usize) -> Vec<Json> {
    let cut = v.len().saturating_sub(max);
    v.into_iter().skip(cut).collect()
}

/// One file's matches, the bytes read, and whether `budget` stopped it. A
/// file is read from its start (lines are oldest first); when the budget
/// stops it, the newest lines of that file are the ones not read.
fn search_file(path: &Path, names: &[String], max: usize, budget: u64) -> (Vec<Json>, Vec<Json>, u64, bool) {
    use std::io::BufRead;
    let mut events = std::collections::VecDeque::new();
    let mut trace = std::collections::VecDeque::new();
    let mut read = 0u64;
    let Ok(f) = std::fs::File::open(path) else { return (vec![], vec![], 0, false) };
    for line in std::io::BufReader::new(f).lines().map_while(Result::ok) {
        read += line.len() as u64 + 1;
        if read > budget {
            return (events.into(), trace.into(), read, true);
        }
        // Only a line that names one of them is parsed.
        if !names.iter().any(|n| line.contains(n.as_str())) {
            continue;
        }
        let Ok(v) = json::parse(&line) else { continue };
        let (q, inner) = match (v.get("event"), v.get("record")) {
            (Some(e), _) => (&mut events, e),
            (_, Some(r)) => (&mut trace, r),
            _ => continue,
        };
        if names_in(inner, names) {
            if q.len() == max {
                q.pop_front();
            }
            q.push_back(v);
        }
    }
    (events.into(), trace.into(), read, false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn out(entity: &str, key: &str) -> crate::pipeline::Output {
        let v = json::parse(&format!(r#"{{"entity":"{entity}","pad":"{}"}}"#, "x".repeat(1000))).unwrap();
        let mut st = crate::pipeline::StageOutput { function: "correlate".into(), events: vec![], trace: vec![] };
        if key == "event" {
            st.events.push(v);
        } else {
            st.trace.push(v);
        }
        crate::pipeline::Output { stages: vec![st] }
    }

    #[test]
    fn the_writer_thread_spills_and_the_search_reads_newest_first_within_a_budget() {
        use std::sync::atomic::Ordering::Relaxed;
        let d = std::env::temp_dir().join(format!("spill-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let sp = Spill { path: d.join("store.jsonl"), max_mb: 1, keep: 2, max_age_s: 86_400 };
        let w = SpillWriter::open(&sp).unwrap();
        // ~1.2 MiB of lines: the file rotates once.
        for step in 0..1200usize {
            w.send(step, Some(step as i64 * 100), out(if step % 100 == 0 { "r/T1" } else { "r/T2" }, "record"));
        }
        w.send(1200, Some(120_000), out("r/T1", "event"));
        let t0 = Instant::now();
        while w.steps.load(Relaxed) + w.dropped.load(Relaxed) < 1201 && t0.elapsed() < Duration::from_secs(10) {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(w.steps.load(Relaxed), 1201, "every step written (the queue had room)");
        assert!(Rotating::files(&sp.path, sp.keep).len() >= 2, "rotated");
        let names = vec!["r/T1".to_string()];
        let (ev, tr, read, stopped) = search(&sp, &names, 1000, SEARCH_BYTES);
        assert!(!stopped && read > 1_000_000);
        assert_eq!(ev.len(), 1);
        let steps: Vec<i64> = tr.iter().map(|t| t.get("step").and_then(Json::as_i64).unwrap()).collect();
        assert_eq!(steps, (0..12).map(|i| i * 100).collect::<Vec<_>>(), "every match, oldest first, across both files");
        let (_, tr, _, _) = search(&sp, &names, 3, SEARCH_BYTES);
        assert_eq!(tr.iter().map(|t| t.get("step").and_then(Json::as_i64).unwrap()).collect::<Vec<_>>(), vec![900, 1000, 1100], "the newest 3");
        // A small budget stops the search and says so.
        let (_, _, read, stopped) = search(&sp, &names, 1000, 100_000);
        assert!(stopped && read <= 102_000, "{read}");
        // A step that would overfill the queue is dropped and counted.
        let mut big = crate::pipeline::Output { stages: vec![crate::pipeline::StageOutput { function: "c".into(), events: vec![], trace: vec![Json::Null; QUEUE_RECORDS + 1] }] };
        w.send(9999, None, std::mem::take(&mut big));
        assert_eq!(w.dropped.load(Relaxed), 1);
        let _ = std::fs::remove_dir_all(&d);
    }
}
