//! correlate.md Association (the `confirm` method: gate, confirm, hold,
//! groups), its tick (staleness, fused output by `output priority|latest`)
//! and its Snapshot. Moved here unchanged from the engine; the shared parts
//! (reports, filters, tests, restart) are in `super`.

use std::collections::BTreeSet;

use super::{course_speed, filter_json, group_name, pair_key, Engine};
use crate::model::json::{obj, Json};
use crate::correlate::pack::Output;
use crate::trace::{record, StepResult};

impl Engine {
    /// Association: A is in a group G, hold.
    pub(super) fn hold(&mut self, a: &str, out: &mut StepResult) {
        let g = self.entities[a].group.expect("hold needs a group");
        let others: Vec<String> = self.groups[&g].iter().filter(|m| m.as_str() != a).cloned().collect();
        let tests = self.pack.hold.clone();
        let mut held = false;
        for b in &others {
            if self.run_tests("hold", &tests, a, b, out) {
                held = true;
                break;
            }
        }
        let limit = self.pack.hold_failures;
        let e = self.entities.get_mut(a).unwrap();
        if held {
            e.hold_failures = 0;
        } else {
            e.hold_failures += 1;
            if e.hold_failures >= limit {
                self.leave(a, "hold", out);
            }
        }
    }

    /// Association: A is not in a group, associate.
    pub(super) fn associate(&mut self, a: &str, out: &mut StepResult) {
        let a_source = self.entities[a].source.clone();
        let allow = self.pack.same_source_allow;
        let candidates: Vec<String> = self
            .entities
            .iter()
            .filter(|(bk, b)| {
                bk.as_str() != a
                    && (allow || b.source != a_source)
                    && (allow || !b.group.is_some_and(|g| self.group_has_source(g, &a_source)))
            })
            .map(|(bk, _)| bk.clone())
            .collect();

        let gate = self.pack.gate.clone();
        let confirm = self.pack.confirm.clone();
        let need = self.pack.confirm_count;
        let mut confirmed: Vec<String> = Vec::new();
        for b in &candidates {
            let all_passed = self.run_tests("gate", &gate, a, b, out) && self.run_tests("confirm", &confirm, a, b, out);
            let pk = pair_key(a, b);
            let count = if all_passed { self.counts.get(&pk).copied().unwrap_or(0) + 1 } else { 0 };
            self.counts.insert(pk, count);
            out.trace.push(record("confirm", a, b, "count", (count as f64).into(), (need as f64).into(), count >= need, false));
            if count >= need {
                confirmed.push(b.clone());
            }
        }

        // Rank by d², ties to key order.
        let mut chosen: Option<(String, f64)> = None;
        for b in &confirmed {
            let d2 = self.d2(a, b);
            out.trace.push(record("rank", a, b, "rank", d2.into(), Json::Null, true, false));
            if chosen.as_ref().is_none_or(|(_, best)| d2 < *best) {
                chosen = Some((b.clone(), d2));
            }
        }
        let Some((b, _)) = chosen else { return };

        match self.entities[&b].group {
            Some(g) => {
                self.groups.get_mut(&g).unwrap().insert(a.to_string());
                self.entities.get_mut(a).unwrap().group = Some(g);
                out.events.push(obj(vec![("ev", "join".into()), ("group", group_name(g).into()), ("entity", a.into())]));
            }
            None => {
                let g = self.next_group;
                self.next_group += 1;
                let members: BTreeSet<String> = [a.to_string(), b.clone()].into_iter().collect();
                let list = Json::Arr(members.iter().map(|m| m.as_str().into()).collect());
                self.groups.insert(g, members);
                self.entities.get_mut(a).unwrap().group = Some(g);
                self.entities.get_mut(&b).unwrap().group = Some(g);
                out.events.push(obj(vec![("ev", "correlate".into()), ("group", group_name(g).into()), ("members", list)]));
            }
        }
        self.counts.insert(pair_key(a, &b), 0);
    }

    fn group_has_source(&self, g: u64, source: &str) -> bool {
        self.groups[&g].iter().any(|m| self.entities[m].source == source)
    }

    /// Entity leaves its group; the group is dissolved if one member is left.
    fn leave(&mut self, key: &str, reason: &str, out: &mut StepResult) {
        let e = self.entities.get_mut(key).unwrap();
        let Some(g) = e.group.take() else { return };
        e.hold_failures = 0;
        let members = self.groups.get_mut(&g).unwrap();
        members.remove(key);
        out.events.push(obj(vec![
            ("ev", "leave".into()),
            ("group", group_name(g).into()),
            ("entity", key.into()),
            ("reason", reason.into()),
        ]));
        if members.len() == 1 {
            let last = members.iter().next().unwrap().clone();
            self.groups.remove(&g);
            let rest = self.entities.get_mut(&last).unwrap();
            rest.group = None;
            rest.hold_failures = 0;
            out.events.push(obj(vec![("ev", "dissolve".into()), ("group", group_name(g).into()), ("entity", last.as_str().into())]));
        }
    }

    // ---- tick (spec: Association "On each tick")

    pub(crate) fn tick_confirm(&mut self, now_ms: i64) -> StepResult {
        let mut out = StepResult::default();

        // 1. Staleness, entities in key order.
        let stale = self.stale_entities(now_ms);
        for k in &stale {
            self.leave(k, "stale", &mut out);
            self.entities.remove(k);
            self.counts.retain(|(x, y), _| x != k && y != k);
            out.events.push(obj(vec![("ev", "drop".into()), ("entity", k.as_str().into())]));
        }

        // 2. Fused output, groups in creation order.
        for (g, members) in &self.groups {
            let primary = self.primary(members);
            let e = &self.entities[primary];
            let (pe, pn) = e.predict(now_ms, &self.pack);
            let frame = self.frame.expect("a group implies a reference");
            let (lat, lon) = frame.to_degrees(pe.p, pn.p);
            let (course, speed) = course_speed(&pe, &pn);
            let mut pairs = vec![
                ("ev", Json::from("fused")),
                ("group", group_name(*g).into()),
                ("primary", primary.into()),
                ("members", Json::Arr(members.iter().map(|m| m.as_str().into()).collect())),
                ("lat", lat.into()),
                ("lon", lon.into()),
                ("course", course.into()),
                ("speed_ms", speed.into()),
            ];
            if let Some(hae) = e.num("hae") {
                pairs.push(("hae", hae.into()));
            }
            out.events.push(obj(pairs));
        }
        out
    }

    /// The primary member by the pack's `output` line, ties to key order.
    fn primary<'a>(&self, members: &'a BTreeSet<String>) -> &'a str {
        let mut best: Option<&'a String> = None;
        for m in members {
            let better = match best {
                None => true,
                Some(b) => match self.pack.output {
                    Output::Priority => self.pack.priority_of(&self.entities[m].source) < self.pack.priority_of(&self.entities[b].source),
                    Output::Latest => self.entities[m].last_time_ms > self.entities[b].last_time_ms,
                },
            };
            if better {
                best = Some(m);
            }
        }
        best.expect("a group has members")
    }

    // ---- snapshot (spec: Snapshot)

    pub(crate) fn snapshot_confirm(&self) -> Json {
        let reference = match self.frame {
            Some(f) => Json::Arr(vec![f.lat0.into(), f.lon0.into()]),
            None => Json::Null,
        };
        let entities = self
            .entities
            .iter()
            .map(|(k, e)| {
                let mut pairs = vec![
                    ("last_time_ms", e.last_time_ms.into()),
                    ("group", e.group.map_or(Json::Null, |g| group_name(g).into())),
                    ("hold_failures", (e.hold_failures as f64).into()),
                ];
                pairs.extend(filter_json(e));
                (k.clone(), obj(pairs))
            })
            .collect();
        let groups = self
            .groups
            .iter()
            .map(|(g, ms)| (group_name(*g), Json::Arr(ms.iter().map(|m| m.as_str().into()).collect())))
            .collect();
        let counts = self.counts.iter().map(|((x, y), n)| (format!("{}|{}", x, y), Json::Num(*n as f64))).collect();
        obj(vec![
            ("ref", reference),
            ("entities", Json::Obj(entities)),
            ("groups", Json::Obj(groups)),
            ("counts", Json::Obj(counts)),
            ("next_group", (self.next_group as f64).into()),
        ])
    }
}
