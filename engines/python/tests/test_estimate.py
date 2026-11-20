"""Unit tests of goat_core.estimate: the track estimate (spec/correlate.md,
Track estimate and Two-model filter), against the formulas written out."""

import math
import unittest

from goat_core import estimate

FILT = {"accel_var": 1.0, "default_ce_m": 50.0, "vel_sigma_ms": 5.0, "unknown_vel_ms": 100.0}
MAN = {"accel_var": 10.0, "p_enter": 0.05, "p_leave": 0.2}


class OneModel(unittest.TestCase):
    def test_predict_axis(self):
        a = [10.0, 2.0, 4.0, 0.5, 1.0]
        dt, q = 3.0, 2.0
        self.assertEqual(estimate.predict_axis(a, dt, q), [
            10.0 + 2.0 * 3.0, 2.0, 4.0 + 2 * 3.0 * 0.5 + 9.0 * 1.0 + 2.0 * 81.0 / 4,
            0.5 + 3.0 * 1.0 + 2.0 * 27.0 / 2, 1.0 + 2.0 * 9.0])
        self.assertEqual(estimate.predict_axis(a, 0.0, q), a)
        self.assertEqual(a, [10.0, 2.0, 4.0, 0.5, 1.0])  # not changed

    def test_negative_dt(self):
        self.assertEqual(estimate.predict_axis([0.0, 1.0, 1.0, 0.0, 1.0], -2.0, 0.0)[0], -2.0)

    def test_position_and_velocity_steps(self):
        a = [0.0, 1.0, 4.0, 1.0, 2.0]
        new, y, s = estimate.pos_step(a, 3.0, 4.0)
        self.assertEqual((y, s), (3.0, 8.0))
        self.assertEqual(new, [0.0 + 0.5 * 3.0, 1.0 + 0.125 * 3.0, 0.5 * 4.0, 0.5 * 1.0, 2.0 - 0.125 * 1.0])
        new, y, s = estimate.vel_step(a, 3.0, 2.0)
        self.assertEqual((y, s), (2.0, 4.0))
        self.assertEqual(new, [0.0 + 0.25 * 2.0, 1.0 + 0.5 * 2.0, 4.0 - 0.25 * 1.0, 0.5 * 1.0, 0.5 * 2.0])
        self.assertEqual(estimate.pos_update(a, 3.0, 4.0), estimate.pos_step(a, 3.0, 4.0)[0])
        self.assertEqual(estimate.vel_update(a, 3.0, 2.0), estimate.vel_step(a, 3.0, 2.0)[0])

    def test_first_axes(self):
        e, n = estimate.first_axes(1.0, 2.0, 9.0, 16.0, (3.0, 4.0), FILT)
        self.assertEqual(e, [1.0, 3.0, 9.0, 0.0, 25.0])
        self.assertEqual(n, [2.0, 4.0, 16.0, 0.0, 25.0])
        e, n = estimate.first_axes(1.0, 2.0, 9.0, 9.0, None, FILT)
        self.assertEqual(e, [1.0, 0.0, 9.0, 0.0, 10000.0])

    def test_update_axes_is_predict_then_updates(self):
        e0, n0 = estimate.first_axes(0.0, 0.0, 2500.0, 2500.0, (1.0, 1.0), FILT)
        e, n = estimate.update_axes(e0, n0, 2.0, 1.0, 5.0, 6.0, 2500.0, 2500.0, (1.5, 0.5), 25.0)
        want_e = estimate.vel_update(estimate.pos_update(estimate.predict_axis(e0, 2.0, 1.0), 5.0, 2500.0), 1.5, 25.0)
        self.assertEqual(e, want_e)
        e2, _ = estimate.update_axes(e0, n0, 2.0, 1.0, 5.0, 6.0, 2500.0, 2500.0, None, 25.0)
        self.assertEqual(e2, estimate.pos_update(estimate.predict_axis(e0, 2.0, 1.0), 5.0, 2500.0))

    def test_inverse_variance(self):
        a = ([0.0, 1.0, 1.0, 0.0, 1.0], [0.0, 0.0, 1.0, 0.0, 1.0])
        b = ([3.0, 3.0, 2.0, 0.0, 1.0], [6.0, 2.0, 2.0, 0.0, 1.0])
        fe, fn = estimate.inverse_variance([a, b])
        self.assertAlmostEqual(fe[2], 2.0 / 3.0)
        self.assertAlmostEqual(fe[0], (2.0 / 3.0) * (0.0 + 1.5))
        self.assertAlmostEqual(fe[1], 2.0)
        self.assertEqual(fe[3], 0.0)
        self.assertEqual(estimate.inverse_variance([a])[0], [0.0, 1.0, 1.0, 0.0, 1.0])

    def test_with_variance(self):
        pr = ([1.0, 2.0, 3.0, 4.0, 5.0], [1.0, 2.0, 3.0, 4.0, 5.0])
        self.assertIs(estimate.with_variance(pr, (0.0, 0.0)), pr)
        out = estimate.with_variance(pr, (1.0, 2.0))
        self.assertEqual(list(out[0]), [1.0, 2.0, 4.0, 4.0, 5.0])
        self.assertEqual(list(out[1]), [1.0, 2.0, 5.0, 4.0, 5.0])


class TwoModel(unittest.TestCase):
    def test_transition_rows_sum_to_one(self):
        t = estimate.transition(MAN, 2.0)
        for row in t:
            self.assertAlmostEqual(sum(row), 1.0)
        lam = math.pow(1 - 0.25, 2.0)
        self.assertAlmostEqual(t[0][1], 0.05 / 0.25 * (1 - lam))
        self.assertEqual(estimate.transition(MAN, 0.0), [[1.0, 0.0], [0.0, 1.0]])

    def test_first_mode_is_stationary(self):
        self.assertEqual(estimate.first_mode(MAN), [0.2 / 0.25, 0.05 / 0.25])

    def test_blend(self):
        a = [0.0, 0.0, 1.0, 0.0, 1.0]
        self.assertEqual(estimate.blend(a, a, 0.5, 0.5), [0.0, 0.0, 1.0, 0.0, 1.0])
        b = [2.0, 0.0, 1.0, 0.0, 1.0]
        self.assertEqual(estimate.blend(a, b, 0.5, 0.5), [1.0, 0.0, 2.0, 0.0, 1.0])
        self.assertEqual(estimate.blend(a, b, 1.0, 0.0), a)

    def test_update_moves_mode_to_the_better_model(self):
        e, n = estimate.first_axes(0.0, 0.0, 100.0, 100.0, (0.0, 0.0), FILT)
        models = [[list(e), list(n)], [list(e), list(n)]]
        mode = estimate.first_mode(MAN)
        q = (FILT["accel_var"], MAN["accel_var"])
        # a report far from the quiet prediction: the maneuver model explains it better
        new_models, mu, east, north, lam = estimate.two_model_update(
            models, mode, MAN, q, 5.0, 300.0, 0.0, (100.0, 100.0), None, 25.0)
        self.assertAlmostEqual(sum(mu), 1.0)
        self.assertGreater(mu[1], mode[1])
        self.assertGreater(lam[1], lam[0])
        self.assertEqual(east, estimate.blend(new_models[0][0], new_models[1][0], mu[0], mu[1]))
        # a report on the prediction: quiet gains
        _, mu2, _, _, _ = estimate.two_model_update(models, mode, MAN, q, 1.0, 0.0, 0.0, (100.0, 100.0),
                                                    (0.0, 0.0), 25.0)
        self.assertGreater(mu2[0], mu2[1])

    def test_predict_models(self):
        e, n = estimate.first_axes(0.0, 0.0, 100.0, 100.0, (1.0, 0.0), FILT)
        models = [[e, n], [e, n]]
        pe, pn = estimate.predict_models(models, [0.5, 0.5], 2.0, (1.0, 10.0))
        self.assertEqual(pe[0], 2.0)
        self.assertAlmostEqual(pe[2], 0.5 * (100 + 4 * 25 + 4) + 0.5 * (100 + 4 * 25 + 40))


if __name__ == "__main__":
    unittest.main()
