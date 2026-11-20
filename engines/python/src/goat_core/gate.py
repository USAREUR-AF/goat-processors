"""The correlate tests (spec/correlate.md, Tests): distance, window,
mahalanobis, course, speed, altitude, same.

A test compares entity A, the one just reported, with entity B predicted to
A's time. `run_test` writes its trace record and returns whether it passed."""

import math

from .model import environment

TESTS = {
    "distance": ("max_m",),
    "window": ("multiplier", "window_m", "err_min_m", "err_max_m"),
    "mahalanobis": ("gate",),
    "course": ("max_deg", "min_speed_ms"),
    "speed": ("max_pct", "min_speed_ms"),
    "altitude": ("max_m",),
    "same": ("key",),
}


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


def run_test(eng, stage, name, prm, a, b, trace):
    rec = {"stage": stage, "a": a.key, "b": b.key, "test": name}
    ra, rb = a.report, b.report
    if name == "distance":
        value, limit = eng._dist(a, b), prm["max_m"]
        ok = value < limit
    elif name == "window":
        lo, hi = prm["err_min_m"], prm["err_max_m"]
        ea = min(max(a.ce(eng.pack), lo), hi)
        eb = min(max(b.ce(eng.pack), lo), hi)
        value = eng._dist(a, b)
        limit = prm["multiplier"] * math.sqrt(ea * ea + eb * eb) + prm["window_m"]
        ok = value < limit
    elif name == "mahalanobis":
        value, limit = eng._d2(a, b), prm["gate"]
        ok = value < limit
    elif name in ("course", "speed"):
        ca, cb = ra.get("course"), rb.get("course")
        sa, sb = ra.get("speed_ms"), rb.get("speed_ms")
        need = (sa, sb) if name == "speed" else (ca, cb, sa, sb)
        if any(x is None for x in need) or float(sa) < prm["min_speed_ms"] or float(sb) < prm["min_speed_ms"]:
            rec.update(value=None, limit=None, **{"pass": True, "skipped": True})
            trace.append(rec)
            return True
        if name == "course":
            value, limit = course_difference(float(ca), float(cb)), prm["max_deg"]
        else:
            value, limit = speed_difference_pct(float(sa), float(sb)), prm["max_pct"]
        ok = value <= limit
    elif name == "altitude":
        ha, hb = ra.get("hae"), rb.get("hae")
        if ha is None or hb is None:
            rec.update(value=None, limit=None, **{"pass": True, "skipped": True})
            trace.append(rec)
            return True
        value, limit = abs(float(ha) - float(hb)), prm["max_m"]
        ok = value <= limit
    elif name == "same":
        k = prm["key"]
        va = environment(ra) if k == "@env" else ra.get(k)
        vb = environment(rb) if k == "@env" else rb.get(k)
        value, limit, ok = va, vb, va == vb
    else:
        raise AssertionError(name)
    rec.update(value=value, limit=limit, **{"pass": ok})
    trace.append(rec)
    return ok


def run_stage(eng, stage, tests, a, b, trace):
    """Tests, within a stage: in pack order, stopping at the first that fails."""
    for name, prm in tests:
        if not run_test(eng, stage, name, prm, a, b, trace):
            return False
    return True
