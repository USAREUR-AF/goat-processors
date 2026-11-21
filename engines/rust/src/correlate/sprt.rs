//! correlate.md 1.0 Association, Sequential test: with the `sprt` directive,
//! Wald's sequential probability ratio test on each pair replaces the
//! counts, `confirm_count`, the `hold` tests and `hold_failures`. The
//! evidence of one report is a pure function of the two tracks' state
//! difference (`evidence`); the pair updates, the hold by the link pair and
//! the association are the engine's.

use super::pack::Sprt;
use super::pair_tests::{state, Test};
use super::{pair_key, Engine};
use crate::model::{state_quadratic, Json, StateDifference};
use crate::trace::{record, StepResult};

/// One report's evidence for A against B: the increment of `L` and the
/// record's `d2`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Evidence {
    pub(crate) increment: f64,
    pub(crate) d2: f64,
}

/// The increment and `d2` from the per-axis state differences (east, north)
/// and, when both last reports have it, the two `hae` values.
pub(crate) fn evidence(t: &Sprt, axes: (StateDifference, StateDifference), hae: Option<(f64, f64)>) -> Evidence {
    let big_p = t.pos_m * t.pos_m;
    let big_v = t.vel_ms * t.vel_ms;
    let term = |s: &StateDifference| {
        let tpp = s.spp + big_p;
        let tvv = s.svv + big_v;
        let det0 = tpp * tvv - s.spv * s.spv;
        let q0 = state_quadratic(s.dp, s.dv, tpp, s.spv, tvv, det0);
        0.5 * (q0 - s.q) + 0.5 * (det0 / s.det).ln()
    };
    let (e, n) = axes;
    let mut increment = 0.0 + term(&e) + term(&n);
    let mut d2 = e.q + n.q;
    if let Some((ha, hb)) = hae {
        let h1 = 2.0 * t.hae_sigma_m * t.hae_sigma_m;
        let h0 = h1 + big_p;
        let dh = ha - hb;
        increment += 0.5 * (dh * dh / h0 - dh * dh / h1) + 0.5 * (h0 / h1).ln();
        d2 += dh * dh / h1;
    }
    Evidence { increment, d2 }
}

impl Engine {
    fn sprt(&self) -> &Sprt {
        self.pack.sprt.as_ref().expect("the pack has sprt")
    }

    /// The `same` tests of the `gate` line, in pack order.
    fn same_tests(&self) -> Vec<Test> {
        self.pack.gate.iter().filter(|t| t.name() == "same").cloned().collect()
    }

    /// Update of a pair: `L = min(max(L + increment, lo), up)` from A's
    /// evidence against B (a pair with no `L` starts from 0), or `L = lo`
    /// when forced. Stores `L`, writes the `sprt` record and returns `L`.
    fn sprt_update(&mut self, a: &str, b: &str, forced: bool, out: &mut StepResult) -> f64 {
        let (up, lo) = (self.sprt().up(), self.sprt().lo());
        let key = pair_key(a, b);
        let (l, increment, d2) = if forced {
            (lo, Json::Null, Json::Null)
        } else {
            let (ea, eb) = (&self.entities[a], &self.entities[b]);
            let hae = ea.num("hae").zip(eb.num("hae"));
            let ev = evidence(self.sprt(), state(ea, self.predict_seen_by(a, b)), hae);
            let before = self.llr.get(&key).copied().unwrap_or(0.0);
            ((before + ev.increment).max(lo).min(up), ev.increment.into(), ev.d2.into())
        };
        self.llr.insert(key, l);
        let mut rec = record("sprt", a, b, "llr", l.into(), up.into(), l >= up, false);
        if let Json::Obj(m) = &mut rec {
            m.insert("lower".into(), lo.into());
            m.insert("increment".into(), increment);
            m.insert("d2".into(), d2);
        }
        out.trace.push(rec);
        l
    }

    /// A is in a group: only the link pair (the other member with the
    /// greatest `L`, ties to key order) is updated, after the `same` tests
    /// of the `gate` line; at `lo` or below A leaves (reason `release`).
    pub(super) fn sprt_hold(&mut self, a: &str, out: &mut StepResult) {
        let g = self.entities[a].group.expect("hold needs a group");
        let mut link: Option<(&String, f64)> = None;
        for m in self.groups[&g].iter().filter(|m| m.as_str() != a) {
            let l = self.llr.get(&pair_key(a, m)).copied().unwrap_or(0.0);
            if link.is_none_or(|(_, best)| l > best) {
                link = Some((m, l));
            }
        }
        let link = link.expect("a group has another member").0.clone();
        let same = self.same_tests();
        let forced = !self.run_tests("gate", &same, a, &link, out);
        let lo = self.sprt().lo();
        if self.sprt_update(a, &link, forced, out) <= lo {
            self.leave(a, "release", out);
            self.llr.retain(|(x, y), l| !((x == a || y == a) && *l <= lo));
        }
    }

    /// A is not in a group: every candidate's pair is updated after its
    /// `gate` and `confirm` tests; the ready pair (`L` at `up`) with the
    /// smallest position `d²` is chosen as in associate, and keeps its `L`.
    pub(super) fn sprt_associate(&mut self, a: &str, out: &mut StepResult) {
        let gate = self.pack.gate.clone();
        let confirm = self.pack.confirm.clone();
        let same = self.same_tests();
        let (up, lo) = (self.sprt().up(), self.sprt().lo());
        let mut ready: Vec<String> = Vec::new();
        for b in &self.candidates(a) {
            let all_passed = self.run_tests("gate", &gate, a, b, out) && self.run_tests("confirm", &confirm, a, b, out);
            let l = if all_passed {
                self.sprt_update(a, b, false, out)
            } else if self.llr.contains_key(&pair_key(a, b)) {
                let forced = !self.run_tests_traced("gate", &same, a, b, None);
                self.sprt_update(a, b, forced, out)
            } else {
                continue;
            };
            if l <= lo {
                self.llr.remove(&pair_key(a, b));
            } else if l >= up {
                ready.push(b.clone());
            }
        }
        self.group_nearest(a, &ready, out);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Axis;

    fn sprt() -> Sprt {
        Sprt { false_p: 0.01, missed: 0.01, pos_m: 100.0, vel_ms: 10.0, hae_sigma_m: 10.0 }
    }

    fn axis(p: f64) -> Axis {
        Axis { p, v: 0.0, pp: 50.0, pv: 0.0, vv: 2.0 }
    }

    #[test]
    fn close_tracks_add_evidence_and_far_ones_take_it_away() {
        let near = StateDifference::of(&axis(1.0), 0.0, &axis(0.0));
        let far = StateDifference::of(&axis(300.0), 0.0, &axis(0.0));
        let e = evidence(&sprt(), (near, near), None);
        assert!(e.increment > 0.0);
        assert_eq!(e.d2, near.q + near.q);
        assert!(evidence(&sprt(), (far, near), None).increment < 0.0);
        let h = evidence(&sprt(), (near, near), Some((100.0, 110.0)));
        assert_eq!(h.d2, e.d2 + 100.0 / 200.0);
        assert!(h.increment > e.increment);
    }
}
