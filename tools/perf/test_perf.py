#!/usr/bin/env python3
"""Tests of the performance harness (not of any engine's speed).

Run: python3 -I tools/perf/test_perf.py
"""

import glob
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import perf  # noqa: E402
from perf import load_json  # noqa: E402
import run_python  # noqa: E402
import scenario  # noqa: E402

RUNNER = [sys.executable, "-I", os.path.join(HERE, "run_python.py")]


class Stats(unittest.TestCase):
    def test_spread(self):
        self.assertEqual(perf.spread([3.0, 1.0, 2.0]), {"median": 2.0, "min": 1.0, "max": 3.0, "n": 3})
        self.assertEqual(perf.spread([4.0, 1.0, 2.0, 3.0])["median"], 2.5)

    def test_rate_cells(self):
        cell = {"ok": True, "wall_s": {"median": 2.0, "min": 1.0, "max": 4.0, "n": 3},
                "rss_kb": {"median": 2048, "min": 1024, "max": 4096, "n": 3}}
        self.assertEqual(perf._cell_rate(100, cell), "50.0 (25.0 to 100)")
        self.assertEqual(perf._cell_rss(cell), "2 (1 to 4)")
        self.assertEqual(perf._cell_rate(100, {"ok": False, "exit": 3}), "fails (exit 3)")

    def test_same(self):
        self.assertTrue(perf.same({"a": [1, 2.0000001]}, {"a": [1.0, 2]}))
        self.assertFalse(perf.same({"a": 1}, {"a": 1, "b": None}))
        self.assertFalse(perf.same(True, 1))
        self.assertFalse(perf.same(None, 0))
        self.assertFalse(perf.same([1, 2], [1, 2, 3]))


class Scenario(unittest.TestCase):
    def test_deterministic(self):
        a = json.dumps(scenario.steps_for("correlate", "smoke"), sort_keys=True)
        b = json.dumps(scenario.steps_for("correlate", "smoke"), sort_keys=True)
        self.assertEqual(a, b)

    def test_steps_and_fuse_groups(self):
        d = scenario.steps_for("fuse", "smoke")
        ing = [s["ingest"] for s in d["steps"] if "ingest" in s]
        ticks = [s["tick"] for s in d["steps"] if "tick" in s]
        self.assertEqual(ticks, list(range(1000, 60001, 1000)))
        self.assertTrue(all(isinstance(r["time_ms"], int) for r in ing))
        self.assertTrue(any("fuse.group" in r for r in ing))
        self.assertFalse(any("fuse.group" in s.get("ingest", {})
                             for s in scenario.steps_for("filter", "smoke")["steps"]))
        self.assertIn("%d reports" % len(ing), d["description"])


class Runner(unittest.TestCase):
    """run_python.py implements the runner contract (README.md)."""

    def run_on(self, function, vector_path, *extra):
        v = load_json(vector_path)
        with tempfile.TemporaryDirectory() as d:
            ev = os.path.join(d, "ev.jsonl")
            out = subprocess.run(RUNNER + ["--function", function, "--pack", os.path.join(ROOT, "packs", v["pack"]),
                                           "--steps", vector_path, "--events", ev] + list(extra),
                                 check=True, capture_output=True, text=True).stdout
            with open(ev, encoding="utf-8") as fh:
                lines = [json.loads(x) for x in fh]
        return v, out, lines

    def test_vector_is_a_steps_file_and_output_matches_it(self):
        for function in perf.FUNCTIONS:
            path = sorted(glob.glob(os.path.join(ROOT, "packs", function + "-*", "vectors", "*.json")))[0]
            v, out, lines = self.run_on(function, path, "--trace")
            self.assertEqual(len(out.strip().splitlines()), 1, "stdout is exactly one line")
            c = json.loads(out)
            self.assertEqual(c["steps"], len(v["steps"]))
            self.assertEqual(c["ingest"] + c["tick"], c["steps"])
            for k in ("parse_ns", "load_ns", "run_ns"):
                self.assertIsInstance(c[k], int)
            self.assertEqual(len(lines), len(v["steps"]) + 1)
            for i, (rec, st) in enumerate(zip(lines, v["steps"])):
                self.assertEqual(rec["step"], i)
                self.assertTrue(perf.same(rec["events"], st["expect"]), (function, path, i))
                self.assertTrue(perf.same(rec["trace"], st["trace"]), (function, path, i))
            self.assertTrue(perf.same(lines[-1]["snapshot"], v["snapshot"]))
            self.assertEqual(c["events"], sum(len(s["expect"]) for s in v["steps"]))

    def test_no_trace_without_flag(self):
        path = sorted(glob.glob(os.path.join(ROOT, "packs", "filter-*", "vectors", "*.json")))[0]
        _, _, lines = self.run_on("filter", path)
        self.assertNotIn("trace", lines[0])

    def test_bad_pack_fails(self):
        path = sorted(glob.glob(os.path.join(ROOT, "packs", "filter-*", "vectors", "*.json")))[0]
        r = subprocess.run(RUNNER + ["--function", "filter", "--pack", os.path.join(ROOT, "no-such-pack"),
                                     "--steps", path], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)

    def test_vector_writer_reproduces_committed_vector(self):
        path = sorted(glob.glob(os.path.join(ROOT, "packs", "correlate-gnn", "vectors", "*.json")))[0]
        v = load_json(path)
        w = run_python.vector("correlate", os.path.join(ROOT, "packs", v["pack"]), v["steps"], v["name"], v["pack"])
        self.assertTrue(perf.same(w, v))


class Measure(unittest.TestCase):
    def test_measure_and_counters(self):
        wall, rss, code, tail = perf.measure([sys.executable, "-c", "print('{\"run_ns\": 5, \"parse_ns\": 1}')"])
        self.assertEqual(code, 0)
        self.assertGreater(wall, 0)
        self.assertEqual(perf.last_json(tail)["run_ns"], 5)
        if os.access(perf.TIME, os.X_OK):
            self.assertGreater(rss, 0)

    def test_failure_is_reported(self):
        r = perf.repeat([sys.executable, "-c", "import sys; sys.exit(3)"], 2)
        self.assertEqual((r["ok"], r["exit"]), (False, 3))


class Report(unittest.TestCase):
    def test_render_from_minimal_results(self):
        cell = {"ok": True, "wall_s": {"median": 1.0, "min": 0.9, "max": 1.1, "n": 3},
                "rss_kb": {"median": 1024, "min": 1000, "max": 1100, "n": 3}}
        res = {"commit": "abc1234", "machine": {"cpu": "x", "cores": 2, "memory_gb": 1, "os": "y"},
               "versions": {k: k for k in ("python", "rust", "go", "java", "cpp", "cmake", "erlang", "zig")},
               "repeats": 3, "large_repeats": 1,
               "large": {"description": "d", "vector_bytes": {"filter-thin": 1e6}},
               "counts": {f: {"vectors": 1, "ingest": 10, "tick": 1, "load_vectors": 1} for f in perf.FUNCTIONS},
               "large_counts": {f: {"vectors": 1, "ingest": 10, "tick": 1, "load_vectors": 1} for f in perf.FUNCTIONS},
               "vectors": {"python": {f: cell for f in perf.FUNCTIONS}},
               "large_vectors": {"python": {f: dict(cell) if f != "fuse" else {"ok": False, "exit": 1, "tail": "boom"}
                                            for f in perf.FUNCTIONS}},
               "runner": {"python": {"filter-thin": dict(cell, function="filter", counters={"ingest": 10},
                                                         run_s=cell["wall_s"], parse_s=cell["wall_s"],
                                                         output="equal to python")}}}
        text = perf.render(res)
        self.assertIn("`abc1234`", text)
        self.assertIn("| python | 10.0 (9.09 to 11.1) |", text)
        self.assertIn("fails (exit 1)", text)
        self.assertIn("| rust | no runner yet |", text)
        self.assertIn("## Runs that did not pass", text)


if __name__ == "__main__":
    unittest.main()
