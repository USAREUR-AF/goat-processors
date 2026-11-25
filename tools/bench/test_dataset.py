#!/usr/bin/env python3
"""Tests of the two sets, the families, the intervals and the detection-level scorer.

Run: python3 -I tools/bench/test_dataset.py
"""

import collections
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dataset  # noqa: E402
import detections  # noqa: E402
import scenarios as S  # noqa: E402
import score as scoring  # noqa: E402
import stats  # noqa: E402


class Sets(unittest.TestCase):
    def test_tuning_set_shape(self):
        scs = dataset.tuning_set()
        fam = collections.Counter(s.family for s in scs)
        self.assertEqual(fam["random"], dataset.RANDOM_COUNT)
        self.assertEqual(fam["formation"], dataset.FAMILY_COUNT)
        self.assertEqual(fam["scale"], 0, "scale is a speed question, outside the accuracy sets")
        names = [s.name for s in scs]
        self.assertEqual(len(names), len(set(names)), "scenario names are unique")
        self.assertTrue(set(s.name for s in S.named()) <= set(names), "the named set is part of tuning")

    def test_first_fifty_random_are_the_earlier_set(self):
        old = S.randomized(50)
        new = S.randomized(dataset.RANDOM_COUNT)[:50]
        for a, b in zip(old, new):
            self.assertEqual(a.build(), b.build())

    def test_deterministic_and_seeded_by_root(self):
        a = dataset.family_scenarios(123)[0].build()
        b = dataset.family_scenarios(123)[0].build()
        c = dataset.family_scenarios(124)[0].build()
        self.assertEqual(a, b)
        self.assertNotEqual(a, c)

    def test_evaluation_needs_seeds(self):
        saved, owner = dataset.EVAL_SEEDS, os.environ.get(dataset.EVAL_OWNER_VAR)
        dataset.EVAL_SEEDS = os.path.join(HERE, "no-such-seed-file")
        os.environ[dataset.EVAL_OWNER_VAR] = dataset.EVAL_OWNER
        try:
            self.assertIsNone(dataset.eval_root())
            with self.assertRaises(SystemExit):
                dataset.evaluation_set()
        finally:
            dataset.EVAL_SEEDS = saved
            _restore_env(dataset.EVAL_OWNER_VAR, owner)

    def test_evaluation_needs_owner(self):
        # Even with a readable seed file, nothing reads it without BENCH_EVAL_OWNER.
        saved, owner = dataset.EVAL_SEEDS, os.environ.pop(dataset.EVAL_OWNER_VAR, None)
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"eval_root": 12345, "rotation": 7}, f)
        dataset.EVAL_SEEDS = f.name
        try:
            for call in (dataset.eval_root, dataset.eval_rotation, dataset.evaluation_set):
                with self.assertRaises(SystemExit):
                    call()
            os.environ[dataset.EVAL_OWNER_VAR] = "someone-else"
            with self.assertRaises(SystemExit):
                dataset.eval_root()
            os.environ[dataset.EVAL_OWNER_VAR] = dataset.EVAL_OWNER
            self.assertEqual((dataset.eval_root(), dataset.eval_rotation()), (12345, 7))
        finally:
            dataset.EVAL_SEEDS = saved
            _restore_env(dataset.EVAL_OWNER_VAR, owner)
            os.unlink(f.name)

    def test_evaluation_names_are_marked(self):
        scs = dataset.evaluation_set(root=99)
        self.assertTrue(all(s.name.startswith("eval-") for s in scs))


def _restore_env(name, value):
    if value is None:
        os.environ.pop(name, None)
    else:
        os.environ[name] = value


class Families(unittest.TestCase):
    def test_every_family_builds_one_scenario(self):
        r = S.Rng(7)
        for fn in (dataset.formation, dataset.crossing, dataset.maneuver, dataset.sensor_problems,
                   dataset.mixed_domains, dataset.track_management):
            v, t = fn(r.fork(fn.__name__), "x").build()
            self.assertTrue(any("ingest" in s for s in v["steps"]), fn.__name__)
            self.assertEqual(len(v["steps"]), len(t["labels"]))

    def test_formation_member_keeps_its_slot(self):
        lead = S.Obj("o1", speed=200.0, heading=90.0, moves=[(10, 30, 3.0, 0.0)])
        mem = S.Member("o2", "o1", [(0, -500.0, 300.0)])
        objs = {"o1": lead, "o2": mem}
        lead.integrate(60, objs)
        mem.integrate(60, objs)
        for t in (0.0, 20.0, 50.0):
            e1, n1, _, _ = lead.state(t)
            e2, n2, _, _ = mem.state(t)
            self.assertAlmostEqual(((e2 - e1) ** 2 + (n2 - n1) ** 2) ** 0.5, (500 ** 2 + 300 ** 2) ** 0.5, delta=1.0)

    def test_number_reuse(self):
        sc = S.Scenario("x", "t", "t", [S.Obj("o1", speed=100.0), S.Obj("o2", east=5000.0, speed=100.0)],
                        [S.beacon(drops=[(20, "o1", 5)], reuse_numbers=True, pd=1.0)], duration_s=60)
        v, t = sc.build()
        uids = {}
        for st, lab in zip(v["steps"], t["labels"]):
            if "ingest" in st:
                uids.setdefault(lab, set()).add(st["ingest"]["uid"])
        self.assertEqual(uids["o1"], {"T1"}, "the dropped number T1 is given back to o1's new track")

    def test_silent_sensor(self):
        sc = S.Scenario("x", "t", "t", [S.Obj("o1", speed=100.0)],
                        [S.beacon(outages=[(10, 20)], start_s=5, pd=1.0, jitter_ms=0, latency_ms=0)], duration_s=30)
        v, _ = sc.build()
        times = [s["ingest"]["time_ms"] for s in v["steps"] if "ingest" in s]
        self.assertFalse(any(t < 5000 or 10000 <= t < 20000 for t in times))

    def test_recorded_ships_data(self):
        if not os.path.exists(dataset.RECORDED_SHIPS):
            self.skipTest("no recorded data")
        with open(dataset.RECORDED_SHIPS, encoding="utf-8") as f:
            d = json.load(f)
        self.assertEqual(len(d["input_sha256"]), 64)
        self.assertGreaterEqual(len(d["windows"]), 2)
        text = json.dumps(d)
        for w in d["windows"]:
            self.assertTrue(all(o["oid"].startswith("v") for o in w["objects"]))
        self.assertNotIn("MMSI", text.replace("MMSI, IMO", ""))


class Intervals(unittest.TestCase):
    def raw(self, tp, fp, fn):
        return {"tp": tp, "fp": fp, "fn": fn, "false_merges": 0, "missed_merges": 0, "episodes": 0, "swaps": 0,
                "tta_sum": 0.0, "tta_n": 0, "sq_err": 0.0, "n_err": 0, "gospa_sum": 0.0, "gospa_loc": 0.0,
                "gospa_missed": 0, "gospa_false": 0, "ticks": 1}

    def test_interval_contains_pooled_and_is_deterministic(self):
        raws = [self.raw(10 + i % 7, i % 3, i % 4) for i in range(60)]
        a, b = stats.summary(raws), stats.summary(raws)
        self.assertEqual(a, b)
        lo, hi = a["ci95"]["f1"]
        self.assertTrue(lo <= a["pooled"]["f1"] <= hi)
        self.assertLess(lo, hi)

    def test_verdict(self):
        self.assertEqual(stats.verdict([0.01, 0.05]), "better")
        self.assertEqual(stats.verdict([-3, -1]), "worse")
        self.assertEqual(stats.verdict([-0.01, 0.02]), "no difference shown")
        self.assertEqual(stats.verdict(None), "no difference shown")

    def test_paired_finds_a_consistent_gain_the_overlap_rule_misses(self):
        # Scenarios differ widely in difficulty; B misses one pair fewer on every scenario.
        a = [self.raw(20 + 15 * (i % 9), i % 5, 6 + 5 * (i % 7)) for i in range(40)]
        b = [dict(r, fn=r["fn"] - 1, tp=r["tp"] + 1) for r in a]
        ca, cb = stats.interval(a)["f1"], stats.interval(b)["f1"]
        self.assertTrue(ca[1] >= cb[0], "the separate intervals overlap")
        self.assertEqual(stats.verdict(stats.paired(a, b)["f1"]), "better")
        self.assertEqual(stats.verdict(stats.paired(b, a)["f1"]), "worse")

    def test_paired_with_itself_shows_nothing(self):
        a = [self.raw(10 + i % 7, i % 3, i % 4) for i in range(30)]
        self.assertEqual(stats.paired(a, a)["f1"], [0.0, 0.0])
        self.assertEqual(stats.verdict(stats.paired(a, a)["f1"]), "no difference shown")

    def test_ambiguity_is_judged_by_distance_from_one(self):
        self.assertGreater(stats._gain("ambiguity", 1.3, 1.1), 0)
        self.assertLess(stats._gain("ambiguity", 1.0, 1.2), 0)


class Measures(unittest.TestCase):
    """IDF1 and the SIAP measures on a known scenario, with outputs built from truth."""

    def setUp(self):
        sc = next(x for x in S.named() if x.name == "parallel-500m")
        self.vector, self.truth = sc.build()

    def picture(self, label_of):
        """One output track per object at its true position; label_of(object, tick index) names it."""
        t, owner, last, ticks = self.truth, {}, {}, {}
        k = 0
        for step, lab in zip(self.vector["steps"], t["labels"]):
            if "ingest" in step:
                r = step["ingest"]
                key = "%s/%s" % (r["track.source_id"], r["uid"])
                owner[key], last[key] = lab, r["time_ms"]
                continue
            now = step["tick"]
            out = []
            for o, d in t["objects"].items():
                p = d["pos"][k]
                members = [m for m, ob in owner.items() if ob == o and last[m] >= now - t["live_ms"]]
                if p is not None and members:
                    out.append({"system": label_of(o, k), "members": members, "lat": p[0], "lon": p[1]})
            ticks[now] = out
            k += 1
        return scoring.derive(scoring.score(t, self.vector, ticks))

    def test_perfect_picture(self):
        d = self.picture(lambda o, k: "S-" + o)
        self.assertEqual((d["f1"], d["idf1"], d["completeness"], d["ambiguity"], d["spuriousness"],
                          d["longest_segment"], d["track_changes_per_min"]), (1.0, 1.0, 1.0, 1.0, 0.0, 1.0, 0.0))
        self.assertAlmostEqual(d["gospa_m"], 0.0, places=6)

    def test_labels_traded_halfway(self):
        half = len(self.truth["ticks"]) // 2
        other = {"o1": "o2", "o2": "o1"}
        d = self.picture(lambda o, k: "S-" + (o if k < half else other[o]))
        self.assertLess(d["idf1"], 0.6)                   # each label covers each object for half its life
        self.assertGreater(d["idf1"], 0.4)
        self.assertGreater(d["track_changes_per_min"], 0)
        self.assertLess(d["longest_segment"], 0.6)
        self.assertEqual((d["completeness"], d["spuriousness"]), (1.0, 0.0))   # coverage itself is unchanged


class Detections(unittest.TestCase):
    def test_perfect_tracks_score_zero(self):
        name, seed = detections.scenarios_of("tuning")[0]
        v, t = detections.build(name, seed)
        self.assertTrue(any("dwell" in s for s in v["steps"]))
        for st, lab in zip(v["steps"], t["labels"]):
            if "dwell" in st:
                self.assertEqual(len(st["dwell"]["detection.items"]), len(lab))
        ticks = {tm: [{"track": "T-" + m, "lat": o["pos"][i][0], "lon": o["pos"][i][1]}
                      for m, o in t["objects"].items() if o["pos"][i] is not None]
                 for i, tm in enumerate(t["ticks"])}
        s = detections.score_tracks(t, ticks)
        self.assertEqual((s["gospa_m"], s["swaps"], s["breaks"], s["false_track_ticks"], s["missed_ticks"]),
                         (0.0, 0, 0, 0, 0))


if __name__ == "__main__":
    unittest.main()
