"""Unit tests of goat_core.trace (the key order of every record shape) and
goat_core.snapshot (the shape of every snapshot; restore)."""

import json
import unittest

from goat_core import FUNCTIONS, trace
from vectorlib import load_json, pack_dir, run, vector_files


class Trace(unittest.TestCase):
    def test_key_orders(self):
        self.assertEqual(list(trace.record("s", "a", "b", "t", 1, 2, True)),
                         ["stage", "a", "b", "test", "value", "limit", "pass"])
        self.assertEqual(list(trace.skipped("s", "a", "b", "t")),
                         ["stage", "a", "b", "test", "value", "limit", "pass", "skipped"])
        st = [[1.0, 2.0, 3.0], [4.0, 2.0, 5.0], 7, 0.25, [0.0] * 8]
        self.assertEqual(list(trace.bias("a", "b", 1.0, 9.0, True, st, True)),
                         ["stage", "a", "b", "test", "value", "limit", "pass", "east", "north", "var", "pairs",
                          "time_offset_ms"])
        self.assertEqual(trace.bias("a", "b", 1.0, 9.0, True, st, True)["time_offset_ms"], 250.0)
        self.assertNotIn("time_offset_ms", trace.bias("a", "b", 1.0, 9.0, True, st, False))
        self.assertEqual(list(trace.filter_rule("r", "e", "t", False, 1, 2, False, True)),
                         ["stage", "rule", "entity", "test", "negated", "value", "limit", "pass", "unknown"])
        self.assertNotIn("unknown", trace.filter_rule("r", "e", "t", False, 1, 2, False, False))
        self.assertEqual(list(trace.filter_forget("e", 1, 2, False)),
                         ["stage", "entity", "test", "value", "limit", "pass"])
        self.assertEqual(list(trace.fuse_intersect("g", "m", 0.5)), ["stage", "group", "member", "value"])
        self.assertEqual(list(trace.fuse_kinematics("g", "best", [], None)),
                         ["stage", "group", "method", "candidates", "winner"])
        self.assertEqual(list(trace.fuse_attribute("g", "k", "max", [], None, None)),
                         ["stage", "group", "key", "rule", "candidates", "winner", "value"])
        self.assertEqual(list(trace.quality_sample("e", "nis", 1.0, [])),
                         ["stage", "entity", "sample", "value", "inputs"])
        self.assertEqual(list(trace.quality_rule("r", "s", "m", 1, 2, True, 0, False)),
                         ["stage", "rule", "subject", "measure", "value", "limit", "pass", "count", "active"])


class Snapshot(unittest.TestCase):
    TOP = {"filter": ["entities"], "fuse": ["ref", "entities"],
           "quality": ["ref", "last_tick", "entities", "rules"]}

    def test_top_level_keys(self):
        for function, keys in self.TOP.items():
            v = load_json(vector_files(function)[0])
            eng = FUNCTIONS[function].open(pack_dir(v["pack"]))
            self.assertEqual(list(eng.snapshot()), keys)
        for f in vector_files("correlate"):
            v = load_json(f)
            eng = FUNCTIONS["correlate"].open(pack_dir(v["pack"]))
            _, snap = run(eng, v["steps"])
            want = (["ref", "entities", "groups", "counts", "next_group"] if eng.pack.method == "confirm"
                    else ["ref", "entities", "systems", "next_system", "reported"])
            self.assertEqual(list(snap)[:len(want)], want)

    def test_snapshot_is_a_copy(self):
        v = load_json(vector_files("quality")[0])
        eng = FUNCTIONS["quality"].open(pack_dir(v["pack"]))
        run(eng, v["steps"])
        snap = eng.snapshot()
        before = json.dumps(eng.snapshot())
        for e in snap["entities"].values():
            e["window"].clear()
            e["filter"]["east"][0] = 1e9
        self.assertEqual(json.dumps(eng.snapshot()), before)

    def test_restore_of_an_empty_engine(self):
        for function in ("filter", "fuse", "quality"):
            fn = FUNCTIONS[function]
            v = load_json(vector_files(function)[0])
            pack = fn.load_pack(pack_dir(v["pack"]))
            empty = fn.make_engine(pack).snapshot()
            self.assertEqual(fn.restore(pack, empty).snapshot(), empty)


if __name__ == "__main__":
    unittest.main()
