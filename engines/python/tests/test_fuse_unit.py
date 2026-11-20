"""Unit tests of goat_core.fuse (spec/fuse.md): covariance intersection,
kinematics, attributes, groups and the pack."""

import unittest

from goat_core import PackError, fuse

PACK = """pack t
version 1
filter accel_var=1 default_ce_m=10 vel_sigma_ms=5 unknown_vel_ms=100
kinematics %s
stale_ms 5000
source radar
source beacon
attribute callsign rule=%s
"""


def rep(src, uid, t, lat, lon, group="g", **kw):
    r = {"track.source_id": src, "uid": uid, "time_ms": t, "lat": lat, "lon": lon}
    if group is not None:
        r["fuse.group"] = group
    r.update(kw)
    return r


def axes(pp_e, pp_n, p=0.0):
    return [[p, 0.0, pp_e, 0.0, 1.0], [p, 0.0, pp_n, 0.0, 1.0]]


class CovarianceIntersection(unittest.TestCase):
    def test_weight_bounds(self):
        self.assertEqual(fuse.ci_weight(axes(1.0, 1.0), axes(4.0, 4.0)), 1.0)
        self.assertEqual(fuse.ci_weight(axes(4.0, 4.0), axes(1.0, 1.0)), 0.0)
        self.assertEqual(fuse.ci_weight(axes(1.0, 1.0), axes(1.0, 1.0)), 0.5)
        w = fuse.ci_weight(axes(1.0, 4.0), axes(4.0, 1.0))
        self.assertAlmostEqual(w, 0.5)

    def test_fold(self):
        x, y = axes(1.0, 4.0, p=0.0), axes(4.0, 1.0, p=10.0)
        self.assertIs(fuse.ci_fold(x, y, 1.0), x)
        self.assertIs(fuse.ci_fold(x, y, 0.0), y)
        out = fuse.ci_fold(x, y, 0.5)
        self.assertAlmostEqual(out[0][2], 1.0 / (0.5 / 1.0 + 0.5 / 4.0))
        self.assertEqual(out[0][3], 0.0)


class Engine(unittest.TestCase):
    def engine(self, method="inverse_variance", rule="priority"):
        return fuse.make_engine(fuse.parse_pack(PACK % (method, rule)))

    def test_groups_and_ingest_events(self):
        eng = self.engine()
        self.assertEqual(eng.ingest(rep("radar", "1", 0, 1.0, 2.0))[0],
                         [{"ev": "new", "entity": "radar/1", "group": "g"}])
        self.assertEqual(eng.ingest(rep("radar", "1", 10, 1.0, 2.0, group="h"))[0],
                         [{"ev": "move", "entity": "radar/1", "from": "g", "to": "h"}])
        self.assertEqual(eng.ingest(rep("radar", "1", 5, 1.0, 2.0))[0],
                         [{"ev": "stale-report", "entity": "radar/1", "time_ms": 5, "last_time_ms": 10}])
        eng.ingest(rep("beacon", "1", 10, 1.0, 2.0, group=""))  # empty group: alone
        events, _ = eng.tick(10)
        self.assertEqual([(e["group"], e["members"]) for e in events], [("h", ["radar/1"]), (None, ["beacon/1"])])

    def test_methods_choose(self):
        for method, want in (("best", "beacon/1"), ("priority", "radar/1"), ("latest", "beacon/1")):
            eng = self.engine(method)
            eng.ingest(rep("radar", "1", 0, 1.0, 2.0, ce=50.0))
            eng.ingest(rep("beacon", "1", 100, 1.0, 2.0, ce=5.0))
            events, trace = eng.tick(100)
            self.assertEqual(events[0]["from"], want, method)
            self.assertEqual(trace[0]["winner"], want)
        eng = self.engine("covariance_intersection")
        eng.ingest(rep("radar", "1", 0, 1.0, 2.0, ce=50.0))
        eng.ingest(rep("beacon", "1", 0, 1.0, 2.0, ce=5.0))
        events, trace = eng.tick(0)
        self.assertEqual(trace[0], {"stage": "intersect", "group": "g", "member": "radar/1", "value": 1.0})  # beacon/1 first (key order) and better
        self.assertIsNone(events[0]["from"])
        self.assertAlmostEqual(events[0]["ce"], 5.0)

    def test_attribute_rules(self):
        cases = (("priority", "R"), ("latest", "B"), ("majority", "B"), ("max", None), ("min", None))
        for rule, want in cases:
            eng = self.engine("best", rule)
            eng.ingest(rep("radar", "1", 0, 1.0, 2.0, callsign="R"))
            eng.ingest(rep("beacon", "1", 1, 1.0, 2.0, callsign="B"))
            eng.ingest(rep("beacon", "2", 1, 1.0, 2.0, callsign="B"))
            events, trace = eng.tick(1)
            got = events[0]["attributes"].get("callsign")
            self.assertEqual(got["value"] if got else None, want, rule)
        eng = self.engine("best", "max")
        eng.ingest(rep("radar", "1", 0, 1.0, 2.0, callsign=3))
        eng.ingest(rep("beacon", "1", 0, 1.0, 2.0, callsign=7.5))
        events, _ = eng.tick(0)
        self.assertEqual(events[0]["attributes"]["callsign"], {"value": 7.5, "from": "beacon/1"})

    def test_same_and_usable(self):
        self.assertTrue(fuse._same(1, 1.0))
        self.assertFalse(fuse._same(True, 1))
        self.assertFalse(fuse._same("1", 1))
        self.assertFalse(fuse._usable("x", "max"))
        self.assertTrue(fuse._usable("x", "majority"))
        self.assertFalse(fuse._usable([1], "majority"))

    def test_stale_drop(self):
        eng = self.engine()
        eng.ingest(rep("radar", "1", 0, 1.0, 2.0, stale_ms=50))
        events, _ = eng.tick(50)
        self.assertEqual(events, [{"ev": "drop", "entity": "radar/1", "group": "g"}])

    def test_pack(self):
        good = PACK % ("best", "max")
        fuse.parse_pack(good.replace("\n", "\r\n"))
        for bad in (good.replace("kinematics best", "kinematics fastest"), good + "source radar\n",
                    good + "attribute callsign rule=max\n", good + "attribute x rule=median\n",
                    good + "attribute x=1 rule=max\n", good.replace("stale_ms 5000", "stale_ms -1"),
                    good.replace("stale_ms 5000", "stale_ms " + "9" * 5000), good + "kinematics best\n",
                    good.replace("vel_sigma_ms=5", "vel_sigma_ms=0"), good + "bogus\n",
                    good.replace("accel_var=1", "accel_var=1 accel_var=2")):
            with self.assertRaises(PackError):
                fuse.parse_pack(bad)


if __name__ == "__main__":
    unittest.main()
