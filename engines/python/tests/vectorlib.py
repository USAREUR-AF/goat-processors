"""Shared by the tests: the repository root, the vectors of each function,
structural equality (spec/vector-format.md) and running steps on an engine."""

import glob
import json
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
PACK_PREFIX = {"correlate": "correlate-", "filter": "filter-", "fuse": "fuse-", "quality": "quality-"}


def equal(got, want, path="$"):
    """None when got equals want as spec/vector-format.md defines it, else
    the path of the first difference."""
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


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def vector_files(function):
    """The scenario vectors of a function, in file order."""
    return sorted(glob.glob(os.path.join(ROOT, "packs", PACK_PREFIX[function] + "*", "vectors", "*.json")))


def load_vector_files(function):
    return sorted(glob.glob(os.path.join(ROOT, "spec", function + "-load-vectors", "*.json")))


def pack_dir(name):
    return os.path.join(ROOT, "packs", name)


def read_pack_def(name):
    with open(os.path.join(pack_dir(name), "pack.def"), encoding="utf-8") as f:
        return f.read()


def run(eng, steps):
    """[(events, trace) per step], snapshot."""
    out = [eng.ingest(s["ingest"]) if "ingest" in s else eng.tick(s["tick"]) for s in steps]
    return out, eng.snapshot()


def canon(x):
    """A byte-exact form of an output, for comparisons that must be exact."""
    return json.dumps(x)
