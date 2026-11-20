"""Unit tests of goat_core.assign (spec/correlate-assign.md: Memberships,
Assignment of one source, Window) and goat_core.tracks (the shared part)."""

import unittest

from goat_core import assign, correlate

PACK = """pack t
version 1
method assign
filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100
gate mahalanobis gate=18.42
new_cost 9.21
keep_bonus 2
stale_ms 10000
"""


def rep(src, uid, t, lat, lon, **kw):
    return dict({"track.source_id": src, "uid": uid, "time_ms": t, "lat": lat, "lon": lon}, **kw)


class Members(unittest.TestCase):
    def test_leave_ends_an_empty_system(self):
        m = assign._Members()
        events = []
        assign.AssignEngine._apply(["a/1", "b/1"], [2, 3], [], m, events)
        self.assertEqual(m.snap(), {"s1": ["a/1"], "s2": ["b/1"]})
        self.assertEqual(events, [{"ev": "start", "system": "s1", "entity": "a/1"},
                                  {"ev": "start", "system": "s2", "entity": "b/1"}])
        c = m.copy()
        events = []
        assign.AssignEngine._apply(["b/1"], [0], [("s1", ["a/1"])], c, events)
        self.assertEqual(c.snap(), {"s1": ["a/1", "b/1"]})
        self.assertEqual(events, [{"ev": "leave", "system": "s2", "entity": "b/1", "reason": "assign"},
                                  {"ev": "end", "system": "s2"},
                                  {"ev": "join", "system": "s1", "entity": "b/1"}])
        self.assertEqual(m.snap(), {"s1": ["a/1"], "s2": ["b/1"]})  # the copy is independent
        self.assertEqual(c.next, 3)
        self.assertEqual(c.system_of("b/1"), "s1")
        self.assertIsNone(c.system_of("z/1"))

    def test_alone_keeps_a_single_member(self):
        m = assign._Members()
        assign.AssignEngine._apply(["a/1"], [1], [], m, [])
        events = []
        assign.AssignEngine._apply(["a/1"], [0], [], m, events)  # alone column of row 0, no system columns
        self.assertEqual(events, [])

    def test_assignment_cost(self):
        fused = ([3.0, 0.0, 2.0, 0.0, 1.0], [4.0, 0.0, 2.0, 0.0, 1.0])
        cost = assign.assignment_cost([0.0, 0, 1.0, 0, 1], [0.0, 0, 1.0, 0, 1], (1.0, 1.0), fused)
        self.assertEqual(cost, 9.0 / 4.0 + 16.0 / 4.0)


class Engine(unittest.TestCase):
    def test_two_sources_one_object(self):
        eng = correlate.make_engine(correlate.parse_pack(PACK))
        self.assertIsInstance(eng, assign.AssignEngine)
        self.assertEqual(eng.ingest(rep("a", "1", 0, 48.0, 11.0))[0], [{"ev": "new", "entity": "a/1"}])
        eng.ingest(rep("b", "1", 0, 48.0001, 11.0))
        events, trace = eng.tick(0)
        self.assertEqual([e["ev"] for e in events], ["start", "join", "system"])
        self.assertEqual(events[2]["members"], ["a/1", "b/1"])
        self.assertIn({"stage": "assign", "a": "a/1", "b": "alone", "test": "choice", "value": 9.21,
                       "limit": None, "pass": True}, trace)
        snap = eng.snapshot()
        self.assertEqual(snap["systems"], {"s1": ["a/1", "b/1"]})
        self.assertEqual(snap["reported"], [])
        self.assertEqual(snap["entities"]["b/1"]["system"], "s1")

    def test_far_apart_stay_apart_and_stale_drops(self):
        eng = correlate.make_engine(correlate.parse_pack(PACK))
        eng.ingest(rep("a", "1", 0, 48.0, 11.0))
        eng.ingest(rep("b", "1", 0, 48.5, 11.0))
        events, _ = eng.tick(0)
        self.assertEqual([e["members"] for e in events if e["ev"] == "system"], [["a/1"], ["b/1"]])
        events, _ = eng.tick(10001)
        self.assertEqual([e["ev"] for e in events][:4], ["leave", "end", "drop", "leave"])
        self.assertEqual(eng.snapshot()["entities"], {})

    def test_rejects(self):
        eng = correlate.make_engine(correlate.parse_pack(PACK))
        self.assertEqual(eng.ingest({"uid": "1"})[0], [{"ev": "reject", "reason": "missing:track.source_id"}])
        eng.ingest(rep("a", "1", 100, 48.0, 11.0))
        self.assertEqual(eng.ingest(rep("a", "1", 50, 48.0, 11.0))[0],
                         [{"ev": "reject", "entity": "a/1", "reason": "out-of-order"}])


class Tracks(unittest.TestCase):
    def test_time_error_adds_the_timing_variance(self):
        text = PACK + "time_default a error_ms=100\n"
        eng = correlate.make_engine(correlate.parse_pack(text))
        _, trace = eng.ingest(rep("a", "1", 0, 48.0, 11.0, course=90.0, speed_ms=100.0))
        self.assertEqual(trace[0]["test"], "time")
        self.assertAlmostEqual(trace[0]["var_east"], (100.0 * 0.1) ** 2)
        ent = eng.entities["a/1"]
        self.assertAlmostEqual(ent.r_meas[0], 2500.0 + 100.0)
        self.assertEqual(eng._time_error_ms({"time_error_ms": 5}, "a"), 5.0)
        self.assertEqual(eng._time_error_ms({}, "zzz"), 0.0)
        _, trace = eng.ingest(rep("b", "1", 0, 48.0, 11.0))
        self.assertEqual(trace, [])  # time error 0: no record

    def test_pair_values_outside_a_tick_and_distance_gate(self):
        eng = correlate.make_engine(correlate.parse_pack(PACK + "gate distance max_m=5000\n"))
        eng.ingest(rep("a", "1", 0, 48.0, 11.0))
        eng.ingest(rep("b", "1", 0, 48.0001, 11.0))
        a, b = eng.entities["a/1"], eng.entities["b/1"]
        d2, dist = eng._d2(b, a), eng._dist(b, a)  # no tick: computed directly
        events, trace = eng.tick(0)
        self.assertIn(dist, [r["value"] for r in trace if r["test"] == "distance"])
        self.assertIn(d2, [r["value"] for r in trace if r["test"] == "mahalanobis"])
        self.assertIsNone(eng._memo)

    def test_pair_key(self):
        self.assertEqual(correlate.ConfirmEngine._pair("b", "a"), "a|b")
        self.assertEqual(correlate.ConfirmEngine._pair("a", "b"), "a|b")


if __name__ == "__main__":
    unittest.main()
