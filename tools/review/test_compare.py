"""Checks of compare.py and tools/feeds/agree.py. Run: python3 -I tools/review/test_compare.py"""

import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "feeds"))

import compare as C  # noqa: E402
import agree as A  # noqa: E402
import feedcheck  # noqa: E402
import adapters  # noqa: E402
import bench  # noqa: E402


class Compare(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        sc, ev = os.path.join(cls.tmp.name, "sc"), os.path.join(cls.tmp.name, "ev")
        names = {s.name for s in bench.all_scenarios() if s.family == "time"} | {"formation-01"}
        bench.cmd_generate(sc, names)
        for vector, _ in bench.load_scenarios(sc):
            doc = adapters.run_pack("correlate-gnn", vector)
            adapters.write_json(os.path.join(ev, vector["name"] + ".events.json"), dict(doc, engine="outside"))
        cls.res = C.compare_dir(ev, sc, ["correlate-gnn", "correlate-assign-time"], "HEAD")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_a_pack_scored_as_an_outside_tracker_gives_its_committed_numbers(self):
        g = self.res["against"]["correlate-gnn"]["groups"]["time"]["measures"]
        for m, r in g.items():         # counts exactly; floats to one part in a million (positions are rounded in the file)
            if isinstance(r["value"], int):
                self.assertEqual(r["value"], r["base_value"], m)
            else:
                self.assertAlmostEqual(r["value"] / r["base_value"], 1.0, delta=1e-6, msg=m)
        self.assertEqual(self.res["against"]["correlate-gnn"]["better"], [])

    def test_a_group_with_missing_scenarios_is_not_compared(self):
        self.assertEqual(self.res["partial"], ["family: formation"])
        self.assertNotIn("family: formation", self.res["against"]["correlate-gnn"]["groups"])

    def test_a_real_difference_shows(self):
        self.assertTrue(self.res["against"]["correlate-assign-time"]["worse"])


class Agree(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vector = A.as_vector(*feedcheck.demo("overlap"))

    def test_a_pack_agrees_with_itself(self):
        o = A.output("correlate-gnn", self.vector)
        r = A.agreement(self.vector, o, o)
        self.assertEqual((r["agreement_f1"], r["together_in_a_only"], r["together_in_b_only"]), (1.0, 0, 0))

    def test_an_events_file_reads_as_the_pack_it_came_from(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "x.events.json")
            adapters.write_json(path, adapters.run_pack("correlate-gnn", self.vector))
            self.assertEqual(A.output(path, self.vector), A.output("correlate-gnn", self.vector))

    def test_different_packs_disagree_somewhere_and_the_report_names_no_track(self):
        a, b = A.output("correlate-gnn", self.vector), A.output("correlate-distance", self.vector)
        r = A.agreement(self.vector, a, b, worst=3)
        self.assertLess(r["agreement_f1"], 1.0)
        uids = {s["ingest"]["uid"] for s in self.vector["steps"] if "ingest" in s}
        self.assertFalse(any('"%s"' % u in json.dumps(r) for u in uids))


if __name__ == "__main__":
    unittest.main()
