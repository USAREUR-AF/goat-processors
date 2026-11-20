import glob
import json
import os
import unittest

from goat_quality import Engine, PackError, load_pack, parse_pack
from vectorlib import ROOT, equal


class QualityVectors(unittest.TestCase):
    def test_scenarios(self):
        files = sorted(glob.glob(os.path.join(ROOT, "packs", "quality-*", "vectors", "*.json")))
        self.assertTrue(files)
        for f in files:
            v = json.load(open(f, encoding="utf-8"))
            with self.subTest(vector=v["name"]):
                eng = Engine(load_pack(os.path.join(ROOT, "packs", v["pack"])))
                for i, step in enumerate(v["steps"]):
                    events, trace = eng.ingest(step["ingest"]) if "ingest" in step else eng.tick(step["tick"])
                    self.assertIsNone(equal(events, step["expect"], "step%d.events" % i))
                    self.assertIsNone(equal(trace, step["trace"], "step%d.trace" % i))
                self.assertIsNone(equal(eng.snapshot(), v["snapshot"], "snapshot"))

    def test_load(self):
        files = sorted(glob.glob(os.path.join(ROOT, "spec", "quality-load-vectors", "*.json")))
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
