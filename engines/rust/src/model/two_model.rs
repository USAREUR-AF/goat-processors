//! correlate.md Two-model filter: the quiet and maneuver models, mixing,
//! likelihood and mode probabilities. Pure functions of the state.

use super::track::{Measurement, Model};

/// The two models of Two-model filter: index 0 is `quiet` (model 1), index 1
/// is `maneuver` (model 2), with mode probabilities `mu`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TwoModel {
    pub models: [Model; 2],
    pub mu: [f64; 2],
}

/// What one later report gives for the trace: `lambda` and the new `mu`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ModeUpdate {
    pub lambda: [f64; 2],
    pub mu: [f64; 2],
}

/// Switching over `dt` seconds: `t[i][j]`, the probability of model `j` at
/// the end of `dt` given model `i` at its start.
fn switching(a: f64, b: f64, dt: f64) -> [[f64; 2]; 2] {
    let s = a + b;
    let l = (1.0 - s).powf(dt);
    let t12 = a / s * (1.0 - l);
    let t21 = b / s * (1.0 - l);
    [[1.0 - t12, t12], [t21, 1.0 - t21]]
}

impl TwoModel {
    /// First report: both models the first-report filter, `mu1 = b / s`,
    /// `mu2 = a / s`.
    pub fn first(filter: Model, a: f64, b: f64) -> TwoModel {
        let s = a + b;
        TwoModel { models: [filter, filter], mu: [b / s, a / s] }
    }

    /// The entity's filter: `blend(mu1, mu2)` of the two models (step 5).
    pub fn combined(&self) -> Model {
        Model::blend(self.mu[0], &self.models[0], self.mu[1], &self.models[1])
    }

    /// Prediction: each model by its own `q`, combined with the current `mu`.
    pub fn predict(&self, dt: f64, q: [f64; 2]) -> Model {
        let p1 = self.models[0].predict(dt, q[0]);
        let p2 = self.models[1].predict(dt, q[1]);
        Model::blend(self.mu[0], &p1, self.mu[1], &p2)
    }

    /// A later report, steps 1 to 4. `q` holds `[q1, q2]`; `a`, `b` are
    /// `p_enter`, `p_leave`.
    pub fn step(&self, dt: f64, q: [f64; 2], a: f64, b: f64, m: &Measurement) -> (TwoModel, ModeUpdate) {
        let t = switching(a, b, dt);
        let [mu1, mu2] = self.mu;
        let [m1, m2] = &self.models;

        // 1. Mixing, both from the model states before mixing.
        let c = [t[0][0] * mu1 + t[1][0] * mu2, t[0][1] * mu1 + t[1][1] * mu2];
        let mixed: [Model; 2] = std::array::from_fn(|j| {
            if c[j] == 0.0 {
                self.models[j]
            } else {
                let w1 = t[0][j] * mu1 / c[j];
                let w2 = t[1][j] * mu2 / c[j];
                Model::blend(w1, m1, w2, m2)
            }
        });

        // 2. Predict and update each model; 3. its log-likelihood.
        let (u1, g1) = mixed[0].step(dt, q[0], m);
        let (u2, g2) = mixed[1].step(dt, q[1], m);
        let lambda = [-0.5 * g1, -0.5 * g2];

        // 4. Mode probabilities.
        let mut best = f64::NEG_INFINITY;
        for j in 0..2 {
            if c[j] > 0.0 && lambda[j] > best {
                best = lambda[j];
            }
        }
        let e: [f64; 2] = std::array::from_fn(|j| if c[j] > 0.0 { c[j] * (lambda[j] - best).exp() } else { 0.0 });
        let mu = [e[0] / (e[0] + e[1]), e[1] / (e[0] + e[1])];

        (TwoModel { models: [u1, u2], mu }, ModeUpdate { lambda, mu })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Axis;

    fn model() -> Model {
        let a = Axis { p: 0.0, v: 1.0, pp: 25.0, pv: 0.0, vv: 4.0 };
        Model { east: a, north: a }
    }

    #[test]
    fn first_report_mode_probabilities() {
        let t = TwoModel::first(model(), 0.1, 0.3);
        assert_eq!(t.mu, [0.3 / 0.4, 0.1 / 0.4]);
        let c = t.combined();
        assert!((c.east.v - 1.0).abs() < 1e-12 && (c.north.pp - 25.0).abs() < 1e-12, "{:?}", c);
    }

    #[test]
    fn switching_rows_sum_to_one() {
        for dt in [0.0, 0.5, 3.0] {
            let t = switching(0.05, 0.2, dt);
            assert!((t[0][0] + t[0][1] - 1.0).abs() < 1e-15 && (t[1][0] + t[1][1] - 1.0).abs() < 1e-15);
        }
    }

    #[test]
    fn a_step_keeps_mu_a_distribution_and_favors_the_model_that_fits() {
        let t = TwoModel::first(model(), 0.05, 0.2);
        let far = Measurement { pos: (400.0, -300.0), r_pos: (25.0, 25.0), vel: Some((30.0, -20.0)), r_vel: 4.0 };
        let (next, mode) = t.step(2.0, [0.1, 50.0], 0.05, 0.2, &far);
        assert!((next.mu[0] + next.mu[1] - 1.0).abs() < 1e-12);
        assert_eq!(mode.mu, next.mu);
        assert!(next.mu[1] > t.mu[1], "a maneuver raises the maneuver model: {:?}", next.mu);
        let p = t.predict(1.0, [0.1, 50.0]);
        assert_eq!(p.east.p, 1.0);
    }
}
