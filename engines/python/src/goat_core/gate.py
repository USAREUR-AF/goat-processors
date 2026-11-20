"""The correlate tests (spec/correlate.md, Tests): distance, window,
mahalanobis, course, speed, altitude, same.

A test compares entity A, the one just reported, with entity B predicted to
A's time. `run_test` writes its trace record and returns whether it passed.

TESTS is the one table of tests: a test is one entry, a TestKind with its
parameters and its evaluation. A pack names its tests from the table its
parser was given (correlate.parse_pack(text, tests=...)), so a test added
with `extend` is known only to the packs parsed with that table."""

import math
from types import MappingProxyType
from typing import Callable, NamedTuple, Tuple

from . import trace as _trace
from .model import environment

def mahalanobis(pe, pn, pred, r):
    """Tests, d2: (p - pb)^2 / (pp_b + r) summed over east and north, for
    the position (pe, pn), the prediction pred = (east, north) and the
    measurement variances r = (r_east, r_north)."""
    be, bn = pred
    return (pe - be[0]) ** 2 / (be[2] + r[0]) + (pn - bn[0]) ** 2 / (bn[2] + r[1])


def plane_distance(pe, pn, pred):
    """Tests, distance: in the plane, from (pe, pn) to the predicted position."""
    return math.hypot(pe - pred[0][0], pn - pred[1][0])


def course_difference(ca, cb):
    """Tests, course: the smaller angle between two courses, deg."""
    d = abs(ca - cb)
    return min(d, 360.0 - d)


def speed_difference_pct(sa, sb):
    """Tests, speed: abs(1 - slow/fast) * 100, 0 when the faster speed is 0."""
    slow, fast = sorted((sa, sb))
    return 0.0 if fast == 0 else abs(1.0 - slow / fast) * 100.0


class TestKind(NamedTuple):
    """One test: its parameter names, and evaluate(eng, prm, a, b), which
    returns (value, limit, pass), or None when the test is skipped (it then
    passes). `text`: the parameters are kept as text, not numbers."""
    params: Tuple[str, ...]
    evaluate: Callable
    text: bool = False


def _distance(eng, prm, a, b):
    value, limit = eng._dist(a, b), prm["max_m"]
    return value, limit, value < limit


def _window(eng, prm, a, b):
    lo, hi = prm["err_min_m"], prm["err_max_m"]
    ea = min(max(a.ce(eng.pack), lo), hi)
    eb = min(max(b.ce(eng.pack), lo), hi)
    value = eng._dist(a, b)
    limit = prm["multiplier"] * math.sqrt(ea * ea + eb * eb) + prm["window_m"]
    ok = value < limit
    return value, limit, ok


def _mahalanobis(eng, prm, a, b):
    value, limit = eng._d2(a, b), prm["gate"]
    return value, limit, value < limit


def _course(eng, prm, a, b):
    ra, rb = a.report, b.report
    ca, cb = ra.get("course"), rb.get("course")
    sa, sb = ra.get("speed_ms"), rb.get("speed_ms")
    if (ca is None or cb is None or sa is None or sb is None
            or float(sa) < prm["min_speed_ms"] or float(sb) < prm["min_speed_ms"]):
        return None
    value, limit = course_difference(float(ca), float(cb)), prm["max_deg"]
    return value, limit, value <= limit


def _speed(eng, prm, a, b):
    sa, sb = a.report.get("speed_ms"), b.report.get("speed_ms")
    if sa is None or sb is None or float(sa) < prm["min_speed_ms"] or float(sb) < prm["min_speed_ms"]:
        return None
    value, limit = speed_difference_pct(float(sa), float(sb)), prm["max_pct"]
    return value, limit, value <= limit


def _altitude(eng, prm, a, b):
    ha, hb = a.report.get("hae"), b.report.get("hae")
    if ha is None or hb is None:
        return None
    value, limit = abs(float(ha) - float(hb)), prm["max_m"]
    return value, limit, value <= limit


def _same(eng, prm, a, b):
    ra, rb = a.report, b.report
    k = prm["key"]
    va = environment(ra) if k == "@env" else ra.get(k)
    vb = environment(rb) if k == "@env" else rb.get(k)
    value, limit, ok = va, vb, va == vb
    return value, limit, ok


TESTS = MappingProxyType({
    "distance": TestKind(("max_m",), _distance),
    "window": TestKind(("multiplier", "window_m", "err_min_m", "err_max_m"), _window),
    "mahalanobis": TestKind(("gate",), _mahalanobis),
    "course": TestKind(("max_deg", "min_speed_ms"), _course),
    "speed": TestKind(("max_pct", "min_speed_ms"), _speed),
    "altitude": TestKind(("max_m",), _altitude),
    "same": TestKind(("key",), _same, text=True),
})


def extend(tests, name, kind):
    """A new table: `tests` with one more test. The table given is unchanged."""
    if name in tests:
        raise ValueError("test %s is already in the table" % name)
    out = dict(tests)
    out[name] = kind
    return MappingProxyType(out)


def run_test(eng, stage, name, prm, a, b, trace):
    """One test of a stage: its trace record, and whether it passed."""
    out = eng.pack.tests[name].evaluate(eng, prm, a, b)
    if out is None:
        trace.append(_trace.skipped(stage, a.key, b.key, name))
        return True
    value, limit, ok = out
    trace.append(_trace.record(stage, a.key, b.key, name, value, limit, ok))
    return ok


def run_stage(eng, stage, tests, a, b, trace):
    """Tests, within a stage: in pack order, stopping at the first that fails."""
    for name, prm in tests:
        if not run_test(eng, stage, name, prm, a, b, trace):
            return False
    return True
