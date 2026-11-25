"""Checks of functions.py against answers known without it. Run: python3 -I tools/bench/test_functions.py"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bench  # noqa: E402
import functions as F  # noqa: E402


class Fuse(unittest.TestCase):
    def test_a_straight_track_with_honest_errors_has_an_honest_stated_error(self):
        for pair in bench.build({"straight-level"}):
            s = F.derive_fuse(F.run_fuse("fuse-independent", pair)[0])
        self.assertLess(s["rms_m"], 30)
        self.assertTrue(0.3 < s["nees"] < 2, s)
        self.assertGreater(s["within95"], 0.85)

    def test_the_breakdown_adds_up(self):
        for pair in bench.build({"random-02"}):
            out, parts = F.run_fuse("fuse-best", pair)
        self.assertEqual(out["n"], sum(p["n"] for p in parts.values()))
        self.assertGreater(parts["a member changed object"]["n"], 0)      # its beacon swaps two numbers


class Filter(unittest.TestCase):
    def test_distance(self):
        self.assertAlmostEqual(F.distance_m((0, 0), (0, 1)), 111195.08, delta=0.1)
        self.assertAlmostEqual(F.distance_m((0, 179.5), (0, -179.5)), 111195.08, delta=0.1)

    def test_right_decisions(self):
        own = (1.0, 1.0)
        self.assertTrue(F.right_area((1.1, 1.0), own, "S", 0))            # 11 km from own ship
        self.assertFalse(F.right_area((1.45, 1.45), own, "A", 5000))      # far, low air
        self.assertTrue(F.right_area((1.45, 1.45), own, "A", 6000))       # far, high air
        self.assertFalse(F.right_area((1.3, 1.3), own, "A", 9000))        # in the harbor circle
        self.assertFalse(F.right_area((0.4, 1.0), own, "A", 9000))        # outside the box
        self.assertTrue(F.right_dateline((0, -176), None, "S", 0))
        self.assertFalse(F.right_dateline((0, 174), None, "S", 0))
        self.assertTrue(F.right_dateline((20.05, 180), None, "S", 0))

    def test_with_no_position_error_the_engine_agrees_with_every_right_decision(self):
        for pack in F.FILTER_PACKS:
            for i in range(5):
                s = F.run_filter(pack, 0.001, i)
                self.assertEqual((s["fp"], s["fn"]), (0, 0), pack)
                self.assertTrue(s["tp"] and s["tn"], pack)


class Quality(unittest.TestCase):
    def test_every_fault_is_drawn_on_both_sides(self):
        for pack, rules in F.FAULTS.items():
            for rule, (_, fault, _) in rules.items():
                got = {fault(F.Rng(F.seed(pack, rule, i)))[1] for i in range(F.N_QUALITY)}
                self.assertEqual(got, {True, False}, rule)

    def test_counts_cover_every_subject_and_scored_tick(self):
        s = F.run_quality("quality-feed", "source-latent", 0)
        self.assertEqual(s["tp"] + s["fp"] + s["fn"] + s["tn"], 4 * (F.DURATION_S - F.WARMUP_S))


class Scores(unittest.TestCase):
    def test_decisions(self):
        d = F.derive_decisions({"tp": 8, "fp": 2, "fn": 8, "tn": 5})
        self.assertEqual((d["precision"], d["recall"]), (0.8, 0.5))
        self.assertAlmostEqual(d["f1"], 8 / 13)

    def test_every_operational_pack_is_scored_or_listed(self):
        listed = set(sum(F.PACKS.values(), [])) | set(F.NOT_COVERED)
        have = {p for p in os.listdir(os.path.join(F.ROOT, "packs")) if p.split("-")[0] in F.PACKS}
        self.assertEqual(have, listed)


if __name__ == "__main__":
    unittest.main()
