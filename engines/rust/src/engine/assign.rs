//! `method assign` (spec/correlate-assign.md 0.6): system tracks, ranked
//! per-source assignments at each tick, a window of histories (with an
//! optional margin), sensor bias with an optional clock offset, and the
//! inverse-variance fused estimate.
//!
//! The sections of the spec map onto this file as follows:
//! Memberships -> `Membership`, `Record`, `History`;
//! Assignment of one source -> `Engine::entries`, `Membership::apply`;
//! Sensor bias -> `PairBias`, `Engine::move_into_frame`, `Engine::update_bias`;
//! Ranking -> `ranked_assignments`; Window -> `Engine::tick_assign` and its
//! steps; Snapshot -> `Engine::snapshot_assign`.

use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

use super::{course_speed, filter_json, record, Engine, StepResult};
use crate::filter::Axis;
use crate::json::{obj, Json};

fn system_name(n: u64) -> String {
    format!("s{}", n)
}

fn names(members: &BTreeSet<String>) -> Json {
    Json::Arr(members.iter().map(|m| m.as_str().into()).collect())
}

fn event(ev: &str, pairs: Vec<(&str, Json)>) -> Json {
    let mut all = vec![("ev", Json::from(ev))];
    all.extend(pairs);
    obj(all)
}

/// Adds keys (`h`, `r`) to a trace record.
fn tagged(mut rec: Json, tags: &[(&str, usize)]) -> Json {
    if let Json::Obj(m) = &mut rec {
        for (k, v) in tags {
            m.insert(k.to_string(), Json::Int(*v as i64));
        }
    }
    rec
}

// ---- Memberships

/// One picture of the system tracks: members by system number (creation
/// order is number order) and the counter that names the next one.
#[derive(Debug, Clone, PartialEq)]
pub struct Membership {
    systems: BTreeMap<u64, BTreeSet<String>>,
    next_system: u64,
}

impl Default for Membership {
    fn default() -> Membership {
        Membership { systems: BTreeMap::new(), next_system: 1 }
    }
}

impl Membership {
    fn system_of(&self, a: &str) -> Option<u64> {
        self.systems.iter().find(|(_, ms)| ms.contains(a)).map(|(s, _)| *s)
    }

    /// A is now the only member of its system track.
    fn alone(&self, a: &str) -> bool {
        self.system_of(a).is_some_and(|s| self.systems[&s].len() == 1)
    }

    /// A leaves its system track if it has one (event `leave`); a track left
    /// empty ends (event `end`).
    fn leave(&mut self, a: &str, reason: &str, events: &mut Vec<Json>) {
        let Some(s) = self.system_of(a) else { return };
        let members = self.systems.get_mut(&s).unwrap();
        members.remove(a);
        events.push(event("leave", vec![("system", system_name(s).into()), ("entity", a.into()), ("reason", reason.into())]));
        if members.is_empty() {
            self.systems.remove(&s);
            events.push(event("end", vec![("system", system_name(s).into())]));
        }
    }

    /// Assignment of one source, step 4: apply one assignment, entities of R
    /// in key order.
    fn apply(&mut self, r: &[String], choices: &[Choice], events: &mut Vec<Json>) {
        for (a, c) in r.iter().zip(choices) {
            let unchanged = match c {
                Choice::Column(s) => self.system_of(a) == Some(*s),
                Choice::Alone => self.alone(a),
            };
            if unchanged {
                continue;
            }
            self.leave(a, "assign", events);
            let (ev, s) = match c {
                Choice::Column(s) => ("join", *s),
                Choice::Alone => {
                    self.next_system += 1;
                    ("start", self.next_system - 1)
                }
            };
            self.systems.entry(s).or_default().insert(a.clone());
            events.push(event(ev, vec![("system", system_name(s).into()), ("entity", a.as_str().into())]));
        }
    }

    fn systems_json(&self) -> Json {
        Json::Obj(self.systems.iter().map(|(s, ms)| (system_name(*s), names(ms))).collect())
    }
}

/// One pending tick of a history.
#[derive(Debug, Clone, PartialEq)]
pub struct Record {
    /// Sum from 0 of the assignment totals of the tick's sources, in key order.
    cost: f64,
    /// `[entity, chosen]`, sources in key order, entities in key order.
    choices: Vec<(String, String)>,
    /// The membership events the tick produced in this history.
    events: Vec<Json>,
    /// The membership after the tick.
    membership: Membership,
}

/// Pending ticks, oldest first.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct History {
    records: Vec<Record>,
}

impl History {
    /// Sum from 0 of the records' `cost`, oldest first.
    fn total(&self) -> f64 {
        self.records.iter().fold(0.0, |sum, r| sum + r.cost)
    }

    /// The newest record's membership, or the committed one when it has none.
    fn latest<'a>(&'a self, committed: &'a Membership) -> &'a Membership {
        self.records.last().map_or(committed, |r| &r.membership)
    }
}

// ---- Sensor bias

/// The stored state of one pair of sources `"<S>|<T>"`: per axis the offset
/// `o` of T's positions from S's and the weight sum `w`; `var` for both axes;
/// `n`, the count of accepted pairs. With `time_offset`, also `tau`, how far
/// T's clock is ahead of S's in seconds, and the sums `S1` to `S8` (Time
/// offset); both stay 0 without it.
#[derive(Debug, Clone, PartialEq)]
pub struct PairBias {
    east: f64,
    weight_east: f64,
    north: f64,
    weight_north: f64,
    var: f64,
    pairs: u64,
    tau: f64,
    sums: [f64; 8],
}

impl PairBias {
    /// The snapshot entry; `time_offset_ms` and `sums` only with `time_offset`.
    fn json(&self, time_offset: bool) -> Json {
        let mut pairs = vec![
            ("east", self.east.into()),
            ("weight_east", self.weight_east.into()),
            ("north", self.north.into()),
            ("weight_north", self.weight_north.into()),
            ("var", self.var.into()),
            ("pairs", Json::Int(self.pairs as i64)),
        ];
        if time_offset {
            pairs.push(("time_offset_ms", (self.tau * 1000.0).into()));
            pairs.push(("sums", Json::Arr(self.sums.iter().map(|x| Json::Num(*x)).collect())));
        }
        obj(pairs)
    }

    /// The offset B is moved by on one axis: `o`, or with `time_offset`
    /// `o - v*tau`, `v` the velocity on that axis (Time offset). Without
    /// `time_offset`, `tau` is not part of the formula.
    fn offset(&self, o: f64, v: f64, time_offset: bool) -> f64 {
        if time_offset {
            o - v * self.tau
        } else {
            o
        }
    }
}

fn bias_key(first: &str, second: &str) -> String {
    format!("{}|{}", first, second)
}

impl Engine {
    /// A pair's state; with none stored, `o = 0`, `w = 0`, `var = s²`, `n = 0`.
    fn pair_bias(&self, key: &str) -> PairBias {
        let s = self.pack.bias.as_ref().expect("bias state needs the bias directive").sigma_m;
        self.bias.get(key).cloned().unwrap_or(PairBias {
            east: 0.0,
            weight_east: 0.0,
            north: 0.0,
            weight_north: 0.0,
            var: s * s,
            pairs: 0,
            tau: 0.0,
            sums: [0.0; 8],
        })
    }

    /// Moving B into A's frame: B's prediction `(east, north)` becomes `p + o`
    /// (pair `"<b_src>|<a_src>"`, when `b_src` is first) or `p - o` (pair
    /// `"<a_src>|<b_src>"`, when `a_src` is first), with `pp + var` on each
    /// axis. With `time_offset`, `o - v*tau` takes the place of `o`, with `v`
    /// B's predicted velocity on that axis. Two entities of one source, or a
    /// pack without `bias`, move nothing.
    pub(super) fn move_into_frame(&self, a_src: &str, b_src: &str, (east, north): (Axis, Axis)) -> (Axis, Axis) {
        if self.pack.bias.is_none() || a_src == b_src {
            return (east, north);
        }
        let timed = self.pack.time_offset.is_some();
        let b_first = b_src < a_src;
        let state = if b_first { self.pair_bias(&bias_key(b_src, a_src)) } else { self.pair_bias(&bias_key(a_src, b_src)) };
        let moved = |axis: Axis, o: f64| {
            let o = state.offset(o, axis.v, timed);
            Axis { p: if b_first { axis.p + o } else { axis.p - o }, pp: axis.pp + state.var, ..axis }
        };
        (moved(east, state.east), moved(north, state.north))
    }

    /// Sensor bias, Update: after the commit, for each committed system track
    /// in creation order, each pair of its members that are not retiring
    /// (key order, `X` before `Y`) from two sources, at least one among the
    /// tick's `rows`.
    fn update_bias(&mut self, now_ms: i64, rows: &BTreeSet<String>, trace: &mut Vec<Json>) {
        let Some(params) = self.pack.bias.clone() else { return };
        let time_offset = self.pack.time_offset;
        let (s2, f2) = (params.sigma_m * params.sigma_m, params.floor_m * params.floor_m);
        let mut pairs: Vec<(String, String)> = Vec::new();
        for members in self.committed.systems.values() {
            let live: Vec<&String> = members.iter().filter(|m| !self.retiring.contains(*m)).collect();
            for (i, x) in live.iter().enumerate() {
                for y in &live[i + 1..] {
                    let different = self.entities[*x].source != self.entities[*y].source;
                    if different && (rows.contains(*x) || rows.contains(*y)) {
                        pairs.push(((*x).clone(), (*y).clone()));
                    }
                }
            }
        }
        for (x, y) in pairs {
            // 1. ES is the entity whose source is first in key order, ET the other.
            let (es, et) = if self.entities[&x].source < self.entities[&y].source { (&x, &y) } else { (&y, &x) };
            let key = bias_key(&self.entities[es].source, &self.entities[et].source);
            let (s_e, s_n) = self.entities[es].predict(now_ms, &self.pack);
            let (t_e, t_n) = self.entities[et].predict(now_ms, &self.pack);
            let (y_e, r_e) = (t_e.p - s_e.p, s_e.pp + t_e.pp);
            let (y_n, r_n) = (t_n.p - s_n.p, s_n.pp + t_n.pp);

            // Time offset: per axis `v = (v_ES + v_ET) / 2`.
            let (v_e, v_n) = ((s_e.v + t_e.v) / 2.0, (s_n.v + t_n.v) / 2.0);

            // 2. d² against the pair's state; with `time_offset`, `o - v*tau`
            // takes the place of `o`.
            let mut st = self.pair_bias(&key);
            let timed = time_offset.is_some();
            let (o_e, o_n) = (st.offset(st.east, v_e, timed), st.offset(st.north, v_n, timed));
            let d2 = (y_e - o_e) * (y_e - o_e) / (st.var + r_e) + (y_n - o_n) * (y_n - o_n) / (st.var + r_n);

            // 3. Accepted below the gate: count, variance, then the offset.
            let accepted = d2 < params.gate;
            if accepted {
                st.pairs += 1;
                st.var = s2 / (st.pairs + 1) as f64;
                if st.var < f2 {
                    st.var = f2;
                }
                match time_offset {
                    // Without `time_offset`: the weighted running mean per axis.
                    None => {
                        st.weight_east += 1.0 / r_e;
                        st.east += ((1.0 / r_e) / st.weight_east) * (y_e - st.east);
                        st.weight_north += 1.0 / r_n;
                        st.north += ((1.0 / r_n) / st.weight_north) * (y_n - st.north);
                    }
                    // Time offset: the weighted least-squares fit of
                    // `y = o - v*tau` with priors.
                    Some(t) => fit_time_offset(&mut st, params.sigma_m, t, (v_e, v_n), (y_e, y_n), (r_e, r_n)),
                }
                self.bias.insert(key, st.clone());
            }

            // 4. Trace, with the state after step 3; `time_offset_ms` with
            // `time_offset`.
            let mut rec = vec![
                ("stage", "bias".into()),
                ("a", x.as_str().into()),
                ("b", y.as_str().into()),
                ("test", "offset".into()),
                ("value", d2.into()),
                ("limit", params.gate.into()),
                ("pass", accepted.into()),
                ("east", st.east.into()),
                ("north", st.north.into()),
                ("var", st.var.into()),
                ("pairs", Json::Int(st.pairs as i64)),
            ];
            if time_offset.is_some() {
                rec.push(("time_offset_ms", (st.tau * 1000.0).into()));
            }
            trace.push(obj(rec));
        }
    }
}

/// Sensor bias, Time offset, for an accepted pair: add this pair to the sums
/// `S1` to `S8` (each `+=` one addition of the whole right-hand side), then
/// solve for `tau` and `o` in closed form. `s` is `bias sigma_m`, `t` is
/// `time_offset sigma_ms`; `v`, `y`, `r` are this pair's `(east, north)`.
fn fit_time_offset(st: &mut PairBias, s: f64, t: f64, (ve, vn): (f64, f64), (ye, yn): (f64, f64), (r_e, r_n): (f64, f64)) {
    let (we, wn) = (1.0 / r_e, 1.0 / r_n);
    let sum = &mut st.sums;
    sum[0] += we;
    sum[1] += wn;
    sum[2] += we * ve;
    sum[3] += wn * vn;
    sum[4] += we * ve * ve + wn * vn * vn;
    sum[5] += we * ye;
    sum[6] += wn * yn;
    sum[7] += we * ve * ye + wn * vn * yn;
    let [s1, s2, s3, s4, s5, s6, s7, s8] = *sum;

    // Priors: `po = 1/s²`, `pt = 1/(t/1000)²`.
    let po = 1.0 / (s * s);
    let t_s = t / 1000.0;
    let pt = 1.0 / (t_s * t_s);

    let a11 = po + s1;
    let a22 = po + s2;
    let a13 = -s3;
    let a23 = -s4;
    let a33 = pt + s5;
    let b1 = s6;
    let b2 = s7;
    let b3 = -s8;
    let tau = (b3 - a13 * b1 / a11 - a23 * b2 / a22) / (a33 - a13 * a13 / a11 - a23 * a23 / a22);
    st.tau = tau;
    st.east = (b1 - a13 * tau) / a11;
    st.north = (b2 - a23 * tau) / a22;
    // The weight sum `w` of each axis is `S1` and `S2`.
    st.weight_east = s1;
    st.weight_north = s2;
}

// ---- Assignment of one source

/// What one entity of R chooses.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Choice {
    Column(u64),
    Alone,
}

/// Steps 1 and 2 for one source against one membership.
struct Entries {
    /// Column system numbers, in creation order.
    columns: Vec<u64>,
    /// Per entity of R, per column: the entry, or None when forbidden.
    rows: Vec<Vec<Option<f64>>>,
    /// Per entity of R: its *alone* entry.
    alone: Vec<f64>,
}

/// One assignment: per entity of R, its choice index (a column's position, or
/// the number of columns for *alone*) and the entry it chose.
#[derive(Debug, Clone)]
struct Assignment {
    index: Vec<usize>,
    values: Vec<f64>,
    total: f64,
}

/// Ranking: the first `k` assignments, by total, then by choice vector. Brute
/// force over every assignment, which is exact and fine at vector sizes.
fn ranked_assignments(e: &Entries, k: usize) -> Vec<Assignment> {
    fn extend(e: &Entries, i: usize, used: &mut Vec<bool>, index: &mut Vec<usize>, all: &mut Vec<Vec<usize>>) {
        if i == e.rows.len() {
            all.push(index.clone());
            return;
        }
        let m = e.columns.len();
        for j in 0..=m {
            let allowed = j == m || (!used[j] && e.rows[i][j].is_some());
            if !allowed {
                continue;
            }
            if j < m {
                used[j] = true;
            }
            index.push(j);
            extend(e, i + 1, used, index, all);
            index.pop();
            if j < m {
                used[j] = false;
            }
        }
    }
    let mut all = Vec::new();
    extend(e, 0, &mut vec![false; e.columns.len()], &mut Vec::new(), &mut all);

    let m = e.columns.len();
    let mut ranked: Vec<Assignment> = all
        .into_iter()
        .map(|index| {
            let values: Vec<f64> = index.iter().enumerate().map(|(i, &j)| if j == m { e.alone[i] } else { e.rows[i][j].unwrap() }).collect();
            // The total: chosen entries in ascending order, added from 0.
            let mut sorted = values.clone();
            sorted.sort_by(|x, y| x.partial_cmp(y).unwrap());
            let total = sorted.iter().fold(0.0, |sum, v| sum + v);
            Assignment { index, values, total }
        })
        .collect();
    ranked.sort_by(|x, y| x.total.partial_cmp(&y.total).unwrap().then_with(|| x.index.cmp(&y.index)));
    ranked.truncate(k);
    ranked
}

impl Engine {
    /// Fused estimate of `members` at time `t`, per axis (spec: Fused estimate).
    /// With `seen_by`, A's source (Cost), each member's prediction gets its
    /// timing variance added to `pp` and is then moved into A's frame (with
    /// `bias`); for output (`None`) neither applies. `pv` of the result is not
    /// defined by the spec and is left 0.
    fn fused<'a>(&self, members: impl IntoIterator<Item = &'a String>, t: i64, seen_by: Option<&str>) -> (Axis, Axis) {
        // Per axis: sum 1/pp, sum p/pp, sum 1/vv, sum v/vv.
        let mut sums = [[0.0f64; 4]; 2];
        for m in members {
            let e = &self.entities[m];
            let (pe, pn) = match seen_by {
                Some(a_src) => self.move_into_frame(a_src, &e.source, e.predict_for_comparison(t, &self.pack)),
                None => e.predict(t, &self.pack),
            };
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

    /// Cost `d²` of entity A against the set `others`, predicted to A's time;
    /// `pp_a` is A's filter `pp` plus A's timing variance.
    fn assign_cost(&self, a: &str, others: &[String]) -> f64 {
        let ea = &self.entities[a];
        let (fe, fn_) = self.fused(others, ea.last_time_ms, Some(&ea.source));
        let (var_e, var_n) = ea.timing_variance();
        let (pp_ae, pp_an) = (ea.east.pp + var_e, ea.north.pp + var_n);
        (ea.east.p - fe.p).powi(2) / (pp_ae + fe.pp) + (ea.north.p - fn_.p).powi(2) / (pp_an + fn_.pp)
    }

    /// Assignment of one source, steps 1 and 2, against `membership`; gate and
    /// cost records go to `trace`.
    fn entries(&self, source: &str, r: &[String], membership: &Membership, trace: &mut Vec<Json>) -> Entries {
        let in_r: BTreeSet<&str> = r.iter().map(String::as_str).collect();

        // 1. Columns, in creation order, with their others.
        let columns: Vec<(u64, Vec<String>)> = membership
            .systems
            .iter()
            .filter_map(|(s, members)| {
                let others: Vec<String> = members.iter().filter(|m| !in_r.contains(m.as_str())).cloned().collect();
                let ok = !others.is_empty() && others.iter().all(|m| self.entities[m].source != source);
                ok.then_some((*s, others))
            })
            .collect();

        // 2. Entries: per entity, one per column (None when forbidden), then alone.
        let keep = self.pack.keep_bonus;
        let mut gate_out = StepResult::default();
        let mut rows = Vec::with_capacity(r.len());
        let mut alone = Vec::with_capacity(r.len());
        for a in r {
            let current = membership.system_of(a);
            let mut row = Vec::with_capacity(columns.len());
            for (s, others) in &columns {
                // The first failing test ends the entry: no test against later others.
                let passed = others.iter().all(|b| self.run_tests("gate", &self.pack.gate, a, b, &mut gate_out));
                row.push(passed.then(|| {
                    let d2 = self.assign_cost(a, others);
                    if current == Some(*s) {
                        d2 - keep
                    } else {
                        d2
                    }
                }));
            }
            rows.push(row);
            alone.push(if membership.alone(a) { self.pack.new_cost - keep } else { self.pack.new_cost });
        }
        trace.append(&mut gate_out.trace);
        for (i, a) in r.iter().enumerate() {
            for (j, (s, _)) in columns.iter().enumerate() {
                let c = rows[i][j];
                trace.push(record("assign", a, &system_name(*s), "cost", c.map_or(Json::Null, Json::from), Json::Null, c.is_some(), false));
            }
            trace.push(record("assign", a, "alone", "cost", alone[i].into(), Json::Null, true, false));
        }
        Entries { columns: columns.into_iter().map(|(s, _)| s).collect(), rows, alone }
    }

    // ---- Window: on each tick

    pub(super) fn tick_assign(&mut self, now_ms: i64) -> StepResult {
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

    // ---- Snapshot

    pub(super) fn snapshot_assign(&self) -> Json {
        let entities = self
            .entities
            .iter()
            .map(|(k, e)| {
                let mut pairs = vec![("last_time_ms", e.last_time_ms.into()), ("system", e.system.map_or(Json::Null, |s| system_name(s).into()))];
                pairs.extend(filter_json(e));
                (k.clone(), obj(pairs))
            })
            .collect();
        let mut pairs = vec![
            ("ref", self.reference_json()),
            ("entities", Json::Obj(entities)),
            ("systems", self.committed.systems_json()),
            ("next_system", Json::Int(self.committed.next_system as i64)),
            ("reported", Json::Arr(self.reported.iter().map(|k| k.as_str().into()).collect())),
        ];
        if self.pack.restart.is_some() {
            pairs.push(("restarted", Json::Arr(self.restarted.iter().map(|k| k.as_str().into()).collect())));
        }
        if self.pack.bias.is_some() {
            pairs.push(("bias", Json::Obj(self.bias.iter().map(|(k, b)| (k.clone(), b.json(self.pack.time_offset.is_some()))).collect())));
        }
        if self.pack.window > 1 {
            let histories = self
                .histories
                .iter()
                .map(|h| {
                    let records = h
                        .records
                        .iter()
                        .map(|r| {
                            obj(vec![
                                ("cost", r.cost.into()),
                                ("choices", Json::Arr(r.choices.iter().map(|(a, c)| Json::Arr(vec![a.as_str().into(), c.as_str().into()])).collect())),
                                ("events", Json::Arr(r.events.clone())),
                                ("systems", r.membership.systems_json()),
                                ("next_system", Json::Int(r.membership.next_system as i64)),
                            ])
                        })
                        .collect();
                    obj(vec![("total", h.total().into()), ("records", Json::Arr(records))])
                })
                .collect();
            pairs.push(("retiring", Json::Arr(self.retiring.iter().map(|k| k.as_str().into()).collect())));
            pairs.push(("histories", Json::Arr(histories)));
        }
        obj(pairs)
    }
}

#[cfg(test)]
mod tests {
    use super::{ranked_assignments, Entries};

    #[test]
    fn ranking_breaks_equal_totals_by_choice_vector() {
        // Both full matchings total 3.0 bit for bit; the smaller choice vector
        // [0, 1] comes first. Then [0, 2] and [2, 0] tie at 10.0.
        let e = Entries { columns: vec![1, 2], rows: vec![vec![Some(1.0), Some(2.0)], vec![Some(1.0), Some(2.0)]], alone: vec![9.0, 9.0] };
        let r = ranked_assignments(&e, 3);
        assert_eq!(r[0].index, vec![0, 1]);
        assert_eq!(r[1].index, vec![1, 0]);
        assert_eq!(r[0].total, r[1].total);
        assert_eq!(r[2].index, vec![0, 2]);
    }
}
