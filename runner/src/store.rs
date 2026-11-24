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

pub struct SpillWriter {
    file: Rotating,
    max_age: Duration,
    pruned_at: Instant,
    /// Steps written, for the status counters.
    pub steps: u64,
}

impl SpillWriter {
    pub fn open(sp: &Spill) -> Result<SpillWriter, String> {
        let file = Rotating::open(&sp.path, Some(sp.max_mb), sp.keep)?;
        let w = SpillWriter { file, max_age: Duration::from_secs(sp.max_age_s), pruned_at: Instant::now(), steps: 0 };
        w.file.prune_older_than(w.max_age);
        Ok(w)
    }

    /// Appends the cited lines of one step that left memory.
    pub fn write(&mut self, lines: &[Json]) -> std::io::Result<()> {
        for l in lines {
            self.file.line(&l.to_string())?;
        }
        self.steps += 1;
        Ok(())
    }

    /// Removes copies past their age, at most once a minute.
    pub fn prune(&mut self) {
        if self.pruned_at.elapsed() >= Duration::from_secs(60) {
            self.pruned_at = Instant::now();
            self.file.prune_older_than(self.max_age);
        }
    }
}

/// The spill's events and trace records that name one of `names`: at most
/// `max` of each, the newest, oldest first. Reads the current file, then the
/// older copies, and stops once both are full.
pub fn search(sp: &Spill, names: &[String], max: usize) -> (Vec<Json>, Vec<Json>) {
    let mut events: Vec<Json> = Vec::new();
    let mut trace: Vec<Json> = Vec::new();
    for path in Rotating::files(&sp.path, sp.keep) {
        if events.len() >= max && trace.len() >= max {
            break;
        }
        let (e, t) = search_file(&path, names, max);
        // An older file's lines go before what the newer files gave.
        events = take_newest([e, events].concat(), max);
        trace = take_newest([t, trace].concat(), max);
    }
    (events, trace)
}

fn take_newest(v: Vec<Json>, max: usize) -> Vec<Json> {
    let cut = v.len().saturating_sub(max);
    v.into_iter().skip(cut).collect()
}

fn search_file(path: &Path, names: &[String], max: usize) -> (Vec<Json>, Vec<Json>) {
    use std::io::BufRead;
    let mut events = std::collections::VecDeque::new();
    let mut trace = std::collections::VecDeque::new();
    let Ok(f) = std::fs::File::open(path) else { return (vec![], vec![]) };
    for line in std::io::BufReader::new(f).lines().map_while(Result::ok) {
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
    (events.into(), trace.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(step: i64, key: &str, entity: &str) -> Json {
        json::parse(&format!(r#"{{"step":{step},"now_ms":{},"stage":"correlate","{key}":{{"entity":"{entity}"}}}}"#, step * 100)).unwrap()
    }

    #[test]
    fn the_spill_is_searched_newest_first_across_rotated_copies() {
        let d = std::env::temp_dir().join(format!("spill-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let sp = Spill { path: d.join("store.jsonl"), max_mb: 1, keep: 2, max_age_s: 86_400 };
        let mut w = SpillWriter::open(&sp).unwrap();
        // ~1.2 MiB of lines: the file rotates once.
        let pad = "x".repeat(1000);
        for step in 0..1200 {
            let mut l = line(step, "record", if step % 100 == 0 { "r/T1" } else { "r/T2" });
            if let Json::Obj(m) = &mut l {
                m.insert("pad".into(), Json::Str(pad.clone()));
            }
            w.write(&[l]).unwrap();
        }
        w.write(&[line(1200, "event", "r/T1")]).unwrap();
        assert!(Rotating::files(&sp.path, sp.keep).len() >= 2, "rotated");
        let names = vec!["r/T1".to_string()];
        let (ev, tr) = search(&sp, &names, 1000);
        assert_eq!(ev.len(), 1);
        let steps: Vec<i64> = tr.iter().map(|t| t.get("step").and_then(Json::as_i64).unwrap()).collect();
        assert_eq!(steps, (0..12).map(|i| i * 100).collect::<Vec<_>>(), "every match, oldest first, across both files");
        let (_, tr) = search(&sp, &names, 3);
        assert_eq!(tr.iter().map(|t| t.get("step").and_then(Json::as_i64).unwrap()).collect::<Vec<_>>(), vec![900, 1000, 1100], "the newest 3");
        assert_eq!(w.steps, 1201);
        let _ = std::fs::remove_dir_all(&d);
    }
}
