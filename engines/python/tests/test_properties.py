"""Property tests over every scenario vector of every function.

Determinism: the same input gives the same output, byte for byte.
Order independence, where the spec says order does not matter:
  - pack.def lines whose order no spec fixes (directives that appear once,
    time_default) may move anywhere: the same output (filter.md, Pack:
    "Other directives may appear in any order relative to the rules";
    correlate.md, Pack: maneuver may come before filter);
  - between two ticks, the reports of different entities may arrive in any
    interleaving where every collection is visited in key order and no
    entity's state reads another's: correlate method assign (decisions are
    per tick, per source in key order), fuse (decisions are per tick), and
    filter packs without `near`. The first accepted report stays first: it
    sets the frame (correlate.md, Frame). Method confirm (per-report
    association), quality (the input clock reads the other sources) and
    filter `near` (reads the reference entity) depend on arrival order by
    their specs and are not tested for it.
Snapshot then restore: filter, fuse and quality continue with the same
output; correlate has no restore (its snapshot omits each entity's last
report and measurement variance: snapshot.py)."""

import json
import os
import random
import unittest

from goat_core import FUNCTIONS
from vectorlib import canon, load_json, pack_dir, read_pack_def, run, vector_files

SEED = 20261120

# pack.def directives whose lines keep their relative order (the spec gives
# their order a meaning, or ties a line to the one before it).
ORDERED = {
    "correlate": {"gate", "confirm", "hold", "priority"},
    "filter": {"rule", "when"},
    "fuse": {"attribute", "source"},
    "quality": {"rule"},
}


def outputs(function, pack, steps):
    eng = FUNCTIONS[function].make_engine(pack)
    return run(eng, steps)


def permute_free_lines(text, ordered, rng):
    """The pack text with every line whose directive is not in `ordered`
    moved to a random place; ordered lines keep their relative order."""
    lines = [l for l in text.splitlines() if l.split("#", 1)[0].strip()]
    fixed = [l for l in lines if l.split()[0] in ordered]
    free = [l for l in lines if l.split()[0] not in ordered]
    out = list(fixed)
    for l in free:
        out.insert(rng.randrange(len(out) + 1), l)
    return "\n".join(out) + "\n"


def entity_of(step):
    r = step["ingest"]
    return "%s/%s" % (r.get("track.source_id"), r.get("uid"))


def interleave(steps, first, rng):
    """Within each run of ingest steps between ticks (after step `first`),
    a random interleaving that keeps each entity's own reports in order.
    Returns the new order as indices of `steps`."""
    order = list(range(first + 1))
    i = first + 1
    while i < len(steps):
        if "tick" in steps[i]:
            order.append(i)
            i += 1
            continue
        j = i
        while j < len(steps) and "ingest" in steps[j]:
            j += 1
        queues = {}
        for k in range(i, j):
            queues.setdefault(entity_of(steps[k]), []).append(k)
        keys = sorted(queues)
        while keys:
            key = rng.choice(keys)
            order.append(queues[key].pop(0))
            if not queues[key]:
                keys.remove(key)
        i = j
    return order


def first_accepted(function, pack, steps):
    """The index of the step whose report set the frame (the first one the
    engine accepted), or -1."""
    eng = FUNCTIONS[function].make_engine(pack)
    for i, s in enumerate(steps):
        if "ingest" not in s:
            eng.tick(s["tick"])
            continue
        before = getattr(eng, "ref", None)
        events, _ = eng.ingest(s["ingest"])
        if before is None and getattr(eng, "ref", None) is not None:
            return i
        if function == "filter" and events and events[0]["ev"] != "reject":
            return i
    return -1


class Determinism(unittest.TestCase):
    def test_same_input_same_output(self):
        for function in FUNCTIONS:
            for f in vector_files(function):
                v = load_json(f)
                with self.subTest(vector=v["name"]):
                    pack = FUNCTIONS[function].load_pack(pack_dir(v["pack"]))
                    a = canon(outputs(function, pack, v["steps"]))
                    b = canon(outputs(function, pack, v["steps"]))
                    pack2 = FUNCTIONS[function].load_pack(pack_dir(v["pack"]))
                    c = canon(outputs(function, pack2, json.loads(json.dumps(v["steps"]))))
                    self.assertEqual(a, b)
                    self.assertEqual(a, c)


class PackLineOrder(unittest.TestCase):
    def test_free_lines_in_any_order(self):
        rng = random.Random(SEED)
        for function in FUNCTIONS:
            for f in vector_files(function):
                v = load_json(f)
                text = read_pack_def(v["pack"])
                parse = FUNCTIONS[function].parse_pack
                want = canon(outputs(function, parse(text), v["steps"]))
                for n in range(3):
                    moved = permute_free_lines(text, ORDERED[function], rng)
                    with self.subTest(vector=v["name"], permutation=n):
                        self.assertEqual(canon(outputs(function, parse(moved), v["steps"])), want)


class ReportInterleaving(unittest.TestCase):
    def cases(self):
        for function in ("correlate", "fuse", "filter"):
            for f in vector_files(function):
                v = load_json(f)
                pack = FUNCTIONS[function].load_pack(pack_dir(v["pack"]))
                if function == "correlate" and pack.method != "assign":
                    continue
                if function == "filter" and any(c.name == "near" for r in pack.rules for c in r.conditions):
                    continue
                yield function, v, pack

    def test_interleaving_between_ticks(self):
        rng = random.Random(SEED)
        tested = 0
        for function, v, pack in self.cases():
            steps = v["steps"]
            want, want_snap = outputs(function, pack, steps)
            first = first_accepted(function, pack, steps)
            for n in range(4):
                order = interleave(steps, first, rng)
                got, got_snap = outputs(function, pack, [steps[i] for i in order])
                with self.subTest(vector=v["name"], interleaving=n):
                    # every step gives what it gave in the original order
                    for pos, i in enumerate(order):
                        self.assertEqual(canon(got[pos]), canon(want[i]), "step %d" % i)
                    self.assertEqual(canon(got_snap), canon(want_snap))
            tested += 1
        self.assertGreater(tested, 20)


class SnapshotRestore(unittest.TestCase):
    def test_restore_continues_the_same(self):
        for function, fn in FUNCTIONS.items():
            if fn.restore is None:
                continue
            for f in vector_files(function):
                v = load_json(f)
                pack = fn.load_pack(pack_dir(v["pack"]))
                steps = v["steps"]
                want, want_snap = outputs(function, pack, steps)
                for k in range(len(steps) + 1):
                    with self.subTest(vector=v["name"], after_step=k):
                        eng = fn.make_engine(pack)
                        run(eng, steps[:k])
                        snap = json.loads(json.dumps(eng.snapshot()))
                        again = fn.restore(pack, snap)
                        self.assertEqual(canon(again.snapshot()), canon(snap))
                        got, got_snap = run(again, steps[k:])
                        self.assertEqual(canon(got), canon(want[k:]))
                        self.assertEqual(canon(got_snap), canon(want_snap))

    def test_correlate_has_no_restore(self):
        self.assertIsNone(FUNCTIONS["correlate"].restore)


if __name__ == "__main__":
    unittest.main()
