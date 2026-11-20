"""Unit tests of goat_core.correlate and correlate_pack (spec/correlate.md,
Pack; spec/correlate-assign.md, Pack): the method table and its rules."""

import unittest

from goat_core import PackError, correlate

BASE = "pack t\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nstale_ms 100\n"
CONFIRM = BASE + "confirm_count 2\nhold_failures 2\n"
ASSIGN = BASE + "method assign\nnew_cost 9\nkeep_bonus 2\n"


class Pack(unittest.TestCase):
    def ok(self, text):
        return correlate.parse_pack(text)

    def bad(self, text):
        with self.assertRaises(PackError):
            correlate.parse_pack(text)

    def test_methods(self):
        self.assertEqual(self.ok(CONFIRM).method, "confirm")
        self.assertEqual(self.ok(ASSIGN).method, "assign")
        self.assertIsInstance(correlate.make_engine(self.ok(CONFIRM)), correlate.ConfirmEngine)
        self.assertIsInstance(correlate.make_engine(self.ok(ASSIGN)), correlate.AssignEngine)
        self.bad(CONFIRM + "method other\n")
        self.bad(CONFIRM + "method\n")

    def test_required_and_refused(self):
        for d in ("confirm_count 2\n", "hold_failures 2\n"):
            self.bad(BASE + d)
        self.bad(ASSIGN.replace("new_cost 9\n", ""))
        for line in ("confirm_count 2", "hold_failures 1", "same_source allow", "output latest",
                     "priority a 1", "confirm distance max_m=1", "hold distance max_m=1"):
            self.bad(ASSIGN + line + "\n")
        for line in ("new_cost 1", "keep_bonus 1", "window 2", "hypotheses 1", "margin 1",
                     "bias sigma_m=10 floor_m=1 gate=9", "time_offset sigma_ms=1"):
            self.bad(CONFIRM + line + "\n")

    def test_tests_and_values(self):
        p = self.ok(CONFIRM + "gate distance max_m=5\ngate same key=x\nconfirm course max_deg=1 min_speed_ms=2\n")
        self.assertEqual(p.gate, [("distance", {"max_m": 5.0}), ("same", {"key": "x"})])
        self.assertEqual(p.confirm, [("course", {"max_deg": 1.0, "min_speed_ms": 2.0})])
        self.bad(CONFIRM + "gate nothing\n")
        self.bad(CONFIRM + "gate\n")
        self.bad(CONFIRM + "gate distance\n")
        self.bad(CONFIRM + "gate distance max_m=1 max_m=2\n")
        self.bad(CONFIRM + "gate distance max_m=x\n")
        self.bad(CONFIRM + "gate distance max_m=nan\n")
        self.bad(CONFIRM + "gate distance max_m=1 extra=2\n")

    def test_cross_checks(self):
        self.ok(ASSIGN + "maneuver accel_var=5 p_enter=0.1 p_leave=0.2\n")
        self.ok("maneuver accel_var=5 p_enter=0.1 p_leave=0.2\n" + ASSIGN)  # before filter
        self.bad(ASSIGN + "maneuver accel_var=1 p_enter=0.1 p_leave=0.2\n")
        self.bad(ASSIGN + "maneuver accel_var=5 p_enter=0.5 p_leave=0.5\n")
        self.bad(ASSIGN + "hypotheses 2\n")
        self.ok(ASSIGN + "window 3\nhypotheses 2\nmargin 1\n")
        self.bad(ASSIGN + "window 3\nmargin 1\n")
        self.bad(ASSIGN + "time_offset sigma_ms=5\n")
        self.ok(ASSIGN + "bias sigma_m=10 floor_m=1 gate=9\ntime_offset sigma_ms=5\n")
        self.bad(ASSIGN + "bias sigma_m=10 floor_m=11 gate=9\n")
        self.bad(ASSIGN + "restart gate=0\n")
        self.bad(ASSIGN + "window 0\n")
        self.bad(BASE.replace("unknown_vel_ms=100", "unknown_vel_ms=0") + "confirm_count 1\nhold_failures 1\n")

    def test_time_default(self):
        p = self.ok(CONFIRM + "time_default a error_ms=5 state=drifting\ntime_default b state=coherent\n")
        self.assertEqual(p.time_default, {"a": {"error_ms": 5.0, "state": "drifting"}, "b": {"state": "coherent"}})
        self.bad(CONFIRM + "time_default a error_ms=5\ntime_default a state=coherent\n")
        self.bad(CONFIRM + "time_default a\n")
        self.bad(CONFIRM + "time_default error_ms=5\n")
        self.bad(CONFIRM + "time_default a error_ms=-1\n")
        self.bad(CONFIRM + "time_default a state=lost\n")
        self.bad(CONFIRM + "time_default a other=1\n")

    def test_repeats_and_comments(self):
        self.bad(CONFIRM + "stale_ms 5\n")
        self.ok("# comment\n\n" + CONFIRM.replace("\n", "  # trailing\n"))
        self.bad(CONFIRM + "nonsense 1\n")

    def test_tables_are_read_only(self):
        with self.assertRaises(TypeError):
            correlate.METHODS["x"] = None
        with self.assertRaises(ValueError):
            correlate.extend_methods(correlate.METHODS, "assign", correlate.METHODS["assign"])


if __name__ == "__main__":
    unittest.main()
