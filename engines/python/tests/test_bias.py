"""Unit tests of goat_core.bias (spec/correlate-assign.md, Sensor bias)."""

import unittest

from goat_core import bias

PRM = {"sigma_m": 100.0, "floor_m": 10.0, "gate": 9.0}


def axis(p, v, pp):
    return [p, v, pp, 0.0, 1.0]


class Bias(unittest.TestCase):
    def test_prior(self):
        self.assertEqual(bias.prior(PRM, False), [[0.0, 10000.0, 0.0], [0.0, 10000.0, 0.0], 0])
        self.assertEqual(bias.prior(PRM, True)[3:], [0.0, [0.0] * 8])

    def test_offset(self):
        self.assertEqual(bias.offset(None, PRM, False, True, (0, 0)), ((0.0, 10000.0), (0.0, 10000.0)))
        st = [[5.0, 400.0, 1.0], [-2.0, 400.0, 1.0], 3]
        self.assertEqual(bias.offset(st, PRM, False, True, (1.0, 1.0)), ((5.0, 400.0), (-2.0, 400.0)))
        self.assertEqual(bias.offset(st, PRM, False, False, (1.0, 1.0)), ((-5.0, 400.0), (2.0, 400.0)))
        timed = st + [0.5, [0.0] * 8]
        self.assertEqual(bias.offset(timed, PRM, True, True, (10.0, 4.0)), ((0.0, 400.0), (-4.0, 400.0)))

    def test_shifted(self):
        pr = (axis(1.0, 2.0, 3.0), axis(4.0, 5.0, 6.0))
        out = bias.shifted(pr, ((10.0, 100.0), (20.0, 200.0)))
        self.assertEqual(list(out[0]), [11.0, 2.0, 103.0, 0.0, 1.0])
        self.assertEqual(list(out[1]), [24.0, 5.0, 206.0, 0.0, 1.0])

    def test_residual(self):
        st = bias.prior(PRM, False)
        lo = (axis(0.0, 1.0, 50.0), axis(0.0, 3.0, 50.0))
        hi = (axis(30.0, 3.0, 50.0), axis(40.0, 5.0, 50.0))
        d2, ys, rs, vs = bias.residual(st, lo, hi, False)
        self.assertEqual((ys, rs, vs), ([30.0, 40.0], [100.0, 100.0], [2.0, 4.0]))
        self.assertEqual(d2, 900.0 / 10100.0 + 1600.0 / 10100.0)

    def test_update_running_mean_and_floor(self):
        st = bias.prior(PRM, False)
        st = bias.update(st, [30.0, 40.0], [100.0, 100.0], PRM)
        self.assertEqual(st[2], 1)
        self.assertEqual(st[0][0], 30.0)
        self.assertEqual(st[0][1], 10000.0 / 2)
        st = bias.update(st, [10.0, 40.0], [100.0, 100.0], PRM)
        self.assertEqual(st[0][0], 20.0)
        self.assertEqual(st[0][2], 0.02)
        for _ in range(200):
            st = bias.update(st, [10.0, 40.0], [100.0, 100.0], PRM)
        self.assertEqual(st[0][1], 100.0)  # floor_m squared

    def test_time_fit_recovers_a_time_offset(self):
        """Pairs whose difference is only velocity * tau: the fit finds tau."""
        st = bias.prior(PRM, True)
        tau = 0.2
        for k in range(40):
            ve, vn = 100.0 * ((k % 5) - 2), 50.0 * ((k % 3) - 1)
            ys = [-ve * tau, -vn * tau]
            st = bias.time_fit(st, ys, [1.0, 1.0], [ve, vn], PRM, 1000.0)
        self.assertAlmostEqual(st[3], tau, places=3)
        self.assertAlmostEqual(st[0][0], 0.0, places=1)
        self.assertEqual(st[2], 40)


if __name__ == "__main__":
    unittest.main()
