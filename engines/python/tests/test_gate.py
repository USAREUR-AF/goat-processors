"""Unit tests of goat_core.gate: the correlate tests (spec/correlate.md, Tests)."""

import math
import unittest

from goat_core import correlate, gate
from goat_core.model import environment
from goat_core.tracks import Track


class Pure(unittest.TestCase):
    def test_mahalanobis(self):
        pred = ([3.0, 0.0, 1.0, 0.0, 1.0], [4.0, 0.0, 2.0, 0.0, 1.0])
        self.assertEqual(gate.mahalanobis(0.0, 0.0, pred, (8.0, 6.0)), 9.0 / 9.0 + 16.0 / 8.0)

    def test_plane_distance(self):
        pred = ([3.0, 0.0, 1.0, 0.0, 1.0], [4.0, 0.0, 2.0, 0.0, 1.0])
        self.assertEqual(gate.plane_distance(0.0, 0.0, pred), 5.0)

    def test_course_difference(self):
        self.assertEqual(gate.course_difference(10.0, 350.0), 20.0)
        self.assertEqual(gate.course_difference(350.0, 10.0), 20.0)
        self.assertEqual(gate.course_difference(0.0, 180.0), 180.0)
        self.assertEqual(gate.course_difference(5.0, 5.0), 0.0)

    def test_speed_difference(self):
        self.assertEqual(gate.speed_difference_pct(50.0, 100.0), 50.0)
        self.assertEqual(gate.speed_difference_pct(100.0, 50.0), 50.0)
        self.assertEqual(gate.speed_difference_pct(0.0, 0.0), 0.0)


def _track(key, report, east=(0.0, 0.0, 1.0, 0.0, 1.0), north=(0.0, 0.0, 1.0, 0.0, 1.0)):
    t = Track(key, key.split("/")[0])
    t.report = report
    t.env = environment(report)
    t.last_time_ms = 0
    t.east, t.north = list(east), list(north)
    t.r_meas = (1.0, 1.0)
    return t


PACK = """pack t
version 1
filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100
gate distance max_m=10
gate mahalanobis gate=4
gate course max_deg=30 min_speed_ms=5
gate speed max_pct=20 min_speed_ms=5
gate altitude max_m=100
gate state probability=0.99 hae_sigma_m=100
gate same key=@env
confirm_count 2
hold_failures 2
stale_ms 1000
"""


class RunTests(unittest.TestCase):
    def setUp(self):
        self.eng = correlate.make_engine(correlate.parse_pack(PACK))

    def run_one(self, name, a, b):
        params = [p for n, p in self.eng.pack.gate if n == name][0]
        trace = []
        ok = gate.run_test(self.eng, "gate", name, params, a, b, trace)
        return ok, trace[0]

    def test_distance_and_mahalanobis(self):
        a = _track("a/1", {"x": 1})
        b = _track("b/1", {"x": 1}, east=(6.0, 0.0, 1.0, 0.0, 1.0), north=(8.0, 0.0, 1.0, 0.0, 1.0))
        ok, rec = self.run_one("distance", a, b)
        self.assertEqual((ok, rec["value"], rec["limit"]), (False, 10.0, 10.0))  # value < max_m
        self.assertEqual(list(rec), ["stage", "a", "b", "test", "value", "limit", "pass"])
        ok, rec = self.run_one("mahalanobis", a, b)
        self.assertEqual(rec["value"], 36.0 / 2.0 + 64.0 / 2.0)
        self.assertFalse(ok)

    def test_skipped_tests_pass(self):
        a, b = _track("a/1", {}), _track("b/1", {"course": 1.0, "speed_ms": 10.0, "hae": 5.0})
        for name in ("course", "speed", "altitude"):
            ok, rec = self.run_one(name, a, b)
            self.assertTrue(ok)
            self.assertEqual(rec, {"stage": "gate", "a": "a/1", "b": "b/1", "test": name, "value": None,
                                   "limit": None, "pass": True, "skipped": True})
        slow = _track("a/1", {"course": 1.0, "speed_ms": 4.0})
        self.assertTrue(self.run_one("course", slow, b)[1].get("skipped"))
        self.assertTrue(self.run_one("speed", slow, b)[1].get("skipped"))

    def test_course_speed_altitude_limits_inclusive(self):
        a = _track("a/1", {"course": 0.0, "speed_ms": 100.0, "hae": 0.0})
        b = _track("b/1", {"course": 30.0, "speed_ms": 80.0, "hae": 100.0})
        self.assertTrue(self.run_one("course", a, b)[0])     # 30 <= 30
        self.assertTrue(self.run_one("speed", a, b)[0])      # 20 <= 20
        self.assertTrue(self.run_one("altitude", a, b)[0])   # 100 <= 100
        b.report["hae"] = 100.5
        self.assertFalse(self.run_one("altitude", a, b)[0])

    def test_state_and_same(self):
        a = _track("a/1", {"ce": 5.0, "type": "a-f-A"})
        b = _track("b/1", {"type": "a-h-A-M"}, east=(2.0, 2.0, 1.0, 0.0, 1.0))
        ok, rec = self.run_one("state", a, b)  # (dp^2 + dv^2) / 2 on east, 0 on north
        self.assertEqual((ok, rec["value"], rec["limit"], rec["dof"]), (True, 4.0, 13.2767, 4))
        a.report["hae"], b.report["hae"] = 0.0, 300.0
        ok, rec = self.run_one("state", a, b)  # + 300^2 / (2 * 100^2)
        self.assertEqual((ok, rec["value"], rec["limit"], rec["dof"]), (True, 8.5, 15.0863, 5))
        b.east = [6.0, 0.0, 1.0, 0.0, 1.0]
        self.assertFalse(self.run_one("state", a, b)[0])  # 18 + 4.5 >= 15.0863
        self.assertIsNotNone(gate.TESTS["state"].check({"probability": 0.9, "hae_sigma_m": 100.0}))
        self.assertIsNotNone(gate.TESTS["state"].check({"probability": 0.99, "hae_sigma_m": 0.0}))
        ok, rec = self.run_one("same", a, b)
        self.assertEqual((ok, rec["value"], rec["limit"]), (True, "A", "A"))
        b.report, b.env = {}, None
        ok, rec = self.run_one("same", a, b)
        self.assertEqual((ok, rec["value"], rec["limit"]), (False, "A", None))

    def test_stage_stops_at_first_failure(self):
        a = _track("a/1", {})
        b = _track("b/1", {}, east=(100.0, 0.0, 1.0, 0.0, 1.0))
        trace = []
        self.assertFalse(gate.run_stage(self.eng, "gate", self.eng.pack.gate, a, b, trace))
        self.assertEqual([r["test"] for r in trace], ["distance"])
        near = _track("b/1", {})
        trace = []
        self.assertTrue(gate.run_stage(self.eng, "gate", self.eng.pack.gate, a, near, trace))
        self.assertEqual(len(trace), 7)

    def test_table(self):
        self.assertEqual(set(gate.TESTS), {"distance", "mahalanobis", "state", "course", "speed",
                                           "altitude", "same"})
        self.assertTrue(gate.TESTS["same"].text)
        self.assertFalse(gate.TESTS["distance"].text)


if __name__ == "__main__":
    unittest.main()
