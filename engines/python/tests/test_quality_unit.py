"""Unit tests of goat_core.quality (spec/quality.md): measures, rules,
input clock, forwarding and the pack."""

import unittest

from goat_core import PackError, quality as Q

BASE = """pack t
version 1
filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100
window window_ms=10000 min_samples=2 forget_ms=60000
"""


def rec(**kw):
    r = {"wt": 0, "time_ms": 0, "order": "advance", "interval": None, "latency": None, "lateness": None,
         "source_out_of_order": False, "time_error": None, "time_state": None, "nis": None,
         "speed_err": None, "ce": True, "vel": True, "hae": True}
    r.update(kw)
    return r


def rep(src, uid, t, **kw):
    return dict({"track.source_id": src, "uid": uid, "time_ms": t, "lat": 1.0, "lon": 2.0}, **kw)


class Measures(unittest.TestCase):
    def test_entity_measures(self):
        w = [rec(order="first"), rec(interval=1000, latency=5, time_state="drifting", ce=False),
             rec(interval=3000, latency=-1, time_state="coherent", order="out-of-order")]
        m = Q.entity_measures(Q.MEASURES, w, 700, 2)
        self.assertEqual(list(m), list(Q.MEASURES))
        self.assertEqual(m["reports"], 3)
        self.assertEqual((m["interval_last"], m["interval_mean"], m["interval_max"]), (3000, 2000.0, 3000))
        self.assertEqual(m["age"], 700)
        self.assertEqual((m["latency_mean"], m["latency_max"]), (2.0, 5))
        self.assertIsNone(m["lateness_mean"])
        self.assertEqual((m["out_of_order"], m["duplicate"]), (1, 0))
        self.assertAlmostEqual(m["missing_ce"], 1 / 3)
        self.assertEqual((m["time_state_last"], m["time_state_worst"]), (0, 1))
        self.assertAlmostEqual(m["missing_time"], 1 / 3)
        few = Q.entity_measures(Q.MEASURES, w[:1], 0, 2)
        self.assertIsNone(few["missing_ce"])
        self.assertEqual(few["reports"], 1)

    def test_source_measures(self):
        a = Q.entity_measures(Q.MEASURES, [rec(interval=10), rec(interval=30)], 5, 1)
        b = Q.entity_measures(Q.MEASURES, [rec(interval=20)], 9, 1)
        s = Q.source_measures(Q.MEASURES, [a, b])
        self.assertEqual(s["reports"], 3)
        self.assertEqual(s["interval_mean"], (20.0 + 20.0) / 2)
        self.assertEqual(s["interval_max"], 30)
        self.assertEqual(s["age"], 5)
        self.assertIsNone(s["latency_mean"])
        self.assertEqual(s["entities"], 2)
        self.assertEqual(list(s)[-1], "entities")

    def test_median_and_input_clock(self):
        self.assertEqual(Q._median([1, 2, 3]), 2)
        self.assertEqual(Q._median([1, 2, 3, 4]), 2.5)

        class E:
            def __init__(self, s, t):
                self.source, self.last_time_ms = s, t
        ents = [E("a", 10), E("a", 30), E("b", 20), E("c", 100)]
        self.assertEqual(Q.input_clock(ents, "a"), (60.0, 30))
        self.assertEqual(Q.input_clock(ents, "z"), (30, None))
        self.assertEqual(Q.input_clock([], "a"), (None, None))


class Rules(unittest.TestCase):
    def rule(self, op=">", limit=10.0, n=2, clear=5.0):
        return Q.Rule("r", "entity", "age", op, limit, n, clear, "alert", None)

    def test_rule_step(self):
        r = self.rule()
        self.assertEqual(Q.rule_step(r, 0, False, 11), (1, False, True, 10.0))
        self.assertEqual(Q.rule_step(r, 1, False, 11), (0, True, True, 10.0))
        self.assertEqual(Q.rule_step(r, 1, False, 9), (0, False, False, 10.0))
        self.assertEqual(Q.rule_step(r, 1, False, None), (0, False, False, 10.0))
        self.assertEqual(Q.rule_step(r, 0, True, 6), (0, True, False, 5.0))
        self.assertEqual(Q.rule_step(r, 0, True, 4), (0, False, True, 5.0))
        low = self.rule("<=", 1.0, 1, 2.0)
        self.assertEqual(Q.rule_step(low, 0, False, 1.0), (0, True, True, 1.0))
        self.assertEqual(Q.rule_step(low, 0, True, 2.0), (0, True, False, 2.0))
        self.assertEqual(Q.rule_step(low, 0, True, 2.5), (0, False, True, 2.0))

    def test_met(self):
        self.assertTrue(Q._met("<", 1, 2) and Q._met("<=", 2, 2) and Q._met(">", 3, 2) and Q._met(">=", 2, 2))
        self.assertFalse(Q._met("<", 2, 2) or Q._met(">", 2, 2))


class Engine(unittest.TestCase):
    def engine(self, rules=""):
        return Q.make_engine(Q.parse_pack(BASE + rules))

    def test_samples_and_order(self):
        eng = self.engine()
        _, trace = eng.ingest(rep("a", "1", 1000, received_ms=1100))
        self.assertEqual([r["sample"] for r in trace], ["order", "latency", "source_order"])
        eng.ingest(rep("b", "1", 2000))
        events, trace = eng.ingest(rep("a", "1", 1500))
        self.assertEqual(trace[0]["value"], "advance")
        self.assertIn("lateness", [r["sample"] for r in trace])
        self.assertEqual(eng.ingest(rep("a", "1", 1500))[1][0]["value"], "duplicate")
        self.assertEqual(eng.ingest(rep("a", "1", 1400))[1][0]["value"], "out-of-order")
        self.assertEqual(events[0]["ev"], "pass")
        events, _ = eng.tick(2000)
        self.assertEqual([(e["scope"], e["subject"]) for e in events],
                         [("entity", "a/1"), ("entity", "b/1"), ("source", "a"), ("source", "b")])
        self.assertEqual(events[0]["measures"]["duplicate"], 1)

    def test_tick_out_of_order_and_forget(self):
        eng = self.engine("rule old scope=entity measure=age op=> limit=100 for=1 clear=100 action=drop\n")
        eng.ingest(rep("a", "1", 0))
        events, _ = eng.tick(200)
        self.assertIn("action-start", [e["ev"] for e in events])
        self.assertEqual(eng.tick(100)[0], [{"ev": "reject", "reason": "tick-out-of-order"}])
        out = eng.ingest(rep("a", "1", 150))[0][-1]
        self.assertEqual((out["withheld"], out["rules"]), (True, ["old"]))
        self.assertNotIn("report", out)
        events, _ = eng.tick(70000)
        self.assertEqual([e["ev"] for e in events],
                         ["action-end", "forget", "forget"])
        self.assertEqual(events[0]["reason"], "forget")

    def test_mark_and_downgrade(self):
        eng = self.engine("rule m scope=entity measure=reports op=>= limit=1 for=1 clear=0 action=mark\n"
                          "rule d scope=source measure=entities op=>= limit=1 for=1 clear=0 action=downgrade factor=2\n")
        eng.ingest(rep("a", "1", 0, ce=10.0))
        eng.tick(1)
        out = eng.ingest(rep("a", "1", 2, ce=10.0, **{"quality.marks": ["x", 1]}))[0][-1]
        self.assertEqual(out["rules"], ["m", "d"])
        self.assertEqual(out["report"]["quality.marks"], ["m"])
        self.assertEqual(out["report"]["ce"], 20.0)
        out = eng.ingest(rep("a", "1", 3, **{"quality.marks": ["x"]}))[0][-1]
        self.assertEqual(out["report"]["quality.marks"], ["x", "m"])
        self.assertEqual(out["report"]["ce"], 100.0)

    def test_pack(self):
        good = BASE + "rule r scope=entity measure=age op=> limit=1 for=1 clear=0 action=alert\n"
        Q.parse_pack(good)
        for bad in (BASE.replace("min_samples=2", "min_samples=0"), good.replace("scope=entity", "scope=group"),
                    good.replace("measure=age", "measure=entities"), good.replace("op=>", "op=!="),
                    good.replace("clear=0", "clear=5"), good.replace("action=alert", "action=downgrade"),
                    good.replace("action=alert", "action=alert factor=2"), good + good.splitlines()[-1] + "\n",
                    good.replace("rule r", "rule r!"), BASE + "\x01\n", good.replace("for=1", "for=0"),
                    BASE.replace("window_ms=10000", "window_ms=" + "9" * 5000), BASE + "time_default a\n",
                    BASE + "time_default a state=lost\n", BASE.replace("limit", "") + "filter x=1\n",
                    good.replace("limit=1", "limit=1e400"), good.replace("limit=1", "limit=1.")):
            with self.subTest(text=bad[-60:]):
                with self.assertRaises(PackError):
                    Q.parse_pack(bad)
        source = BASE + "rule r scope=source measure=entities op=> limit=1 for=1 clear=0 action=alert\n"
        self.assertEqual(Q.parse_pack(source).rules[0].measure, "entities")


if __name__ == "__main__":
    unittest.main()
