"""Checks of feedcheck.py. Run: python3 -I tools/feeds/test_feedcheck.py"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import feedcheck as F  # noqa: E402
import scenarios as S  # noqa: E402


def capture(sensors, seed=3):
    objs = [S.Obj("o%d" % i, east=i * 3000.0, speed=150.0, heading=30.0 * i) for i in range(3)]
    vector, _ = S.Scenario("t", "t", "t", objs, sensors, duration_s=150, seed=seed).build()
    return [s["ingest"] for s in vector["steps"] if "ingest" in s], [s["tick"] for s in vector["steps"] if "tick" in s]


class Verdicts(unittest.TestCase):
    def test_sensors_that_see_the_same_objects_exercise_fusion(self):
        res = F.check(*F.demo("overlap"))
        self.assertEqual(res["verdict"]["fusion"], "exercised")
        self.assertTrue(all(v.startswith("ready") for k, v in res["verdict"].items() if k != "fusion"))

    def test_sensors_200_km_apart_do_not(self):
        res = F.check(*F.demo("apart"))
        self.assertTrue(res["verdict"]["fusion"].startswith("not exercised: the sources rarely"))
        self.assertEqual(res["fused tracks"], 0.0)

    def test_a_source_that_states_a_quarter_of_its_error_is_not_ready(self):
        res = F.check(*capture([S.radar(ce="understated", ce_factor=4), S.beacon()]))
        self.assertIn("error honesty", res["verdict"]["radar"])
        self.assertTrue(res["verdict"]["beacon"].startswith("ready"))

    def test_a_source_without_stated_error_is_not_ready(self):
        res = F.check(*capture([S.radar(ce="absent"), S.beacon()]))
        self.assertIn("stated error", res["verdict"]["radar"])

    def test_one_source_has_no_fusion_to_exercise(self):
        res = F.check(*capture([S.beacon()]))
        self.assertEqual(res["verdict"]["fusion"], "one source: no fusion to exercise")


class Files(unittest.TestCase):
    def test_a_runner_record_and_plain_reports_read_the_same(self):
        reports, ticks = F.demo("overlap")
        with tempfile.TemporaryDirectory() as d:
            rec, plain = os.path.join(d, "rec.jsonl"), os.path.join(d, "plain.jsonl")
            with open(rec, "w") as f:
                for r in reports:
                    f.write(json.dumps({"ingest": r}) + "\n")
                for t in ticks:
                    f.write(json.dumps({"tick": t}) + "\n")
            with open(plain, "w") as f:
                f.writelines(json.dumps(r) + "\n" for r in reports)
            a, b = F.read([rec]), F.read([plain])
        self.assertEqual(a[0], b[0])
        self.assertEqual(a[1], sorted(ticks))

    def test_the_renamed_summary_holds_no_position_identifier_or_source_name(self):
        reports, ticks = F.demo("overlap")
        res = F.check(reports, ticks, rename=True)

        def leaves(x):
            if isinstance(x, dict):
                for k, v in x.items():
                    yield k
                    yield from leaves(v)
            elif isinstance(x, list):
                for v in x:
                    yield from leaves(v)
            else:
                yield x
        values = set(leaves(res))
        secret = {r[k] for r in reports for k in ("uid", "track.source_id", "lat", "lon", "time_ms")}
        self.assertEqual(values & secret, set())
        self.assertEqual(set(res["sources"]), {"s1", "s2"})

if __name__ == "__main__":
    unittest.main()
