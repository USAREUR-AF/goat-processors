"""Prototype methods for the research harness (README.md).

Each prototype is a subclass of the Python reference engine of
engines/python. It changes only what the method needs and leaves the engine
itself untouched. A prototype is evidence for a decision, not an engine: an
ADOPTED method reaches the engines only through a spec and vectors.

VARIANTS maps a variant name to (pack directory name, engine class, options).
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "engines", "python", "src"))
from goat_correlator.engine import AssignEngine as _AssignEngine, Engine as _Engine  # noqa: E402


# The reference engines, taking the options a prototype passes down the chain.
class AssignEngine(_AssignEngine):
    def __init__(self, pack, **opt):
        super().__init__(pack)


class Engine(_Engine):
    def __init__(self, pack, **opt):
        super().__init__(pack)


# ---------------------------------------------------------------------------
# Prototype 1: measurement-noise scale per source, from the source's own
# filter innovations (covariance matching).
#
# A source that understates its position error (or reports none, so the pack
# default stands in) is weighted too heavily in every fused estimate, and its
# gates are too tight: its tracks fall out of their system tracks and back
# in. The innovation of a track's own filter, y = z - p_pred, has expected
# square pp_pred + R_true on each axis. So over a source's reports
#     lambda = (nu0 + sum((y^2 - pp_pred) / r0)) / (nu0 + n)
# estimates R_true / r0, the factor by which the stated variance r0 is too
# small. nu0 is the weight of the prior lambda = 1, in pseudo-innovations.
# The report's stated variance is then scaled by lambda, clamped to
# [lam_min, lam_max]. A constant sensor bias does not enter y (the filter
# follows it), and a clock error moves every report alike, so this measures
# random error only. Reports that fail the restart test (a track number
# moved to another object) are left out.

class NoiseScaleMixin:
    NU0 = 10.0
    LAM_MIN = 1.0
    LAM_MAX = 25.0

    def __init__(self, pack, **opt):
        super().__init__(pack, **opt)
        self.nu0 = opt.get("nu0", self.NU0)
        self.lam_min = opt.get("lam_min", self.LAM_MIN)
        self.lam_max = opt.get("lam_max", self.LAM_MAX)
        self.noise = {}   # source -> [sum of (y^2 - pp)/r0, count of axis samples]

    def scale(self, source):
        st = self.noise.get(source)
        if st is None:
            return 1.0
        lam = (self.nu0 + st[0]) / (self.nu0 + st[1])
        return min(self.lam_max, max(self.lam_min, lam))

    def _accept(self, report, events, trace):
        src = report.get("track.source_id")
        if src is None or report.get("lat") is None or report.get("time_ms") is None:
            return super()._accept(report, events, trace)
        src = str(src)
        lam = self.scale(src)
        ce0 = report.get("ce")
        ce0 = self.pack.filter["default_ce_m"] if ce0 is None else float(ce0)
        rep = dict(report)
        rep["ce"] = ce0 * math.sqrt(lam)
        key = src + "/" + str(report.get("uid"))
        ent = self.entities.get(key)
        pre = None
        if ent is not None and self.ref is not None and key not in self.retiring \
                and int(report["time_ms"]) >= ent.last_time_ms:
            pr = self._predict(ent, int(report["time_ms"]))
            z = self._to_plane(float(report["lat"]), float(report["lon"]))
            pre = (pr, z)
        start = len(trace)
        out = super()._accept(rep, events, trace)
        if out is None or pre is None:
            return out
        if any(r.get("test") == "restart" and not r["pass"] for r in trace[start:]):
            return out
        pr, z = pre
        st = self.noise.setdefault(src, [0.0, 0])
        for x in (0, 1):
            r0 = ce0 * ce0 + out.t_var[x]
            y = z[x] - pr[x][0]
            st[0] += (y * y - pr[x][2]) / r0
            st[1] += 1
        trace.append({"stage": "filter", "a": key, "b": src, "test": "noise_scale",
                      "value": self.scale(src), "limit": None, "pass": True})
        return out


class NoiseScaleAssign(NoiseScaleMixin, AssignEngine):
    pass


class NoiseScaleConfirm(NoiseScaleMixin, Engine):
    pass


# ---------------------------------------------------------------------------
# Prototype 2: track succession (track-segment association).
#
# When a sensor drops a track and starts a new number for the same object,
# the old number stays a member of its system track until it goes stale, and
# while it is there the source already has a member, so the new number cannot
# join. A member is *overdue* when it has not reported for more than `factor`
# times its source's median update interval. An overdue member does not
# block its source: the system track is a column for the source's new
# numbers, scored on its other members, and a new number that joins it takes
# the overdue member's place (the overdue member leaves, reason
# `succeeded`). An overdue member that nobody replaces stays until its
# ordinary staleness.

class SuccessionMixin:
    FACTOR = 2.5
    SAMPLES = 9

    def __init__(self, pack, **opt):
        super().__init__(pack, **opt)
        self.factor = opt.get("factor", self.FACTOR)
        self.samples = opt.get("samples", self.SAMPLES)
        self.intervals = {}  # source -> recent intervals, oldest first
        self._now = None
        self._overdue = {}

    def ingest(self, report):
        key = None
        if report.get("track.source_id") is not None:
            key = str(report["track.source_id"]) + "/" + str(report.get("uid"))
        before = self.entities[key].last_time_ms if key in self.entities else None
        events, trace = super().ingest(report)
        ent = self.entities.get(key)
        if ent is not None and before is not None and ent.last_time_ms > before \
                and not any(e.get("ev") == "reject" for e in events):
            iv = self.intervals.setdefault(ent.source, [])
            iv.append(ent.last_time_ms - before)
            del iv[:-self.samples]
        return events, trace

    def _is_overdue(self, ent):
        iv = self.intervals.get(ent.source)
        if not iv or self._now is None:
            return False
        s = sorted(iv)
        med = s[(len(s) - 1) // 2]   # the lower median, as correlate 1.0's stale_rate
        return self._now - ent.last_time_ms > self.factor * med

    def tick(self, now_ms):
        self._now = now_ms
        return super().tick(now_ms)

    def _entries(self, source, rows, mem, tag, trace):
        rowset = set(rows)
        self._overdue = {}
        hidden = {}
        for s in mem.order:
            others = [m for m in mem.systems[s] if m not in rowset]
            same = [m for m in others if self.entities[m].source == source]
            rest = [m for m in others if self.entities[m].source != source]
            if same and rest and all(self._is_overdue(self.entities[m]) for m in same):
                hidden[s] = same
        if not hidden:
            return super()._entries(source, rows, mem, tag, trace)
        # Score the column on its other members only: hide the overdue ones.
        saved = {s: list(mem.systems[s]) for s in hidden}
        for s, same in hidden.items():
            mem.systems[s] = [m for m in mem.systems[s] if m not in same]
        try:
            columns, matrix = super()._entries(source, rows, mem, tag, trace)
        finally:
            for s, members in saved.items():
                mem.systems[s] = members
        self._overdue = hidden
        return columns, matrix

    def _apply(self, rows, cols, columns, mem, events):
        c = len(columns)
        for i in range(len(rows)):
            j = cols[i]
            if j < c and columns[j][0] in self._overdue and mem.system_of(rows[i]) != columns[j][0]:
                for m in self._overdue[columns[j][0]]:
                    if mem.system_of(m) == columns[j][0]:
                        mem.leave(m, "succeeded", events)
        _AssignEngine._apply(rows, cols, columns, mem, events)


class SuccessionAssign(SuccessionMixin, AssignEngine):
    pass


class NoiseSuccessionAssign(SuccessionMixin, NoiseScaleMixin, AssignEngine):
    pass


# ---------------------------------------------------------------------------
# Prototype 3: fast covariance intersection for the fused estimate.
#
# The assign method fuses a system track's members by inverse-variance
# weights, which assumes their errors are independent. Covariance
# intersection makes no such assumption: P^-1 = sum(w_i / P_i),
# x = P * sum(w_i * x_i / P_i), with weights summing to 1. The fast form
# takes w_i proportional to 1 / trace(P_i), here 1 / pp_i for position and
# 1 / vv_i for velocity on each axis. `where` is "output" (the system event
# only) or "all" (the cost as well).

class FastCiMixin:
    def __init__(self, pack, **opt):
        super().__init__(pack, **opt)
        self.ci_where = opt.get("where", "all")

    def _fused(self, members, t, frame=None):
        if frame is not None and self.ci_where == "output":
            return super()._fused(members, t, frame)
        preds = [self._predict(self.entities[k], t) if frame is None
                 else self._predict_in(self.entities[k], t, frame) for k in members]
        res = []
        for x in (0, 1):
            out = []
            for vi, ci in ((0, 2), (1, 4)):
                wsum = 0.0
                for pr in preds:
                    wsum += 1.0 / pr[x][ci]
                inv, acc = 0.0, 0.0
                for pr in preds:
                    w = (1.0 / pr[x][ci]) / wsum
                    inv += w / pr[x][ci]
                    acc += w * pr[x][vi] / pr[x][ci]
                var = 1.0 / inv
                out.append((var * acc, var))
            res.append((out[0][0], out[0][1], out[1][0], out[1][1]))
        return res


class FastCiAssign(FastCiMixin, AssignEngine):
    pass


# ---------------------------------------------------------------------------
# The registry. A variant without an engine class runs the reference engine.

VARIANTS = {
    # Baselines: the packs as they are on main.
    "assign-time": ("correlate-assign-time", None, {}),
    "assign-full": ("correlate-assign-full", None, {}),
    "gnn-imm": ("correlate-gnn-imm", None, {}),
    # Prototype 1.
    "assign-time+noise": ("correlate-assign-time", NoiseScaleAssign, {}),
    "assign-time+noise2way": ("correlate-assign-time", NoiseScaleAssign, {"lam_min": 0.04}),
    "assign-time+noise-nu30": ("correlate-assign-time", NoiseScaleAssign, {"nu0": 30.0}),
    "gnn-imm+noise": ("correlate-gnn-imm", NoiseScaleConfirm, {}),
    # Prototype 2.
    "assign-time+succ": ("correlate-assign-time", SuccessionAssign, {}),
    "assign-time+succ2": ("correlate-assign-time", SuccessionAssign, {"factor": 2.0}),
    "assign-time+succ3": ("correlate-assign-time", SuccessionAssign, {"factor": 3.0}),
    "assign-time+succ4": ("correlate-assign-time", SuccessionAssign, {"factor": 4.0}),
    # Prototype 3.
    "assign-time+ci": ("correlate-assign-time", FastCiAssign, {"where": "all"}),
    "assign-time+ci-out": ("correlate-assign-time", FastCiAssign, {"where": "output"}),
    # Prototypes 1 and 2 together.
    "assign-time+noise+succ": ("correlate-assign-time", NoiseSuccessionAssign, {}),
}
