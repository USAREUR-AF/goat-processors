//! correlate.md Track estimate: one constant-velocity Kalman filter per axis
//! (prediction, position and velocity updates, likelihood terms). Every
//! function here is pure: it takes a state and returns a new one.

/// One axis of the constant-velocity filter.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Axis {
    pub p: f64,
    pub v: f64,
    pub pp: f64,
    pub pv: f64,
    pub vv: f64,
}

impl Axis {
    /// First report, with `pp = ce²`.
    pub fn first(z: f64, vel: Option<f64>, ce: f64, vel_sigma_ms: f64, unknown_vel_ms: f64) -> Axis {
        Axis::first_with_variance(z, vel, ce * ce, vel_sigma_ms, unknown_vel_ms)
    }

    /// First report, with `pp = r`, that axis's measurement variance
    /// (correlate.md 0.8 Track estimate, First report).
    pub fn first_with_variance(z: f64, vel: Option<f64>, r: f64, vel_sigma_ms: f64, unknown_vel_ms: f64) -> Axis {
        Axis {
            p: z,
            v: vel.unwrap_or(0.0),
            pp: r,
            pv: 0.0,
            vv: match vel {
                Some(_) => vel_sigma_ms * vel_sigma_ms,
                None => unknown_vel_ms * unknown_vel_ms,
            },
        }
    }

    /// Step 1, predict by `dt` seconds with process noise `q`.
    pub fn predict(&self, dt: f64, q: f64) -> Axis {
        let Axis { p, v, pp, pv, vv } = *self;
        Axis {
            p: p + v * dt,
            v,
            pp: pp + 2.0 * dt * pv + dt * dt * vv + q * dt.powi(4) / 4.0,
            pv: pv + dt * vv + q * dt.powi(3) / 2.0,
            vv: vv + q * dt * dt,
        }
    }

    /// Step 2, position update with measurement `z` and variance `r`; also
    /// returns the innovation.
    pub fn update_position(&self, z: f64, r: f64) -> (Axis, Innovation) {
        let Axis { p, v, pp, pv, vv } = *self;
        let s = pp + r;
        let k1 = pp / s;
        let k2 = pv / s;
        let y = z - p;
        (Axis { p: p + k1 * y, v: v + k2 * y, pp: (1.0 - k1) * pp, pv: (1.0 - k1) * pv, vv: vv - k2 * pv }, Innovation { y, s })
    }

    /// Step 3, velocity update with measurement `z` and variance `r`; also
    /// returns the innovation.
    pub fn update_velocity(&self, z: f64, r: f64) -> (Axis, Innovation) {
        let Axis { p, v, pp, pv, vv } = *self;
        let s = vv + r;
        let k1 = pv / s;
        let k2 = vv / s;
        let y = z - v;
        (Axis { p: p + k1 * y, v: v + k2 * y, pp: pp - k1 * pv, pv: (1.0 - k2) * pv, vv: (1.0 - k2) * vv }, Innovation { y, s })
    }

    /// `blend(w1, w2)` of two axis states (spec: Two-model filter, step 1).
    pub fn blend(w1: f64, a1: &Axis, w2: f64, a2: &Axis) -> Axis {
        let p = w1 * a1.p + w2 * a2.p;
        let v = w1 * a1.v + w2 * a2.v;
        let (d1, e1, d2, e2) = (a1.p - p, a1.v - v, a2.p - p, a2.v - v);
        Axis {
            p,
            v,
            pp: w1 * (a1.pp + d1 * d1) + w2 * (a2.pp + d2 * d2),
            pv: w1 * (a1.pv + d1 * e1) + w2 * (a2.pv + d2 * e2),
            vv: w1 * (a1.vv + e1 * e1) + w2 * (a2.vv + e2 * e2),
        }
    }

    pub fn as_list(&self) -> [f64; 5] {
        [self.p, self.v, self.pp, self.pv, self.vv]
    }
}

/// Innovation `y` and its variance `s` of one scalar update.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Innovation {
    pub y: f64,
    pub s: f64,
}

impl Innovation {
    /// The likelihood term `y*y/s + ln(s)`.
    pub fn term(&self) -> f64 {
        self.y * self.y / self.s + self.s.ln()
    }
}

/// The measurements of one report, in the plane.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Measurement {
    /// `(east, north)` position, with its measurement variance per axis
    /// `(r_east, r_north)` (correlate.md Track estimate, Measurement variance).
    pub pos: (f64, f64),
    pub r_pos: (f64, f64),
    /// `(ve, vn)` when the report has `course` and `speed_ms`, with variance
    /// `r_vel = vel_sigma_ms²`.
    pub vel: Option<(f64, f64)>,
    pub r_vel: f64,
}

/// Both axes of one constant-velocity filter.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Model {
    pub east: Axis,
    pub north: Axis,
}

impl Model {
    /// Track estimate step 1 on both axes.
    pub fn predict(&self, dt: f64, q: f64) -> Model {
        Model { east: self.east.predict(dt, q), north: self.north.predict(dt, q) }
    }

    /// Track estimate steps 1 to 3 for a later report. Also returns `g`, the
    /// sum from 0 of the likelihood terms in the order east position, north
    /// position, east velocity, north velocity (Two-model filter, step 3).
    pub fn step(&self, dt: f64, q: f64, m: &Measurement) -> (Model, f64) {
        let predicted = self.predict(dt, q);
        let (mut east, ie) = predicted.east.update_position(m.pos.0, m.r_pos.0);
        let (mut north, in_) = predicted.north.update_position(m.pos.1, m.r_pos.1);
        let mut g = 0.0 + ie.term() + in_.term();
        if let Some((ve, vn)) = m.vel {
            let (e, iev) = east.update_velocity(ve, m.r_vel);
            let (n, inv) = north.update_velocity(vn, m.r_vel);
            east = e;
            north = n;
            g = g + iev.term() + inv.term();
        }
        (Model { east, north }, g)
    }

    /// `blend(w1, w2)` of two models, per axis.
    pub fn blend(w1: f64, m1: &Model, w2: f64, m2: &Model) -> Model {
        Model { east: Axis::blend(w1, &m1.east, w2, &m2.east), north: Axis::blend(w1, &m1.north, w2, &m2.north) }
    }
}

/// correlate.md Track estimate: the velocity measurement `(ve, vn) =
/// (s * sin(c), s * cos(c))` from `course` (degrees) and `speed_ms`, when a
/// report has both.
pub fn velocity(course: Option<f64>, speed_ms: Option<f64>) -> Option<(f64, f64)> {
    match (course, speed_ms) {
        (Some(c), Some(s)) => Some((s * super::rad(c).sin(), s * super::rad(c).cos())),
        _ => None,
    }
}

/// correlate.md Track estimate, Measurement variance, for one report.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MeasurementVariance {
    /// `(r_east, r_north)`.
    pub r: (f64, f64),
    /// The timing variance `((v_e*ts)², (v_n*ts)²)`; `None` when the time
    /// error is 0.
    pub time_var: Option<(f64, f64)>,
}

/// With time error `te_ms` 0, `r = ce²` on both axes. Otherwise
/// `ts = te / 1000` and `r = ce² + (v*ts)²` per axis, `v` the velocity
/// `(v_e, v_n)` the caller found (the entity's prediction to the report's
/// time; for a first report the measured velocity, or 0).
pub fn measurement_variance(ce: f64, te_ms: f64, v: impl FnOnce() -> (f64, f64)) -> MeasurementVariance {
    if te_ms == 0.0 {
        return MeasurementVariance { r: (ce * ce, ce * ce), time_var: None };
    }
    let (v_e, v_n) = v();
    let ts = te_ms / 1000.0;
    let (de, dn) = (v_e * ts, v_n * ts);
    let (var_e, var_n) = (de * de, dn * dn);
    MeasurementVariance { r: (ce * ce + var_e, ce * ce + var_n), time_var: Some((var_e, var_n)) }
}

/// `d² = sum over east, north of (z - p)² / (pp + r)`: a position `z` against
/// a prediction, with the measurement variance `r` per axis (the form of
/// correlate.md Restart, Tests and correlate-assign.md Cost).
pub fn d2(z: (f64, f64), (pe, pn): (&Axis, &Axis), r: (f64, f64)) -> f64 {
    (z.0 - pe.p) * (z.0 - pe.p) / (pe.pp + r.0) + (z.1 - pn.p) * (z.1 - pn.p) / (pn.pp + r.1)
}

/// The difference of two tracks' whole state on one axis (correlate.md 1.0
/// Tests, the `state` test): A's filter `a` with A's timing variance `ta`,
/// and B's prediction to A's time `b` (B's timing variance already in `pp`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StateDifference {
    pub dp: f64,
    pub dv: f64,
    pub spp: f64,
    pub spv: f64,
    pub svv: f64,
    pub det: f64,
    pub q: f64,
}

/// `q = (svv*dp*dp - 2*spv*dp*dv + spp*dv*dv) / det`, in that order.
pub fn state_quadratic(dp: f64, dv: f64, spp: f64, spv: f64, svv: f64, det: f64) -> f64 {
    (svv * dp * dp - 2.0 * spv * dp * dv + spp * dv * dv) / det
}

impl StateDifference {
    pub fn of(a: &Axis, ta: f64, b: &Axis) -> StateDifference {
        let dp = a.p - b.p;
        let dv = a.v - b.v;
        let spp = a.pp + ta + b.pp;
        let spv = a.pv + b.pv;
        let svv = a.vv + b.vv;
        let det = spp * svv - spv * spv;
        StateDifference { dp, dv, spp, spv, svv, det, q: state_quadratic(dp, dv, spp, spv, svv, det) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn axis() -> Axis {
        Axis { p: 10.0, v: 2.0, pp: 4.0, pv: 1.0, vv: 9.0 }
    }

    #[test]
    fn first_report_variances() {
        assert_eq!(Axis::first(5.0, Some(1.0), 3.0, 2.0, 50.0), Axis { p: 5.0, v: 1.0, pp: 9.0, pv: 0.0, vv: 4.0 });
        assert_eq!(Axis::first(5.0, None, 3.0, 2.0, 50.0), Axis { p: 5.0, v: 0.0, pp: 9.0, pv: 0.0, vv: 2500.0 });
    }

    #[test]
    fn predict_by_zero_is_the_identity_and_grows_otherwise() {
        assert_eq!(axis().predict(0.0, 1.0), axis());
        let p = axis().predict(2.0, 1.0);
        assert_eq!((p.p, p.v), (14.0, 2.0));
        assert_eq!(p.pp, 4.0 + 2.0 * 2.0 * 1.0 + 4.0 * 9.0 + 16.0 / 4.0);
        assert_eq!(p.pv, 1.0 + 2.0 * 9.0 + 8.0 / 2.0);
        assert_eq!(p.vv, 9.0 + 4.0);
    }

    #[test]
    fn updates_shrink_the_variance_and_report_the_innovation() {
        let (u, i) = axis().update_position(12.0, 4.0);
        assert_eq!((i.y, i.s), (2.0, 8.0));
        assert!(u.pp < axis().pp && u.p == 11.0);
        assert_eq!(i.term(), 4.0 / 8.0 + 8f64.ln());
        let (u, i) = axis().update_velocity(5.0, 9.0);
        assert_eq!((i.y, i.s), (3.0, 18.0));
        assert!(u.vv < axis().vv && u.v == 3.5);
    }

    #[test]
    fn blend_of_equal_states_is_that_state() {
        assert_eq!(Axis::blend(0.25, &axis(), 0.75, &axis()), axis());
        let m = Model { east: axis(), north: axis() };
        assert_eq!(Model::blend(0.5, &m, 0.5, &m), m);
        assert_eq!(axis().as_list(), [10.0, 2.0, 4.0, 1.0, 9.0]);
    }

    #[test]
    fn model_step_sums_the_likelihood_terms_in_order() {
        let m = Model { east: axis(), north: axis() };
        let meas = Measurement { pos: (11.0, 9.0), r_pos: (1.0, 2.0), vel: Some((1.0, 3.0)), r_vel: 4.0 };
        let (next, g) = m.step(0.0, 1.0, &meas);
        let (e, ie) = axis().update_position(11.0, 1.0);
        let (n, in_) = axis().update_position(9.0, 2.0);
        let (e2, iev) = e.update_velocity(1.0, 4.0);
        let (n2, inv) = n.update_velocity(3.0, 4.0);
        assert_eq!(next, Model { east: e2, north: n2 });
        assert_eq!(g, 0.0 + ie.term() + in_.term() + iev.term() + inv.term());
        let without = Measurement { vel: None, ..meas };
        assert_eq!(m.step(0.0, 1.0, &without).0, Model { east: e, north: n });
    }

    #[test]
    fn velocity_needs_course_and_speed() {
        assert_eq!(velocity(Some(90.0), None), None);
        assert_eq!(velocity(None, Some(3.0)), None);
        let (ve, vn) = velocity(Some(90.0), Some(3.0)).unwrap();
        assert!((ve - 3.0).abs() < 1e-12 && vn.abs() < 1e-12);
    }

    #[test]
    fn measurement_variance_adds_the_timing_term() {
        let none = measurement_variance(10.0, 0.0, || panic!("not read when te is 0"));
        assert_eq!(none, MeasurementVariance { r: (100.0, 100.0), time_var: None });
        let v = measurement_variance(10.0, 500.0, || (4.0, -2.0));
        assert_eq!(v, MeasurementVariance { r: (104.0, 101.0), time_var: Some((4.0, 1.0)) });
    }

    #[test]
    fn state_difference_of_independent_axes() {
        let a = Axis { p: 3.0, v: 1.0, pp: 2.0, pv: 0.0, vv: 1.0 };
        let b = Axis { p: 0.0, v: 0.0, pp: 1.0, pv: 0.0, vv: 1.0 };
        let s = StateDifference::of(&a, 1.0, &b);
        assert_eq!((s.spp, s.svv, s.det), (4.0, 2.0, 8.0));
        assert_eq!(s.q, 9.0 / 4.0 + 1.0 / 2.0);
    }

    #[test]
    fn d2_sums_both_axes() {
        let a = Axis { p: 0.0, v: 0.0, pp: 1.0, pv: 0.0, vv: 1.0 };
        assert_eq!(d2((3.0, 4.0), (&a, &a), (1.0, 3.0)), 9.0 / 2.0 + 16.0 / 4.0);
    }
}
