#!/usr/bin/env python3
"""Check that two copies of the vectors are the same, as spec/vector-format.md compares them.

    python3 -I tools/vectors_match.py COMMITTED_DIR REGENERATED_DIR

Each directory holds `packs/` and `spec/`. Every vector file (packs/*/vectors/*.json
and spec/*-load-vectors/*.json) must exist in both, and the two must agree under the
comparison of spec/vector-format.md: numbers within 1e-6 * max(1, abs(want)), every
other value exactly. Exit 0 when they agree, 1 otherwise, listing every difference.

Why not byte equality: the vectors are computed by the Rust engine, and
spec/correlate.md ("Floats") lets the platform's library functions (sin, cos, atan2,
hypot, pow, exp, ln) differ in the last bit between platforms. A vector regenerated on
another machine can therefore differ in the last digit of a float, and the comparison
every engine uses absorbs exactly that. Any other change fails.
"""

import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import consensus  # noqa: E402  (the same comparison the generators use)

PATTERNS = ("packs/*/vectors/*.json", "spec/*-load-vectors/*.json")


def vector_files(root):
    found = set()
    for pattern in PATTERNS:
        for path in glob.glob(os.path.join(root, pattern)):
            found.add(os.path.relpath(path, root))
    return found


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    committed, regenerated = argv
    a, b = vector_files(committed), vector_files(regenerated)
    bad = 0
    for rel in sorted(a - b):
        print("missing after regeneration: %s" % rel)
        bad += 1
    for rel in sorted(b - a):
        print("new after regeneration, not committed: %s" % rel)
        bad += 1
    for rel in sorted(a & b):
        with open(os.path.join(committed, rel), encoding="utf-8") as f:
            want = json.load(f)
        with open(os.path.join(regenerated, rel), encoding="utf-8") as f:
            got = json.load(f)
        for field, w, g in consensus.differences(want, got):
            print("%s %s: committed %r, regenerated %r" % (rel, field or "<root>", w, g))
            bad += 1
    if bad:
        print("vectors differ: %d" % bad)
        return 1
    print("vectors match: %d files (spec/vector-format.md comparison)" % len(a))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
