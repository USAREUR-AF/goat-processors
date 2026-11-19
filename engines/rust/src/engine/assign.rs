//! `method assign` (spec/correlate-assign.md 0.2): system tracks, a per-source
//! exact least-cost assignment at each tick, inverse-variance fused estimate.

use std::collections::{BTreeMap, BTreeSet};

use super::{axis_json, course_speed, record, Engine, StepResult};
use crate::filter::Axis;
use crate::json::{obj, Json};

fn system_name(n: u64) -> String {
    format!("s{}", n)
}

/// What one entity of R may choose.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Choice {
    Column(u64),
    Alone,
}

impl Engine {
    /// Fused estimate of `members` at time `t`, per axis (spec: Fused estimate).
    /// `pv` of the result is not defined by the spec and is left 0.
    fn fused<'a>(&self, members: impl IntoIterator<Item = &'a String>, t: i64) -> (Axis, Axis) {
        let q = self.pack.filter.accel_var;
        // Per axis: sum 1/pp, sum p/pp, sum 1/vv, sum v/vv.
        let mut sums = [[0.0f64; 4]; 2];
        for m in members {
            let (pe, pn) = self.entities[m].predict(t, q);
            for (s, a) in sums.iter_mut().zip([pe, pn]) {
                s[0] += 1.0 / a.pp;
                s[1] += a.p / a.pp;
                s[2] += 1.0 / a.vv;
                s[3] += a.v / a.vv;
            }
        }
        let axis = |s: [f64; 4]| {
            let pp = 1.0 / s[0];
            let vv = 1.0 / s[2];
            Axis { p: pp * s[1], v: vv * s[3], pp, pv: 0.0, vv }
        };
        (axis(sums[0]), axis(sums[1]))
    }

    /// Cost `d²` of entity A against the set `others`, predicted to A's time.
    fn assign_cost(&self, a: &str, others: &[String]) -> f64 {
        let ea = &self.entities[a];
        let (fe, fn_) = self.fused(others, ea.last_time_ms);
        (ea.east.p - fe.p).powi(2) / (ea.east.pp + fe.pp) + (ea.north.p - fn_.p).powi(2) / (ea.north.pp + fn_.pp)
    }

    /// A leaves its system track (event `leave`); an emptied track ends.
    fn leave_system(&mut self, a: &str, reason: &str, out: &mut StepResult) {
        let Some(s) = self.entities.get_mut(a).and_then(|e| e.system.take()) else { return };
        let members = self.systems.get_mut(&s).expect("member of a known system track");
        members.remove(a);
        out.events.push(obj(vec![
            ("ev", "leave".into()),
            ("system", system_name(s).into()),
            ("entity", a.into()),
            ("reason", reason.into()),
        ]));
        if members.is_empty() {
            self.systems.remove(&s);
            out.events.push(obj(vec![("ev", "end".into()), ("system", system_name(s).into())]));
        }
    }

    pub(super) fn tick_assign(&mut self, now_ms: i64) -> StepResult {
        let mut out = StepResult::default();

        // Staleness, entities in key order.
        for k in self.stale_entities(now_ms) {
            self.leave_system(&k, "stale", &mut out);
            self.entities.remove(&k);
            self.reported.remove(&k);
            out.events.push(obj(vec![("ev", "drop".into()), ("entity", k.as_str().into())]));
        }

        // Reported entities grouped by source; sources and entities in key order.
        let mut by_source: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for k in std::mem::take(&mut self.reported) {
            if let Some(e) = self.entities.get(&k) {
                by_source.entry(e.source.clone()).or_default().push(k);
            }
        }
        for (source, r) in &by_source {
            self.assign_source(source, r, &mut out);
        }

        // Output, system tracks in creation order.
        let frame = self.frame;
        for (s, members) in &self.systems {
            let (fe, fn_) = self.fused(members, now_ms);
            let (lat, lon) = frame.expect("a system track implies a reference").to_degrees(fe.p, fn_.p);
            let (course, speed) = course_speed(&fe, &fn_);
            let mut pairs = vec![
                ("ev", Json::from("system")),
                ("system", system_name(*s).into()),
                ("members", Json::Arr(members.iter().map(|m| m.as_str().into()).collect())),
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
            out.events.push(obj(pairs));
        }
        out
    }

    /// Steps 1 to 4 of "On each tick" for one source S with reported entities R.
    fn assign_source(&mut self, source: &str, r: &[String], out: &mut StepResult) {
        let in_r: BTreeSet<&str> = r.iter().map(String::as_str).collect();

        // 1. Columns, in creation order, with their others.
        let columns: Vec<(u64, Vec<String>)> = self
            .systems
            .iter()
            .filter_map(|(s, members)| {
                let others: Vec<String> = members.iter().filter(|m| !in_r.contains(m.as_str())).cloned().collect();
                let ok = !others.is_empty() && others.iter().all(|m| self.entities[m].source != source);
                ok.then_some((*s, others))
            })
            .collect();

        // 2. Entries: per entity, one per column (None when forbidden), then alone.
        let gate = self.pack.gate.clone();
        let keep = self.pack.keep_bonus;
        let mut entries: Vec<Vec<Option<f64>>> = Vec::with_capacity(r.len());
        let mut alone: Vec<f64> = Vec::with_capacity(r.len());
        for a in r {
            let current = self.entities[a].system;
            let mut row = Vec::with_capacity(columns.len());
            for (s, others) in &columns {
                // The first failing test ends the entry: no test against later others.
                let passed = others.iter().all(|b| self.run_tests("gate", &gate, a, b, out));
                row.push(passed.then(|| {
                    let d2 = self.assign_cost(a, others);
                    if current == Some(*s) {
                        d2 - keep
                    } else {
                        d2
                    }
                }));
            }
            entries.push(row);
            let only = current.is_some_and(|s| self.systems[&s].len() == 1);
            alone.push(if only { self.pack.new_cost - keep } else { self.pack.new_cost });
        }
        for (i, a) in r.iter().enumerate() {
            for (j, (s, _)) in columns.iter().enumerate() {
                let c = entries[i][j];
                out.trace.push(record("assign", a, &system_name(*s), "cost", c.map_or(Json::Null, Json::from), Json::Null, c.is_some(), false));
            }
            out.trace.push(record("assign", a, "alone", "cost", alone[i].into(), Json::Null, true, false));
        }

        // 3. Assignment: columns 0..m are the system tracks, m+i is row i's alone.
        let m = columns.len();
        let n = r.len();
        let cost: Vec<Vec<f64>> = (0..n)
            .map(|i| {
                let mut row: Vec<f64> = entries[i].iter().map(|c| c.unwrap_or(f64::INFINITY)).collect();
                row.extend((0..n).map(|k| if k == i { alone[i] } else { f64::INFINITY }));
                row
            })
            .collect();
        let pick = min_cost_assignment(&cost);
        let choices: Vec<(Choice, f64)> = (0..n)
            .map(|i| {
                let j = pick[i];
                if j < m {
                    (Choice::Column(columns[j].0), cost[i][j])
                } else {
                    (Choice::Alone, alone[i])
                }
            })
            .collect();
        for (a, (c, v)) in r.iter().zip(&choices) {
            let b = match c {
                Choice::Column(s) => system_name(*s),
                Choice::Alone => "alone".to_string(),
            };
            out.trace.push(record("assign", a, &b, "choice", (*v).into(), Json::Null, true, false));
        }

        // 4. Apply, entities of R in key order.
        for (a, (c, _)) in r.iter().zip(&choices) {
            let current = self.entities[a].system;
            let unchanged = match c {
                Choice::Column(s) => current == Some(*s),
                Choice::Alone => current.is_some_and(|s| self.systems[&s].len() == 1),
            };
            if unchanged {
                continue;
            }
            self.leave_system(a, "assign", out);
            let s = match c {
                Choice::Column(s) => *s,
                Choice::Alone => {
                    let s = self.next_system;
                    self.next_system += 1;
                    s
                }
            };
            self.systems.entry(s).or_default().insert(a.clone());
            self.entities.get_mut(a).unwrap().system = Some(s);
            let ev = if matches!(c, Choice::Alone) { "start" } else { "join" };
            out.events.push(obj(vec![("ev", ev.into()), ("system", system_name(s).into()), ("entity", a.as_str().into())]));
        }
    }

    pub(super) fn snapshot_assign(&self) -> Json {
        let entities = self
            .entities
            .iter()
            .map(|(k, e)| {
                let v = obj(vec![
                    ("last_time_ms", e.last_time_ms.into()),
                    ("system", e.system.map_or(Json::Null, |s| system_name(s).into())),
                    ("filter", obj(vec![("east", axis_json(&e.east)), ("north", axis_json(&e.north))])),
                ]);
                (k.clone(), v)
            })
            .collect();
        let systems = self
            .systems
            .iter()
            .map(|(s, ms)| (system_name(*s), Json::Arr(ms.iter().map(|m| m.as_str().into()).collect())))
            .collect();
        obj(vec![
            ("ref", self.reference_json()),
            ("entities", Json::Obj(entities)),
            ("systems", Json::Obj(systems)),
            ("next_system", (self.next_system as f64).into()),
            ("reported", Json::Arr(self.reported.iter().map(|k| k.as_str().into()).collect())),
        ])
    }
}

/// Exact minimum-cost assignment of every row to a distinct column (rows <=
/// columns), by the Hungarian method with potentials. Forbidden entries are
/// `f64::INFINITY`; every row must have some assignment of finite total cost.
/// Returns the column of each row.
pub(crate) fn min_cost_assignment(cost: &[Vec<f64>]) -> Vec<usize> {
    let n = cost.len();
    if n == 0 {
        return Vec::new();
    }
    let m = cost[0].len();
    assert!(n <= m, "more rows than columns");
    const INF: f64 = f64::INFINITY;
    // 1-indexed; column 0 and row 0 are sentinels.
    let mut u = vec![0.0f64; n + 1];
    let mut v = vec![0.0f64; m + 1];
    let mut p = vec![0usize; m + 1]; // row matched to column j
    let mut way = vec![0usize; m + 1];
    for i in 1..=n {
        p[0] = i;
        let mut j0 = 0usize;
        let mut minv = vec![INF; m + 1];
        let mut used = vec![false; m + 1];
        loop {
            used[j0] = true;
            let i0 = p[j0];
            let mut delta = INF;
            let mut j1 = 0usize;
            for j in 1..=m {
                if !used[j] {
                    let c = cost[i0 - 1][j - 1];
                    if c.is_finite() {
                        let cur = c - u[i0] - v[j];
                        if cur < minv[j] {
                            minv[j] = cur;
                            way[j] = j0;
                        }
                    }
                    if minv[j] < delta {
                        delta = minv[j];
                        j1 = j;
                    }
                }
            }
            assert!(j1 != 0, "no feasible assignment");
            for j in 0..=m {
                if used[j] {
                    u[p[j]] += delta;
                    v[j] -= delta;
                } else if minv[j].is_finite() {
                    minv[j] -= delta;
                }
            }
            j0 = j1;
            if p[j0] == 0 {
                break;
            }
        }
        loop {
            let j1 = way[j0];
            p[j0] = p[j1];
            j0 = j1;
            if j0 == 0 {
                break;
            }
        }
    }
    let mut row_col = vec![0usize; n];
    for j in 1..=m {
        if p[j] != 0 {
            row_col[p[j] - 1] = j - 1;
        }
    }
    row_col
}

#[cfg(test)]
mod tests {
    use super::min_cost_assignment;

    /// Brute force over every injective choice, for comparison.
    fn brute(cost: &[Vec<f64>]) -> f64 {
        fn go(cost: &[Vec<f64>], i: usize, used: &mut Vec<bool>) -> f64 {
            if i == cost.len() {
                return 0.0;
            }
            let mut best = f64::INFINITY;
            for j in 0..cost[i].len() {
                if !used[j] && cost[i][j].is_finite() {
                    used[j] = true;
                    best = best.min(cost[i][j] + go(cost, i + 1, used));
                    used[j] = false;
                }
            }
            best
        }
        go(cost, 0, &mut vec![false; cost[0].len()])
    }

    #[test]
    fn matches_brute_force() {
        // Deterministic pseudo-random matrices, some entries forbidden, some negative.
        let mut x: u64 = 12345;
        let mut next = || {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (x >> 33) as f64 / (1u64 << 31) as f64
        };
        for n in 1..=5 {
            for extra in 0..=3 {
                for _ in 0..20 {
                    let m = n + extra;
                    let mut cost: Vec<Vec<f64>> = (0..n)
                        .map(|_| (0..m).map(|_| if next() < 0.3 { f64::INFINITY } else { next() * 20.0 - 5.0 }).collect())
                        .collect();
                    // Guarantee feasibility: each row its own finite column (the "alone" shape).
                    for (i, row) in cost.iter_mut().enumerate() {
                        row.extend((0..n).map(|k| if k == i { 9.21 } else { f64::INFINITY }));
                    }
                    let pick = min_cost_assignment(&cost);
                    let mut seen = std::collections::BTreeSet::new();
                    assert!(pick.iter().all(|j| seen.insert(*j)));
                    let total: f64 = pick.iter().enumerate().map(|(i, j)| cost[i][*j]).sum();
                    assert!((total - brute(&cost)).abs() < 1e-9, "{:?}", cost);
                }
            }
        }
    }
}
