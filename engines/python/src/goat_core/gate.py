"""The correlate tests (spec/correlate.md, Tests): distance, mahalanobis,
state, course, speed, altitude, same.

A test compares entity A, the one just reported, with entity B predicted to
A's time. `run_test` writes its trace record and returns whether it passed.

TESTS is the one table of tests: a test is one entry, a TestKind with its
parameters and its evaluation. A pack names its tests from the table its
parser was given (correlate.parse_pack(text, tests=...)), so a test added
with `extend` is known only to the packs parsed with that table."""

import math
from types import MappingProxyType

from . import trace as _trace

# Chi-square quantiles for 4 and 5 degrees of freedom (Tests, `state`):
# probability -> (4 dof, 5 dof).
CHI2 = {0.95: (9.4877, 11.0705), 0.99: (13.2767, 15.0863),
        0.995: (14.8603, 16.7496), 0.999: (18.4668, 20.5150)}

def mahalanobis(pe, pn, pred, r):
    """Tests, d2: (p - pb)^2 / (pp_b + r) summed over east and north, for
    the position (pe, pn), the prediction pred = (east, north) and the
    measurement variances r = (r_east, r_north)."""
    be, bn = pred
    return (pe - be[0]) ** 2 / (be[2] + r[0]) + (pn - bn[0]) ** 2 / (bn[2] + r[1])


def plane_distance(pe, pn, pred):
    """Tests, distance: in the plane, from (pe, pn) to the predicted position."""
    return math.hypot(pe - pred[0][0], pn - pred[1][0])


def state_statistic(fa, ta, pb, ha, hb, hae_sigma):
    """Tests, state: the track-to-track statistic on the full kinematic
    state. fa = (east, north) of A's filter, ta = A's timing variances, pb =
    B's prediction to A's time (timing variance added). Per axis the 2x2
    position and velocity difference covariance; plus the height difference
    when both report hae. Returns (d2, degrees of freedom)."""
    total = 0.0
    for x in (0, 1):
        a, b = fa[x], pb[x]
        dp = a[0] - b[0]
        dv = a[1] - b[1]
        spp = a[2] + ta[x] + b[2]
        spv = a[3] + b[3]
        svv = a[4] + b[4]
        det = spp * svv - spv * spv
        total += (svv * dp * dp - 2.0 * spv * dp * dv + spp * dv * dv) / det
    if ha is None or hb is None:
        return total, 4
    dh = float(ha) - float(hb)
    return total + dh * dh / (2.0 * hae_sigma * hae_sigma), 5


def course_difference(ca, cb):
    """Tests, course: the smaller angle between two courses, deg."""
    d = abs(ca - cb)
    return min(d, 360.0 - d)


def speed_difference_pct(sa, sb):
    """Tests, speed: abs(1 - slow/fast) * 100, 0 when the faster speed is 0."""
    slow, fast = sorted((sa, sb))
    return 0.0 if fast == 0 else abs(1.0 - slow / fast) * 100.0


class TestKind:
    """One test: its parameter names, and evaluate(eng, prm, a, b), which
    returns (value, limit, pass), or (value, limit, pass, extra fields of its
    trace record), or None when the test is skipped (it then passes).
    `text`: the parameters are kept as text, not numbers. `check(params)`:
    a load-time message when the parameters are out of range, else None."""

    __slots__ = ("params", "evaluate", "text", "check")

    def __init__(self, params, evaluate, text=False, check=None):
        self.params = params
        self.evaluate = evaluate
        self.text = text
        self.check = check


def _distance(eng, prm, a, b):
    value, limit = eng._dist(a, b), prm["max_m"]
    return value, limit, value < limit


def _mahalanobis(eng, prm, a, b):
    value, limit = eng._d2(a, b), prm["gate"]
    return value, limit, value < limit


def _state(eng, prm, a, b):
    pb = eng._predict_in(b, a.last_time_ms, a)
    value, dof = state_statistic((a.east, a.north), a.t_var, pb, a.report.get("hae"),
                                 b.report.get("hae"), prm["hae_sigma_m"])
    limit = CHI2[prm["probability"]][dof - 4]
    return value, limit, value < limit, {"dof": dof}


def _state_check(prm):
    if prm["probability"] not in CHI2 or prm["hae_sigma_m"] <= 0:
        return "state needs probability one of %s and hae_sigma_m above 0" % ", ".join(
            str(x) for x in sorted(CHI2))
    return None


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
    k = prm["key"]
    va = a.env if k == "@env" else a.report.get(k)
    vb = b.env if k == "@env" else b.report.get(k)
    return va, vb, va == vb


TESTS = MappingProxyType({
    "distance": TestKind(("max_m",), _distance),
    "mahalanobis": TestKind(("gate",), _mahalanobis),
    "state": TestKind(("probability", "hae_sigma_m"), _state, check=_state_check),
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
    rec = _trace.record(stage, a.key, b.key, name, out[0], out[1], out[2])
    if len(out) > 3:
        rec.update(out[3])
    trace.append(rec)
    return out[2]


def run_same(eng, stage, tests, a, b, trace):
    """The categorical (`same`) tests of a stage only, in pack order,
    stopping at the first that fails (Association, Sequential test)."""
    for name, prm in tests:
        if name == "same" and not run_test(eng, stage, name, prm, a, b, trace):
            return False
    return True


def run_stage(eng, stage, tests, a, b, trace):
    """Tests, within a stage: in pack order, stopping at the first that fails."""
    for name, prm in tests:
        if not run_test(eng, stage, name, prm, a, b, trace):
            return False
    return True
