//! correlate-assign.md Assignment of one source (steps 1 and 2: columns,
//! entries) with its Cost, and the fused estimate (Window step 6) the cost
//! and the output share.

use std::collections::BTreeSet;

use super::membership::Membership;
use super::ranking::Entries;
use super::system_name;
use crate::correlate::Engine;
use crate::model::{Axis, Json};
use crate::trace::{record, StepResult};

impl Engine {
    /// Fused estimate of `members` at time `t`, per axis (spec: Fused estimate).
    /// With `seen_by`, A's source (Cost), each member's prediction gets its
    /// timing variance added to `pp` and is then moved into A's frame (with
    /// `bias`); for output (`None`) neither applies. `pv` of the result is not
    /// defined by the spec and is left 0.
    pub(crate) fn fused<'a>(&self, members: impl IntoIterator<Item = &'a String>, t: i64, seen_by: Option<&str>) -> (Axis, Axis) {
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
    pub(crate) fn assign_cost(&self, a: &str, others: &[String]) -> f64 {
        let ea = &self.entities[a];
        let (fe, fn_) = self.fused(others, ea.last_time_ms, Some(&ea.source));
        let (var_e, var_n) = ea.timing_variance();
        let (pp_ae, pp_an) = (ea.east.pp + var_e, ea.north.pp + var_n);
        (ea.east.p - fe.p).powi(2) / (pp_ae + fe.pp) + (ea.north.p - fn_.p).powi(2) / (pp_an + fn_.pp)
    }

    /// Assignment of one source, steps 1 and 2, against `membership`; gate and
    /// cost records go to `trace`.
    pub(crate) fn entries(&self, source: &str, r: &[String], membership: &Membership, trace: &mut Vec<Json>) -> Entries {
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
}
