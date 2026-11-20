//! Combining a group's members' kinematics (spec/fuse.md, Kinematics).

use crate::model::Axis;
use crate::model::{obj, Json};

use super::pack::Kinematics;
use super::Member;

/// Per axis `p`, `v`, `pp`, `vv` of the combined estimate.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AxisEstimate {
    pub p: f64,
    pub v: f64,
    pub pp: f64,
    pub vv: f64,
}

impl From<Axis> for AxisEstimate {
    fn from(a: Axis) -> AxisEstimate {
        AxisEstimate { p: a.p, v: a.v, pp: a.pp, vv: a.vv }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Estimate {
    pub east: AxisEstimate,
    pub north: AxisEstimate,
}

/// What a kinematics method gives: the estimate, the index of the member it
/// came from (`from`), and the `intersect` trace records.
pub struct Combined {
    pub estimate: Estimate,
    pub from: Option<usize>,
    pub trace: Vec<Json>,
}

/// Combines `members` (key order, already predicted to `now_ms`) by `method`.
pub fn combine(method: Kinematics, group: &Json, members: &[Member], unlisted_rank: usize) -> Combined {
    let own = |i: usize| Estimate { east: members[i].east.into(), north: members[i].north.into() };
    let pick = |i: usize| Combined { estimate: own(i), from: Some(i), trace: Vec::new() };
    match method {
        Kinematics::InverseVariance => Combined { estimate: inverse_variance(members), from: None, trace: Vec::new() },
        Kinematics::CovarianceIntersection => covariance_intersection(group, members),
        // `best`: smallest `var`, ties to key order.
        Kinematics::Best => pick(first_min_by(members, |a, b| a.var() < b.var())),
        // `priority`: smallest rank, ties to key order.
        Kinematics::Priority => {
            let rank = |m: &Member| m.rank.unwrap_or(unlisted_rank);
            pick(first_min_by(members, |a, b| rank(a) < rank(b)))
        }
        // `latest`: greatest `last_time_ms`, ties to key order.
        Kinematics::Latest => pick(first_min_by(members, |a, b| a.last_time_ms > b.last_time_ms)),
    }
}

/// Index of the first member that no later member `better`s: a later member
/// replaces the current choice only when strictly better, so ties go to key order.
fn first_min_by(members: &[Member], better: impl Fn(&Member, &Member) -> bool) -> usize {
    let mut chosen = 0;
    for i in 1..members.len() {
        if better(&members[i], &members[chosen]) {
            chosen = i;
        }
    }
    chosen
}

/// `inverse_variance`, per axis, members in key order.
fn inverse_variance(members: &[Member]) -> Estimate {
    fn axis(axes: impl Iterator<Item = Axis>) -> AxisEstimate {
        let (mut ip, mut sp, mut iv, mut sv) = (0.0, 0.0, 0.0, 0.0);
        for a in axes {
            ip += 1.0 / a.pp;
            sp += a.p / a.pp;
            iv += 1.0 / a.vv;
            sv += a.v / a.vv;
        }
        let pp = 1.0 / ip;
        let vv = 1.0 / iv;
        AxisEstimate { p: pp * sp, v: vv * sv, pp, vv }
    }
    Estimate { east: axis(members.iter().map(|m| m.east)), north: axis(members.iter().map(|m| m.north)) }
}

/// `covariance_intersection`: fold members in key order into `X`.
fn covariance_intersection(group: &Json, members: &[Member]) -> Combined {
    let mut x = Estimate { east: members[0].east.into(), north: members[0].north.into() };
    let mut trace = Vec::new();
    for m in &members[1..] {
        let y = Estimate { east: m.east.into(), north: m.north.into() };
        let w = weight(&x, &y);
        trace.push(obj(vec![
            ("stage", "intersect".into()),
            ("group", group.clone()),
            ("member", m.key.as_str().into()),
            ("value", w.into()),
        ]));
        x = fold(&x, &y, w);
    }
    Combined { estimate: x, from: None, trace }
}

/// Weight: the closed-form `w` in [0, 1] that `X` carries, steps 1 to 5.
fn weight(x: &Estimate, y: &Estimate) -> f64 {
    let ae = 1.0 / y.east.pp;
    let an = 1.0 / y.north.pp;
    let de = 1.0 / x.east.pp - ae;
    let dn = 1.0 / x.north.pp - an;
    let c2 = de * dn;
    let c1 = ae * dn + an * de;
    if c2 < 0.0 {
        (-c1 / (2.0 * c2)).clamp(0.0, 1.0)
    } else if c1 + c2 > 0.0 {
        1.0
    } else if c1 + c2 < 0.0 {
        0.0
    } else {
        0.5
    }
}

/// Fold: `X` unchanged at `w = 1`, `Y` at `w = 0`, otherwise per axis.
fn fold(x: &Estimate, y: &Estimate, w: f64) -> Estimate {
    if w == 1.0 {
        return *x;
    }
    if w == 0.0 {
        return *y;
    }
    fn axis(x: &AxisEstimate, y: &AxisEstimate, w: f64) -> AxisEstimate {
        let a = w / x.pp;
        let b = (1.0 - w) / y.pp;
        let pp = 1.0 / (a + b);
        let p = pp * (a * x.p + b * y.p);
        let c = w / x.vv;
        let d = (1.0 - w) / y.vv;
        let vv = 1.0 / (c + d);
        let v = vv * (c * x.v + d * y.v);
        AxisEstimate { p, v, pp, vv }
    }
    Estimate { east: axis(&x.east, &y.east, w), north: axis(&x.north, &y.north, w) }
}
