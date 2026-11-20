//! correlate-assign.md Sensor bias: the state of a pair of sources, moving
//! B into A's frame, the update after each commit, and the time offset fit.

use std::collections::BTreeSet;

use crate::correlate::pack::Bias;
use crate::correlate::Engine;
use crate::model::{obj, Axis, Json};

/// The stored state of one pair of sources `"<S>|<T>"`: per axis the offset
/// `o` of T's positions from S's and the weight sum `w`; `var` for both axes;
/// `n`, the count of accepted pairs. With `time_offset`, also `tau`, how far
/// T's clock is ahead of S's in seconds, and the sums `S1` to `S8` (Time
/// offset); both stay 0 without it.
#[derive(Debug, Clone, PartialEq)]
pub struct PairBias {
    pub(crate) east: f64,
    pub(crate) weight_east: f64,
    pub(crate) north: f64,
    pub(crate) weight_north: f64,
    pub(crate) var: f64,
    pub(crate) pairs: u64,
    pub(crate) tau: f64,
    pub(crate) sums: [f64; 8],
}

impl PairBias {
    /// The snapshot entry; `time_offset_ms` and `sums` only with `time_offset`.
    pub(crate) fn json(&self, time_offset: bool) -> Json {
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

impl PairBias {
    /// A pair with no stored state: `o = 0`, `w = 0`, `var = s²`, `n = 0`.
    pub(crate) fn initial(sigma_m: f64) -> PairBias {
        PairBias {
            east: 0.0,
            weight_east: 0.0,
            north: 0.0,
            weight_north: 0.0,
            var: sigma_m * sigma_m,
            pairs: 0,
            tau: 0.0,
            sums: [0.0; 8],
        }
    }
}

/// Moving B into A's frame with the pair's `state`: B's prediction
/// `(east, north)` becomes `p + o` when B's source is first in key order
/// (`b_first`), else `p - o`, with `pp + var` on each axis. With `timed`
/// (`time_offset`), `o - v*tau` takes the place of `o`, `v` B's predicted
/// velocity on that axis. Pure.
pub(crate) fn move_into_frame(state: &PairBias, b_first: bool, timed: bool, (east, north): (Axis, Axis)) -> (Axis, Axis) {
    let moved = |axis: Axis, o: f64| {
        let o = state.offset(o, axis.v, timed);
        Axis { p: if b_first { axis.p + o } else { axis.p - o }, pp: axis.pp + state.var, ..axis }
    };
    (moved(east, state.east), moved(north, state.north))
}

impl Engine {
    /// A pair's state; with none stored, `PairBias::initial`.
    pub(crate) fn pair_bias(&self, key: &str) -> PairBias {
        let s = self.pack.bias.as_ref().expect("bias state needs the bias directive").sigma_m;
        self.bias.get(key).cloned().unwrap_or_else(|| PairBias::initial(s))
    }

    /// `move_into_frame` with the stored state of A's and B's sources. Two
    /// entities of one source, or a pack without `bias`, move nothing.
    pub(crate) fn move_into_frame(&self, a_src: &str, b_src: &str, prediction: (Axis, Axis)) -> (Axis, Axis) {
        if self.pack.bias.is_none() || a_src == b_src {
            return prediction;
        }
        let b_first = b_src < a_src;
        let state = if b_first { self.pair_bias(&bias_key(b_src, a_src)) } else { self.pair_bias(&bias_key(a_src, b_src)) };
        move_into_frame(&state, b_first, self.pack.time_offset.is_some(), prediction)
    }

    /// Sensor bias, Update: after the commit, for each committed system track
    /// in creation order, each pair of its members that are not retiring
    /// (key order, `X` before `Y`) from two sources, at least one among the
    /// tick's `rows`.
    pub(crate) fn update_bias(&mut self, now_ms: i64, rows: &BTreeSet<String>, trace: &mut Vec<Json>) {
        let Some(params) = self.pack.bias.clone() else { return };
        let time_offset = self.pack.time_offset;
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

            // 2 and 3.
            let (st, d2, accepted) = update_pair(self.pair_bias(&key), &params, time_offset, (y_e, y_n), (r_e, r_n), (v_e, v_n));
            if accepted {
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

/// Sensor bias, Update, steps 2 and 3 for one pair with offset `y`, its
/// variance `r` and velocity `v` per axis `(east, north)`: `d²` against the
/// pair's state `st` (with `time_offset`, `o - v*tau` in place of `o`); when
/// `d²` is below the gate, the count, the variance, then the offset. Returns
/// the state after step 3, `d²` and whether the pair was accepted. Pure.
pub(crate) fn update_pair(
    mut st: PairBias,
    params: &Bias,
    time_offset: Option<f64>,
    (y_e, y_n): (f64, f64),
    (r_e, r_n): (f64, f64),
    (v_e, v_n): (f64, f64),
) -> (PairBias, f64, bool) {
    let (s2, f2) = (params.sigma_m * params.sigma_m, params.floor_m * params.floor_m);
    let timed = time_offset.is_some();
    let (o_e, o_n) = (st.offset(st.east, v_e, timed), st.offset(st.north, v_n, timed));
    let d2 = (y_e - o_e) * (y_e - o_e) / (st.var + r_e) + (y_n - o_n) * (y_n - o_n) / (st.var + r_n);

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
    }
    (st, d2, accepted)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn axis(p: f64, v: f64) -> Axis {
        Axis { p, v, pp: 4.0, pv: 0.0, vv: 1.0 }
    }

    #[test]
    fn moving_adds_or_subtracts_the_offset_by_source_order() {
        let st = PairBias { east: 10.0, north: -2.0, var: 3.0, tau: 0.5, ..PairBias::initial(1.0) };
        let (e, n) = move_into_frame(&st, true, false, (axis(1.0, 4.0), axis(1.0, 0.0)));
        assert_eq!((e.p, e.pp, n.p, n.pp), (11.0, 7.0, -1.0, 7.0));
        let (e, _) = move_into_frame(&st, false, false, (axis(1.0, 4.0), axis(1.0, 0.0)));
        assert_eq!(e.p, -9.0);
        // With time_offset: o - v*tau = 10 - 4*0.5.
        let (e, _) = move_into_frame(&st, true, true, (axis(1.0, 4.0), axis(1.0, 0.0)));
        assert_eq!(e.p, 9.0);
    }

    #[test]
    fn update_accepts_below_the_gate_and_floors_the_variance() {
        let params = Bias { sigma_m: 10.0, floor_m: 8.0, gate: 9.0 };
        let st = PairBias::initial(10.0);
        let (next, d2, ok) = update_pair(st.clone(), &params, None, (5.0, 0.0), (100.0, 100.0), (0.0, 0.0));
        assert!(ok && d2 == 25.0 / 200.0);
        assert_eq!((next.pairs, next.var), (1, 64.0));
        assert_eq!((next.weight_east, next.east), (0.01, 5.0));
        let (same, _, ok) = update_pair(st.clone(), &params, None, (500.0, 0.0), (1.0, 1.0), (0.0, 0.0));
        assert!(!ok && same == st);
    }

    #[test]
    fn time_offset_fit_moves_tau_and_sets_the_weights() {
        let params = Bias { sigma_m: 10.0, floor_m: 1.0, gate: 1e9 };
        let (next, _, ok) = update_pair(PairBias::initial(10.0), &params, Some(100.0), (-2.0, -1.0), (1.0, 1.0), (20.0, 10.0));
        assert!(ok && next.tau > 0.0, "{:?}", next);
        assert_eq!((next.weight_east, next.weight_north), (next.sums[0], next.sums[1]));
        let json = next.json(true);
        assert!(json.get("time_offset_ms").is_some() && json.get("sums").is_some());
        assert!(next.json(false).get("sums").is_none());
    }
}
