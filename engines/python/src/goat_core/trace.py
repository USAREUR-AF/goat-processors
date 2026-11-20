"""Trace records: one constructor per record shape, so that the key order
of every record (which the events file keeps) is written in one place.

spec/correlate.md and spec/correlate-assign.md, Trace; spec/filter.md,
spec/fuse.md and spec/quality.md, Trace. Pure functions."""


def record(stage, a, b, test, value, limit, ok, extra=None):
    """A correlate record: stage, a, b, test, value, limit, pass, then any
    extra keys in their order."""
    rec = {"stage": stage, "a": a, "b": b, "test": test, "value": value, "limit": limit, "pass": ok}
    if extra:
        rec.update(extra)
    return rec


def skipped(stage, a, b, test):
    """A correlate test that was skipped and passes."""
    return {"stage": stage, "a": a, "b": b, "test": test, "value": None, "limit": None,
            "pass": True, "skipped": True}


def bias(lo, hi, d2, gate, ok, st, timed):
    """correlate-assign.md, Trace: the bias offset record of one pair."""
    rec = {"stage": "bias", "a": lo, "b": hi, "test": "offset",
           "value": d2, "limit": gate, "pass": ok,
           "east": st[0][0], "north": st[1][0], "var": st[0][1],
           "pairs": st[2]}
    if timed:
        rec["time_offset_ms"] = st[3] * 1000.0
    return rec


def filter_rule(rule, entity, test, negated, value, limit, ok, unknown):
    """spec/filter.md, Trace: one condition of one rule."""
    rec = {"stage": "rule", "rule": rule, "entity": entity, "test": test,
           "negated": negated, "value": value, "limit": limit, "pass": ok}
    if unknown:
        rec["unknown"] = True
    return rec


def filter_forget(entity, age, limit, gone):
    """spec/filter.md, Trace: the age check of one entity at a tick."""
    return {"stage": "forget", "entity": entity, "test": "age", "value": age,
            "limit": limit, "pass": gone}


def fuse_intersect(group, member, w):
    """spec/fuse.md, Trace: one covariance intersection weight."""
    return {"stage": "intersect", "group": group, "member": member, "value": w}


def fuse_kinematics(group, method, candidates, winner):
    """spec/fuse.md, Trace: the kinematics of one group."""
    return {"stage": "kinematics", "group": group, "method": method,
            "candidates": candidates, "winner": winner}


def fuse_candidate(member, var, time_ms, rank):
    return {"member": member, "var": var, "time_ms": time_ms, "rank": rank}


def fuse_attribute(group, key, rule, candidates, winner, value):
    """spec/fuse.md, Trace: one attribute of one group."""
    return {"stage": "attribute", "group": group, "key": key, "rule": rule,
            "candidates": candidates, "winner": winner, "value": value}


def fuse_attribute_candidate(member, value, time_ms, rank):
    return {"member": member, "value": value, "time_ms": time_ms, "rank": rank}


def quality_sample(entity, sample, value, inputs):
    """spec/quality.md, Trace: one sample of one report."""
    return {"stage": "sample", "entity": entity, "sample": sample, "value": value,
            "inputs": inputs}


def quality_rule(rule, subject, measure, value, limit, ok, count, active):
    """spec/quality.md, Trace: one rule on one subject at a tick."""
    return {"stage": "rule", "rule": rule, "subject": subject,
            "measure": measure, "value": value, "limit": limit, "pass": ok,
            "count": count, "active": active}
