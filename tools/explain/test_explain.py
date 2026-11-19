"""Checks for tools/explain: every vector replays to its own events, trace and
snapshot, and the page it writes is self-contained.

    python3 -I tools/explain/test_explain.py
"""

import glob
import json
import os
import re
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import explain  # noqa: E402

ROOT = explain.ROOT
VECTORS = sorted(glob.glob(os.path.join(ROOT, "packs", "*", "vectors", "*.json")))


class Explain(unittest.TestCase):
    def test_every_vector_replays_exactly(self):
        """Every vector of a function whose Python engine is on this tree."""
        self.assertTrue(VECTORS)
        for f in VECTORS:
            pack = os.path.basename(os.path.dirname(os.path.dirname(f)))
            if explain.load_engine(pack)[0] is None:
                continue
            with self.subTest(vector=os.path.basename(f)):
                d = explain.build(f)
                self.assertTrue(d["replayed"], d["note"])
                self.assertEqual(d["mismatch_steps"], 0)
                self.assertTrue(d["snapshot_match"])
                self.assertEqual(len(d["steps"]), len(json.load(open(f, encoding="utf-8"))["steps"]))

    def test_page_is_self_contained(self):
        page = explain.render(explain.build(VECTORS[0]))
        refs = re.findall(r"""(?:src|href)\s*=\s*["']([^"']+)""", page)
        self.assertEqual(refs, [])
        urls = set(re.findall(r"https?://[^\s\"'<>)]+", page)) - {"http://www.w3.org/2000/svg"}
        self.assertEqual(urls, set())
        data = re.search(r'<script id="data" type="application/json">(.*?)</script>', page, re.S).group(1)
        self.assertEqual(json.loads(data)["name"], json.load(open(VECTORS[0], encoding="utf-8"))["name"])

    def test_a_changed_vector_is_marked(self):
        v = json.load(open(VECTORS[0], encoding="utf-8"))
        step = next(i for i, s in enumerate(v["steps"]) if s["trace"])
        v["steps"][step]["trace"][0]["value"] = 123.0
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, "changed.json")
            json.dump(v, open(p, "w", encoding="utf-8"))
            d = explain.build(p)
        self.assertEqual(d["mismatch_steps"], 1)
        self.assertIn("trace[0].value", d["steps"][step]["diffs"][0])

    def test_input_without_expectations_is_replayed(self):
        v = json.load(open(VECTORS[0], encoding="utf-8"))
        run = {"pack": v["pack"], "steps": [{k: s[k] for k in ("ingest", "tick") if k in s} for s in v["steps"]]}
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, "run.json")
            json.dump(run, open(p, "w", encoding="utf-8"))
            d = explain.build(p)
        self.assertTrue(d["replayed"])
        self.assertFalse(d["has_expect"])
        self.assertEqual(d["steps"][-1]["snapshot"], v["snapshot"])

    def test_bench_run_with_pack_truth_and_events(self):
        """The shapes tools/bench writes: steps only, no pack; truth per tick; events per tick."""
        v = json.load(open(VECTORS[0], encoding="utf-8"))
        steps = [{k: s[k] for k in ("ingest", "tick") if k in s} for s in v["steps"]]
        ticks = [s["tick"] for s in steps if "tick" in s] or [0]
        first = next(s["ingest"] for s in steps if "ingest" in s)
        truth = {"ticks": ticks, "labels": ["o1" if "ingest" in s else None for s in steps],
                 "objects": {"o1": {"env": "A", "pos": [[first["lat"], first["lon"]] for _ in ticks]}}}
        events = {"engine": "x", "scenario": "s", "ticks": [{"now_ms": t, "tracks": [
            {"system": "s9", "members": [], "lat": first["lat"], "lon": first["lon"]}]} for t in ticks]}
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for name, obj in (("run.json", {"name": "run", "pack": None, "steps": steps}),
                              ("run.truth.json", truth), ("run.events.json", events)):
                paths.append(os.path.join(tmp, name))
                json.dump(obj, open(paths[-1], "w", encoding="utf-8"))
            d = explain.build(paths[0], paths[1], paths[2], pack=v["pack"])
        self.assertTrue(d["replayed"])
        self.assertEqual(list(d["truth"]), ["o1"])
        self.assertEqual(d["steps"][0]["truth"], "o1")
        tick_steps = [s for s in d["steps"] if s["kind"] == "tick"]
        if tick_steps:
            self.assertEqual(tick_steps[0]["events"][0]["system"], "s9")

    def test_unknown_function_shows_the_file(self):
        v = json.load(open(VECTORS[0], encoding="utf-8"))
        v["pack"] = "nofunction-x"
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, "x.json")
            json.dump(v, open(p, "w", encoding="utf-8"))
            d = explain.build(p)
        self.assertFalse(d["replayed"])
        self.assertEqual(d["steps"][-1]["snapshot"], v["snapshot"])


if __name__ == "__main__":
    unittest.main()
