//! correlate.md 1.0 Association (the `confirm` method: gate, confirm, hold,
//! groups; with `sprt` the sequential test of `sprt.rs`), its tick
//! (staleness, the fused output by `output fused|priority|latest`) and its
//! Snapshot. The shared parts (reports, filters, tests, restart, stale time)
//! are in `super`.

use std::collections::BTreeSet;

use super::{course_speed, filter_json, group_name, pair_key, Engine};
use crate::model::json::{obj, Json};
use crate::model::Axis;
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

    /// The candidates of associate, in key order: every other entity,
    /// excluding (unless `same_source allow`) those of A's source and those
    /// in a group that already holds an entity of A's source.
    pub(super) fn candidates(&self, a: &str) -> Vec<String> {
        let a_source = &self.entities[a].source;
        let allow = self.pack.same_source_allow;
        self.entities
            .iter()
            .filter(|(bk, b)| {
                bk.as_str() != a
                    && (allow || &b.source != a_source)
                    && (allow || !b.group.is_some_and(|g| self.group_has_source(g, a_source)))
            })
            .map(|(bk, _)| bk.clone())
            .collect()
    }

    /// Association: A is not in a group, associate.
    pub(super) fn associate(&mut self, a: &str, out: &mut StepResult) {
        let candidates = self.candidates(a);
        let gate = self.pack.gate.clone();
        let confirm = self.pack.confirm.clone();
        let need = self.pack.confirm_count;
        let mut confirmed: Vec<String> = Vec::new();
        for b in &candidates {
            let all_passed = self.run_tests("gate", &gate, a, b, out) && self.run_tests("confirm", &confirm, a, b, out);
            let pk = pair_key(a, b);
            let count = if all_passed { self.counts.get(&pk).copied().unwrap_or(0) + 1 } else { 0 };
            self.counts.insert(pk, count);
            out.trace.push(record("confirm", a, b, "count", Json::Int(count as i64), Json::Int(need as i64), count >= need, false));
            if count >= need {
                confirmed.push(b.clone());
            }
        }

        if let Some(b) = self.group_nearest(a, &confirmed, out) {
            self.counts.insert(pair_key(a, &b), 0);
        }
    }

    /// Of the confirmed candidates, the one with the smallest `d²`, ties to
    /// key order, each with its `rank` record; A joins its group or forms a
    /// new one with it. Returns the chosen candidate.
    pub(super) fn group_nearest(&mut self, a: &str, confirmed: &[String], out: &mut StepResult) -> Option<String> {
        let mut chosen: Option<(String, f64)> = None;
        for b in confirmed {
            let d2 = self.d2(a, b);
            out.trace.push(record("rank", a, b, "rank", d2.into(), Json::Null, true, false));
            if chosen.as_ref().is_none_or(|(_, best)| d2 < *best) {
                chosen = Some((b.clone(), d2));
            }
        }
        let (b, _) = chosen?;

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
        Some(b)
    }

    fn group_has_source(&self, g: u64, source: &str) -> bool {
        self.groups[&g].iter().any(|m| self.entities[m].source == source)
    }

    /// Entity leaves its group; the group is dissolved if one member is left.
    pub(super) fn leave(&mut self, key: &str, reason: &str, out: &mut StepResult) {
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
            self.llr.retain(|(x, y), _| x != k && y != k);
            out.events.push(obj(vec![("ev", "drop".into()), ("entity", k.as_str().into())]));
        }

        // 2. Fused output, groups in creation order.
        for (g, members) in &self.groups {
            let (primary, (pe, pn), hae) = match self.pack.output {
                Output::Fused => (Json::Null, self.fused_output(members, now_ms), self.latest_hae(members)),
                Output::Priority | Output::Latest => {
                    let primary = self.primary(members);
                    let e = &self.entities[primary];
                    (primary.into(), e.predict(now_ms, &self.pack), e.num("hae"))
                }
            };
            let frame = self.frame.expect("a group implies a reference");
            let (lat, lon) = frame.to_degrees(pe.p, pn.p);
            let (course, speed) = course_speed(&pe, &pn);
            let mut pairs = vec![
                ("ev", Json::from("fused")),
                ("group", group_name(*g).into()),
                ("primary", primary),
                ("members", Json::Arr(members.iter().map(|m| m.as_str().into()).collect())),
                ("lat", lat.into()),
                ("lon", lon.into()),
                ("course", course.into()),
                ("speed_ms", speed.into()),
            ];
            if let Some(hae) = hae {
                pairs.push(("hae", hae.into()));
            }
            out.events.push(obj(pairs));
        }
        out
    }

    /// `output fused`: per axis, the information-weighted combination of
    /// every member's filter predicted to `now_ms`, members in key order.
    fn fused_output(&self, members: &BTreeSet<String>, now_ms: i64) -> (Axis, Axis) {
        let predicted: Vec<(Axis, Axis)> = members.iter().map(|m| self.entities[m].predict(now_ms, &self.pack)).collect();
        let east: Vec<Axis> = predicted.iter().map(|p| p.0).collect();
        let north: Vec<Axis> = predicted.iter().map(|p| p.1).collect();
        (information_weighted(&east), information_weighted(&north))
    }

    /// The `hae` of the member with the greatest `last_time_ms` whose last
    /// report has `hae`, ties to key order.
    fn latest_hae(&self, members: &BTreeSet<String>) -> Option<f64> {
        let mut best: Option<(i64, f64)> = None;
        for m in members {
            let e = &self.entities[m];
            if let Some(h) = e.num("hae") {
                if best.is_none_or(|(t, _)| e.last_time_ms > t) {
                    best = Some((e.last_time_ms, h));
                }
            }
        }
        best.map(|(_, h)| h)
    }

    /// The primary member by the pack's `output` line, ties to key order.
    fn primary<'a>(&self, members: &'a BTreeSet<String>) -> &'a str {
        let mut best: Option<&'a String> = None;
        for m in members {
            let better = match best {
                None => true,
                Some(b) => match self.pack.output {
                    Output::Fused => false,
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
                    ("hold_failures", Json::Int(e.hold_failures as i64)),
                ];
                pairs.extend(filter_json(e));
                (k.into(), obj(pairs))
            })
            .collect();
        let groups = self
            .groups
            .iter()
            .map(|(g, ms)| (group_name(*g).into(), Json::Arr(ms.iter().map(|m| m.as_str().into()).collect())))
            .collect();
        let counts = self.counts.iter().map(|((x, y), n)| (format!("{}|{}", x, y).into(), Json::Int(*n as i64))).collect();
        let mut pairs = vec![
            ("ref", reference),
            ("entities", Json::Obj(entities)),
            ("groups", Json::Obj(groups)),
            ("counts", Json::Obj(counts)),
            ("next_group", Json::Int(self.next_group as i64)),
        ];
        if self.pack.sprt.is_some() {
            pairs.push(("llr", Json::Obj(self.llr.iter().map(|((x, y), l)| (format!("{}|{}", x, y).into(), (*l).into())).collect())));
        }
        pairs.extend(self.intervals_json());
        obj(pairs)
    }
}

/// `p = (sum of p_i/pp_i) / (sum of 1/pp_i)` and
/// `v = (sum of v_i/vv_i) / (sum of 1/vv_i)`, each sum left to right from 0.
/// The covariance of the result is not reported.
pub(crate) fn information_weighted(axes: &[Axis]) -> Axis {
    let (mut sp, mut wp, mut sv, mut wv) = (0.0, 0.0, 0.0, 0.0);
    for a in axes {
        sp += a.p / a.pp;
        wp += 1.0 / a.pp;
        sv += a.v / a.vv;
        wv += 1.0 / a.vv;
    }
    Axis { p: sp / wp, v: sv / wv, pp: 1.0 / wp, pv: 0.0, vv: 1.0 / wv }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn information_weighting_favors_the_smaller_variance() {
        let a = Axis { p: 0.0, v: 1.0, pp: 1.0, pv: 0.0, vv: 1.0 };
        let b = Axis { p: 3.0, v: 4.0, pp: 2.0, pv: 0.0, vv: 2.0 };
        let f = information_weighted(&[a, b]);
        assert_eq!((f.p, f.v), ((0.0 + 1.5) / 1.5, (1.0 + 2.0) / 1.5));
        assert_eq!(information_weighted(&[b]).p, 3.0);
    }
}
