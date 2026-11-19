import glob
import json
import os
import unittest

from goat_correlator import PackError, load_pack, make_engine
from goat_correlator.engine import parse_pack

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))


def equal(got, want, path="$"):
    if isinstance(want, bool) or want is None or isinstance(got, bool) or got is None:
        if got is not want and got != want or type(got) is not type(want):
            if not (got is None and want is None):
                return "%s: got %r want %r" % (path, got, want)
        return None
    if isinstance(want, (int, float)):
        if not isinstance(got, (int, float)):
            return "%s: got %r want %r" % (path, got, want)
        if abs(got - want) > 1e-6 * max(1.0, abs(want)):
            return "%s: got %r want %r" % (path, got, want)
        return None
    if isinstance(want, str):
        return None if got == want else "%s: got %r want %r" % (path, got, want)
    if isinstance(want, list):
        if not isinstance(got, list) or len(got) != len(want):
            return "%s: got %r want %r" % (path, got, want)
        for i, (g, w) in enumerate(zip(got, want)):
            e = equal(g, w, "%s[%d]" % (path, i))
            if e:
                return e
        return None
    if isinstance(want, dict):
        if not isinstance(got, dict) or set(got) != set(want):
            return "%s: keys %r want %r" % (path, sorted(got) if isinstance(got, dict) else got, sorted(want))
        for k in want:
            e = equal(got[k], want[k], "%s.%s" % (path, k))
            if e:
                return e
        return None
    raise AssertionError(path)


class Vectors(unittest.TestCase):
    def test_scenarios(self):
        files = sorted(glob.glob(os.path.join(ROOT, "packs", "*", "vectors", "*.json")))
        self.assertTrue(files)
        for f in files:
            v = json.load(open(f, encoding="utf-8"))
            with self.subTest(vector=v["name"]):
                eng = make_engine(load_pack(os.path.join(ROOT, "packs", v["pack"])))
                for i, step in enumerate(v["steps"]):
                    events, trace = eng.ingest(step["ingest"]) if "ingest" in step else eng.tick(step["tick"])
                    self.assertIsNone(equal(events, step["expect"], "step%d.events" % i))
                    self.assertIsNone(equal(trace, step["trace"], "step%d.trace" % i))
                self.assertIsNone(equal(eng.snapshot(), v["snapshot"], "snapshot"))

    def test_load(self):
        files = sorted(glob.glob(os.path.join(ROOT, "spec", "correlate-load-vectors", "*.json")))
        self.assertTrue(files)
        for f in files:
            v = json.load(open(f, encoding="utf-8"))
            with self.subTest(vector=v["name"]):
                if v["expect_error"]:
                    with self.assertRaises(PackError):
                        parse_pack(v["pack_def"])
                else:
                    parse_pack(v["pack_def"])


if __name__ == "__main__":
    unittest.main()
