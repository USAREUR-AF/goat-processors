"""The registration point (one table per extension kind), proven with a
no-op test kind registered only here (tests/registration.py) and the
test-only fixture pack tests/fixtures/correlate-noop."""

import glob
import json
import os
import unittest

from goat_core import FUNCTIONS, PackError, correlate, filter as filt, gate, quality
from registration import NOOP, TESTS_WITH_NOOP
from test_vectors import ROOT, equal

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def run(eng, steps):
    out = []
    for s in steps:
        out.append(eng.ingest(s["ingest"]) if "ingest" in s else eng.tick(s["tick"]))
    return out, eng.snapshot()


def check_vector(case, v, eng):
    outs, snap = run(eng, v["steps"])
    for i, (step, (events, trace)) in enumerate(zip(v["steps"], outs)):
        case.assertIsNone(equal(events, step["expect"], "step%d.events" % i))
        case.assertIsNone(equal(trace, step["trace"], "step%d.trace" % i))
    case.assertIsNone(equal(snap, v["snapshot"], "snapshot"))


class NoopTest(unittest.TestCase):
    def test_table_given_is_unchanged(self):
        self.assertNotIn("noop", gate.TESTS)
        self.assertIn("noop", TESTS_WITH_NOOP)
        self.assertIs(TESTS_WITH_NOOP["noop"], NOOP)
        with self.assertRaises(TypeError):
            gate.TESTS["noop"] = NOOP  # the engine's table is read-only
        with self.assertRaises(ValueError):
            gate.extend(TESTS_WITH_NOOP, "noop", NOOP)

    def test_engine_alone_does_not_know_it(self):
        with self.assertRaises(PackError):
            FUNCTIONS["correlate"].open(os.path.join(FIXTURES, "correlate-noop"))

    def test_invisible_to_every_existing_vector(self):
        """Every correlate vector, its pack parsed with the table that holds
        noop, gives exactly the vector's output."""
        files = sorted(glob.glob(os.path.join(ROOT, "packs", "correlate-*", "vectors", "*.json")))
        self.assertTrue(files)
        for f in files:
            with open(f, encoding="utf-8") as fh:
                v = json.load(fh)
            with self.subTest(vector=v["name"]):
                pack = correlate.load_pack(os.path.join(ROOT, "packs", v["pack"]), tests=TESTS_WITH_NOOP)
                check_vector(self, v, correlate.make_engine(pack))

    def test_its_own_vector(self):
        files = sorted(glob.glob(os.path.join(FIXTURES, "correlate-noop", "vectors", "*.json")))
        self.assertTrue(files)
        for f in files:
            with open(f, encoding="utf-8") as fh:
                v = json.load(fh)
            with self.subTest(vector=v["name"]):
                pack = correlate.load_pack(os.path.join(FIXTURES, v["pack"]), tests=TESTS_WITH_NOOP)
                check_vector(self, v, correlate.make_engine(pack))
                noop = [r for s in v["steps"] for r in s["trace"] if r.get("test") == "noop"]
                self.assertTrue(noop)
                for r in noop:
                    self.assertEqual((r["value"], r["limit"], r["pass"]), (None, None, True))

    def test_decides_nothing(self):
        """The fixture pack without its noop line gives the same events, and
        the same trace once the noop records are taken out."""
        with open(os.path.join(FIXTURES, "correlate-noop", "pack.def"), encoding="utf-8") as fh:
            text = fh.read()
        base_text = "\n".join(l for l in text.splitlines() if l.split() != ["gate", "noop"])
        for f in sorted(glob.glob(os.path.join(ROOT, "packs", "correlate-assign", "vectors", "*.json"))):
            with open(f, encoding="utf-8") as fh:
                steps = json.load(fh)["steps"]
            with self.subTest(vector=os.path.basename(f)):
                with_noop = run(correlate.make_engine(correlate.parse_pack(text, tests=TESTS_WITH_NOOP)), steps)
                base = run(correlate.make_engine(correlate.parse_pack(base_text)), steps)
                for (ev1, tr1), (ev2, tr2) in zip(with_noop[0], base[0]):
                    self.assertEqual(ev1, ev2)
                    self.assertEqual([r for r in tr1 if r.get("test") != "noop"], tr2)
                self.assertEqual(with_noop[1], base[1])


class OtherTables(unittest.TestCase):
    """Every other extension kind is one table too, extended the same way."""

    def test_method(self):
        m = correlate.Method(engine=correlate.ConfirmEngine, required=correlate.METHODS["confirm"].required,
                             refused=correlate.METHODS["confirm"].refused)
        methods = correlate.extend_methods(correlate.METHODS, "confirm2", m)
        text = open(os.path.join(ROOT, "packs", "correlate-gnn", "pack.def"), encoding="utf-8").read()
        pack = correlate.parse_pack(text + "\nmethod confirm2\n", methods=methods)
        self.assertIsInstance(correlate.make_engine(pack), correlate.ConfirmEngine)
        with self.assertRaises(PackError):
            correlate.parse_pack(text + "\nmethod confirm2\n")

    def test_quality_measure(self):
        measures = quality.extend_measures(quality.MEASURES, "zero", quality.Measure("sum", lambda w: 0))
        text = open(os.path.join(ROOT, "packs", "quality-feed", "pack.def"), encoding="utf-8").read()
        rule = "rule z scope=entity measure=zero op=> limit=1 for=1 clear=0 action=alert\n"
        pack = quality.parse_pack(text + "\n" + rule, measures=measures)
        eng = quality.make_engine(pack)
        eng.ingest({"track.source_id": "s", "uid": "u", "time_ms": 0, "lat": 1.0, "lon": 2.0})
        events, _ = eng.tick(10)
        q = [e for e in events if e["ev"] == "quality"]
        self.assertEqual(list(q[0]["measures"])[-1], "zero")
        self.assertEqual(q[1]["measures"]["zero"], 0)
        with self.assertRaises(PackError):
            quality.parse_pack(text + "\n" + rule)

    def test_filter_condition(self):
        always = filt.ConditionKind((frozenset(),), lambda p, r, s, e: (None, None, True))
        conditions = filt.extend_conditions(filt.CONDITIONS, "always", always)
        text = "pack x\nversion 1\ndefault keep\nforget_ms 10\nrule r drop\nwhen always\n"
        eng = filt.make_engine(filt.parse_pack(text, conditions=conditions))
        events, trace = eng.ingest({"track.source_id": "s", "uid": "u", "time_ms": 0, "lat": 1.0, "lon": 2.0})
        self.assertEqual(events, [{"ev": "drop", "entity": "s/u", "rule": "r"}])
        with self.assertRaises(PackError):
            filt.parse_pack(text)


if __name__ == "__main__":
    unittest.main()
