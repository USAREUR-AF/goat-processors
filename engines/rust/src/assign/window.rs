//! correlate-assign.md Window: on each tick, staleness and restarted
//! entities, the rows, every source's ranked assignments in every history,
//! the commit, the bias update and the output (`system`, `provisional`).

use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

use super::membership::{History, Record};
use super::ranking::{ranked_assignments, Choice};
use super::{names, system_name};
use crate::correlate::{course_speed, Engine};
use crate::model::{obj, Json};
use crate::trace::{event, record, tagged, StepResult};

impl Engine {

    // ---- Window: on each tick

    pub(crate) fn tick_assign(&mut self, now_ms: i64) -> StepResult {
        let mut out = StepResult::default();

        // 1. Staleness, among entities that are not retiring, in key order.
        let stale: Vec<String> = self.stale_entities(now_ms).into_iter().filter(|k| !self.retiring.contains(k)).collect();
        for h in &mut self.histories {
            let mut rec = Record { cost: 0.0, choices: Vec::new(), events: Vec::new(), membership: h.latest(&self.committed).clone() };
            for k in &stale {
                rec.membership.leave(k, "stale", &mut rec.events);
                rec.events.push(event("drop", vec![("entity", k.as_str().into())]));
            }
            h.records.push(rec);
        }
        // Each restarted entity that is not stale, in key order, leaves its
        // system track; no entity is restarted after this step.
        let restarted: Vec<String> = std::mem::take(&mut self.restarted).into_iter().filter(|k| !stale.contains(k)).collect();
        for h in &mut self.histories {
            let rec = h.records.last_mut().expect("just pushed");
            for k in &restarted {
                rec.membership.leave(k, "restart", &mut rec.events);
            }
        }
        self.retiring.extend(stale.iter().cloned());

        // 2. Rows: entities reported since the previous tick, not found stale,
        // grouped by source; sources and entities in key order.
        let mut by_source: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for k in std::mem::take(&mut self.reported) {
            if !self.retiring.contains(&k) {
                by_source.entry(self.entities[&k].source.clone()).or_default().push(k);
            }
        }

        let rows: BTreeSet<String> = by_source.values().flatten().cloned().collect();

        // 3. Sources, in key order.
        for (source, r) in &by_source {
            self.assign_source(source, r, &mut out.trace);
        }

        // 4. Commit, when the best history has `window` records.
        if self.histories[0].records.len() == self.pack.window {
            self.commit(&mut out);
        }

        // 5. Bias, from the committed membership.
        self.update_bias(now_ms, &rows, &mut out.trace);

        // 6. Output.
        self.output(now_ms, &mut out);
        out
    }

    /// Window step 3 for one source S with reported entities R.
    fn assign_source(&mut self, source: &str, r: &[String], trace: &mut Vec<Json>) {
        let windowed = self.pack.window > 1;
        let k = self.pack.hypotheses;
        let histories = std::mem::take(&mut self.histories);

        // Candidates `(h, r, history)`, generated in h then r order.
        let mut candidates: Vec<(usize, usize, History)> = Vec::new();
        for (h, history) in histories.iter().enumerate() {
            let rec = history.records.last().expect("step 1 gave every history a record");
            // Gate and cost records, with `h` when windowed.
            let mut records = Vec::new();
            let entries = self.entries(source, r, &rec.membership, &mut records);
            for rec in records {
                trace.push(if windowed { tagged(rec, &[("h", h)]) } else { rec });
            }
            // Per ranked assignment: apply it to a copy, and its choice records.
            let ranked = ranked_assignments(&entries, k);
            for (ri, asg) in ranked.iter().enumerate() {
                let choices: Vec<Choice> =
                    asg.index.iter().map(|&j| if j == entries.columns.len() { Choice::Alone } else { Choice::Column(entries.columns[j]) }).collect();
                let mut next = history.clone();
                let newest = next.records.last_mut().unwrap();
                newest.membership.apply(r, &choices, &mut newest.events);
                newest.cost += asg.total;
                for ((a, c), v) in r.iter().zip(&choices).zip(&asg.values) {
                    let b = match c {
                        Choice::Column(s) => system_name(*s),
                        Choice::Alone => "alone".to_string(),
                    };
                    let choice = record("assign", a, &b, "choice", (*v).into(), Json::Null, true, false);
                    trace.push(if windowed { tagged(choice, &[("h", h), ("r", ri)]) } else { choice });
                    newest.choices.push((a.clone(), b));
                }
                candidates.push((h, ri, next));
            }
        }

        // Candidates ordered by their total (recomputed from the records), then
        // h, then r: a stable sort of the generation order.
        let mut candidates: Vec<(f64, usize, usize, History)> = candidates.into_iter().map(|(h, ri, c)| (c.total(), h, ri, c)).collect();
        candidates.sort_by(|x, y| x.0.partial_cmp(&y.0).unwrap_or(Ordering::Equal));

        // The first `k` are kept; with `margin`, only those with a total at
        // most `cut = best + m`, `best` the first candidate's total.
        let cut = self.pack.margin.map(|m| candidates[0].0 + m);
        let kept = |i: usize, total: f64| i < k && cut.is_none_or(|c| total <= c);
        if windowed {
            for (i, (total, h, ri, _)) in candidates.iter().enumerate() {
                trace.push(obj(vec![
                    ("stage", "history".into()),
                    ("a", Json::Int(*h as i64)),
                    ("b", Json::Int(*ri as i64)),
                    ("test", "total".into()),
                    ("value", (*total).into()),
                    ("limit", cut.map_or(Json::Null, Json::from)),
                    ("pass", kept(i, *total).into()),
                ]));
            }
        }
        self.histories = candidates.into_iter().enumerate().filter(|(i, c)| kept(*i, c.0)).map(|(_, (_, _, _, c))| c).collect();
    }

    /// Window step 4: commit the best history's oldest record.
    fn commit(&mut self, out: &mut StepResult) {
        let committed = self.histories[0].records[0].clone();
        let histories = std::mem::take(&mut self.histories);
        for (rank, mut h) in histories.into_iter().enumerate() {
            let keep = h.records[0].choices == committed.choices;
            if self.pack.window > 1 {
                out.trace.push(obj(vec![
                    ("stage", "history".into()),
                    ("a", Json::Int(rank as i64)),
                    ("b", Json::Null),
                    ("test", "commit".into()),
                    ("value", h.total().into()),
                    ("limit", Json::Null),
                    ("pass", keep.into()),
                ]));
            }
            if keep {
                h.records.remove(0);
                self.histories.push(h);
            }
        }

        // Each entity with a `drop` event in the record is removed.
        for ev in &committed.events {
            if ev.get("ev").and_then(Json::as_str) == Some("drop") {
                let k = ev.get("entity").and_then(Json::as_str).unwrap();
                self.entities.remove(k);
                self.retiring.remove(k);
            }
        }
        out.events.extend(committed.events);
        self.committed = committed.membership;
        for (k, e) in self.entities.iter_mut() {
            e.system = self.committed.system_of(k);
        }
    }

    /// Window step 6: `system` per committed system track (with `margin`, per
    /// system track of the best history's latest membership), then
    /// `provisional` per system track of the best history when the window is
    /// above 1.
    fn output(&self, now_ms: i64, out: &mut StepResult) {
        let reported = match self.pack.margin {
            Some(_) => self.histories[0].latest(&self.committed),
            None => &self.committed,
        };
        for (s, members) in &reported.systems {
            let (fe, fn_) = self.fused(members, now_ms, None);
            let (lat, lon) = self.frame.expect("a system track implies a reference").to_degrees(fe.p, fn_.p);
            let (course, speed) = course_speed(&fe, &fn_);
            let mut pairs = vec![
                ("system", system_name(*s).into()),
                ("members", names(members)),
                ("lat", lat.into()),
                ("lon", lon.into()),
                ("course", course.into()),
                ("speed_ms", speed.into()),
            ];
            // hae from the latest member that has one, ties to key order.
            let mut best: Option<(i64, f64)> = None;
            for m in members {
                let e = &self.entities[m];
                if let Some(h) = e.num("hae") {
                    if best.is_none_or(|(t, _)| e.last_time_ms > t) {
                        best = Some((e.last_time_ms, h));
                    }
                }
            }
            if let Some((_, h)) = best {
                pairs.push(("hae", h.into()));
            }
            out.events.push(event("system", pairs));
        }
        if self.pack.window > 1 {
            for (s, members) in &self.histories[0].latest(&self.committed).systems {
                out.events.push(event("provisional", vec![("system", system_name(*s).into()), ("members", names(members))]));
            }
        }
    }
}
