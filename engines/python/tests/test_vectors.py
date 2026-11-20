import glob
import json
import os
import unittest

from goat_correlator import PackError, load_pack, make_engine
from goat_correlator.engine import parse_pack

from vectorlib import ROOT, equal  # noqa: F401  (equal: other tests import it from here)


class Vectors(unittest.TestCase):
    def test_scenarios(self):
        files = sorted(glob.glob(os.path.join(ROOT, "packs", "correlate-*", "vectors", "*.json")))
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
