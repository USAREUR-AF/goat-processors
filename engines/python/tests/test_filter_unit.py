"""Unit tests of goat_core.filter (spec/filter.md): values, geometry,
conditions, rules, tick and the pack."""

import unittest

from goat_core import PackError, filter as F

PACK = "pack t\nversion 1\ndefault keep\nforget_ms 1000\n"


def rep(t=0, **kw):
    return dict({"track.source_id": "s", "uid": "u", "time_ms": t, "lat": 10.0, "lon": 20.0}, **kw)


class Geometry(unittest.TestCase):
    def test_distance(self):
        self.assertEqual(F.distance(0.0, 0.0, 0.0, 0.0), 0.0)
        one_deg = F.distance(0.0, 0.0, 1.0, 0.0)
        self.assertAlmostEqual(one_deg, F.R * F.rad(1.0), places=6)
        self.assertAlmostEqual(F.distance(0.0, 179.5, 0.0, -179.5), F.distance(0.0, 0.0, 0.0, 1.0), places=6)

    def test_polygon(self):
        sq = [(0.0, 0.0), (0.0, 10.0), (10.0, 10.0), (10.0, 0.0)]
        self.assertEqual(F.polygon(sq, 5.0, 5.0), "inside")
        self.assertEqual(F.polygon(sq, 15.0, 5.0), "outside")
        self.assertEqual(F.polygon(sq, 0.0, 5.0), "boundary")
        self.assertEqual(F.polygon(sq, 10.0, 10.0), "boundary")
        across = [(0.0, 170.0), (0.0, -170.0), (10.0, -170.0), (10.0, 170.0)]
        self.assertEqual(F.polygon(across, 5.0, 179.0), "inside")
        self.assertEqual(F.polygon(across, 5.0, 0.0), "outside")

    def test_predict(self):
        st = {"time_ms": 0, "lat": 0.0, "lon": 0.0, "course": 90.0, "speed_ms": 100.0}
        lat, lon = F.predict(st, 1000)
        self.assertAlmostEqual(lat, 0.0, places=9)
        self.assertAlmostEqual(lon, F.deg(100.0 / F.R), places=12)
        st["course"] = None
        self.assertEqual(F.predict(st, 1000), (0.0, 0.0))

    def test_wrap(self):
        self.assertEqual(F.wrap(-180.0), 180.0)
        self.assertEqual(F.wrap(181.0), -179.0)


class Values(unittest.TestCase):
    def test_key_equal(self):
        self.assertTrue(F.key_equal("x", "x"))
        self.assertTrue(F.key_equal(True, "true"))
        self.assertFalse(F.key_equal(True, "1"))
        self.assertTrue(F.key_equal(1, "1.0"))
        self.assertTrue(F.key_equal(1.5, "1.5"))
        self.assertFalse(F.key_equal(1, "1e0"))
        self.assertFalse(F.key_equal([1], "1"))

    def test_report_helpers(self):
        self.assertEqual(F.affiliation({"type": "a-h-G"}), "h")
        self.assertIsNone(F.affiliation({"type": "b-h-G"}))
        self.assertEqual(F.environment({"type": "a-h-G"}), "G")

    def test_pack_values(self):
        for bad in ("default nope", "forget_ms 0", "forget_ms -1", "forget_ms 1.5",
                    "forget_ms 99999999999999999999", "forget_ms " + "9" * 5000):
            with self.assertRaises(PackError):
                F.parse_pack(PACK.replace("forget_ms 1000", "") + bad + "\n" if "forget_ms" in bad
                             else PACK.replace("default keep", bad))
        p = F.parse_pack(PACK.replace("forget_ms 1000", "forget_ms " + "0" * 5000 + "7"))
        self.assertEqual(p.forget_ms, 7)


class Rules(unittest.TestCase):
    def engine(self, rules):
        return F.make_engine(F.parse_pack(PACK + rules))

    def test_first_matching_rule_decides(self):
        eng = self.engine("rule far drop\nwhen not circle lat=10 lon=20 radius_m=1000\n"
                          "rule slow drop\nwhen speed max=5\n")
        events, trace = eng.ingest(rep(speed_ms=3.0))
        self.assertEqual(events, [{"ev": "drop", "entity": "s/u", "rule": "slow"}])
        self.assertEqual([r["rule"] for r in trace], ["far", "slow"])
        self.assertEqual(trace[0]["value"], 0.0)
        events, trace = eng.ingest(rep(t=1))
        self.assertEqual(events[0]["rule"], "default")
        self.assertTrue(trace[1]["unknown"])
        self.assertFalse(trace[1]["pass"])

    def test_interval_thins(self):
        eng = self.engine("rule thin drop\nwhen interval min_ms=100\n")
        self.assertEqual(eng.ingest(rep(0))[0][0]["ev"], "keep")
        self.assertEqual(eng.ingest(rep(50))[0][0]["ev"], "drop")
        self.assertEqual(eng.ingest(rep(150))[0][0]["ev"], "keep")
        self.assertEqual(eng.snapshot()["entities"]["s/u"]["kept_ms"], 150)

    def test_key_and_has(self):
        eng = self.engine("rule a drop\nwhen key name=x in=1,2\nrule b drop\nwhen has name=y\n"
                          "rule c drop\nwhen key name=z min=1 max=2\n")
        self.assertEqual(eng.ingest(rep(x=2))[0][0]["rule"], "a")
        self.assertEqual(eng.ingest(rep(1, y=0))[0][0]["rule"], "b")
        self.assertEqual(eng.ingest(rep(2, z=1.5))[0][0]["rule"], "c")
        self.assertEqual(eng.ingest(rep(3, z="1.5"))[0][0]["rule"], "default")

    def test_near(self):
        eng = self.engine("rule close keep\nwhen near reference=own/ship radius_m=500 max_age_ms=1000\n"
                          "rule far drop\nwhen not near reference=own/ship radius_m=500 max_age_ms=1000\n")
        self.assertEqual(eng.ingest(rep())[0][0]["rule"], "default")  # no reference: unknown both ways
        eng.ingest({"track.source_id": "own", "uid": "ship", "time_ms": 0, "lat": 10.0, "lon": 20.001})
        self.assertEqual(eng.ingest(rep(10))[0][0]["rule"], "close")
        self.assertEqual(eng.ingest(rep(5000))[0][0]["rule"], "default")  # too old

    def test_tick_forgets(self):
        eng = self.engine("")
        eng.ingest(rep(0))
        events, trace = eng.tick(1000)
        self.assertEqual(events, [])
        self.assertEqual(trace, [{"stage": "forget", "entity": "s/u", "test": "age", "value": 1000,
                                  "limit": 1000, "pass": False}])
        events, _ = eng.tick(1001)
        self.assertEqual(events, [{"ev": "forget", "entity": "s/u"}])

    def test_reject(self):
        self.assertEqual(self.engine("").ingest({"track.source_id": "s"}),
                         ([{"ev": "reject", "reason": "missing:uid"}], []))

    def test_pack_rules(self):
        for bad in ("when has name=x\n", "rule a keep\n", "rule a keep\nwhen has name=x\nrule a drop\nwhen has name=y\n",
                    "rule default keep\nwhen has name=x\n", "rule a maybe\nwhen has name=x\n",
                    "rule a keep\nwhen nothing\n", "rule a keep\nwhen has\n", "rule a keep\nwhen has name=x name=y\n",
                    "rule a keep\nwhen speed min=5 max=1\n", "rule a keep\nwhen polygon vertices=1,1;2,2\n",
                    "rule a keep\nwhen circle lat=91 lon=0 radius_m=1\n", "rule a keep\nwhen env in=A,,B\n",
                    "rule a keep\nwhen not\n"):
            with self.subTest(rules=bad):
                with self.assertRaises(PackError):
                    F.parse_pack(PACK + bad)


if __name__ == "__main__":
    unittest.main()
