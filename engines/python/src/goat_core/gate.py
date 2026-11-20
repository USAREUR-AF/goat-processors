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
            d = abs(float(ca) - float(cb))
            value, limit = min(d, 360.0 - d), prm["max_deg"]
        else:
            slow, fast = sorted((float(sa), float(sb)))
            value = 0.0 if fast == 0 else abs(1.0 - slow / fast) * 100.0
            limit = prm["max_pct"]
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
