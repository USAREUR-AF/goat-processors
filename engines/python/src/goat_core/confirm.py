"""Correlate, method confirm (spec/correlate.md, Association, Events,
Snapshot): a pair is grouped after passing its gate and confirm tests on
confirm_count reports in a row, or, with sprt, when its log-likelihood ratio
reaches the upper bound; a member leaves after hold_failures failed hold
tests, or with sprt when its link's ratio falls to the lower bound, or when
stale; output fused, by priority or latest."""

import math

from . import estimate
from . import snapshot as _snapshot
from .tracks import Correlator
from .gate import run_same, run_test
from .model import course_deg


def sprt_bounds(sp):
    """Association, Sequential test: (ln A, ln B) from the false and missed
    association probabilities."""
    return (math.log((1.0 - sp["missed"]) / sp["false"]),
            math.log(sp["missed"] / (1.0 - sp["false"])))


def sprt_step(fa, ta, pb, ha, hb, sp):
    """Association, Sequential test: the full-state d2 under "same object"
    (covariance S per axis) and the log-likelihood ratio increment against
    "different objects" (S + diag(pos_m^2, vel_ms^2)), plus the height term
    when both report hae. fa, ta, pb as gate.state_statistic. Returns (d2,
    increment)."""
    p0, v0 = sp["pos_m"] ** 2, sp["vel_ms"] ** 2
    q1 = 0.0
    lam = 0.0
    for x in (0, 1):
        a, px = fa[x], pb[x]
        dp = a[0] - px[0]
        dv = a[1] - px[1]
        spp = a[2] + ta[x] + px[2]
        spv = a[3] + px[3]
        svv = a[4] + px[4]
        det = spp * svv - spv * spv
        qa = (svv * dp * dp - 2.0 * spv * dp * dv + spp * dv * dv) / det
        tpp, tvv = spp + p0, svv + v0
        det0 = tpp * tvv - spv * spv
        qb = (tvv * dp * dp - 2.0 * spv * dp * dv + tpp * dv * dv) / det0
        q1 += qa
        lam += 0.5 * (qb - qa) + 0.5 * math.log(det0 / det)
    if ha is not None and hb is not None:
        dh = float(ha) - float(hb)
        h1 = 2.0 * sp["hae_sigma_m"] ** 2
        h0 = h1 + p0
        q1 += dh * dh / h1
        lam += 0.5 * (dh * dh / h0 - dh * dh / h1) + 0.5 * math.log(h0 / h1)
    return q1, lam


class ConfirmEngine(Correlator):
    def __init__(self, pack):
        super().__init__(pack)
        self.groups = {}
        self.group_order = []
        self.counts = {}
        self.llr = {}
        self.next_group = 1
        self._bounds = sprt_bounds(pack.sprt) if pack.sprt is not None else None
        # With sprt the gate and the sequential test predict the same pair:
        # each prediction is kept for the rest of one ingest. A memo, not
        # state: never in snapshot().
        self._memo = None

    def _predict_in(self, b, t, a):
        memo = self._memo
        if memo is None:
            return Correlator._predict_in(self, b, t, a)
        k = (b.key, t)
        pr = memo.get(k)
        if pr is None:
            pr = memo[k] = Correlator._predict_in(self, b, t, a)
        return pr

    def _sprt_update(self, a, b, gate_ok, trace):
        """Association, Sequential test: one report's evidence added to the
        pair's ratio, clamped to [ln B, ln A]; the lower bound when a gate
        test failed. Returns the new value."""
        up, lo = self._bounds
        pk = self._pair(a.key, b.key)
        old = self.llr.get(pk, 0.0)
        if gate_ok:
            q1, lam = sprt_step((a.east, a.north), a.t_var, self._predict_in(b, a.last_time_ms, a),
                                a.report.get("hae"), b.report.get("hae"), self.pack.sprt)
            new = min(max(old + lam, lo), up)
        else:
            q1, lam, new = None, None, lo
        self.llr[pk] = new
        trace.append({"stage": "sprt", "a": a.key, "b": b.key, "test": "llr", "value": new,
                      "limit": up, "pass": new >= up, "lower": lo, "increment": lam, "d2": q1})
        return new

    def _hold_ok(self, stage_tests, a, b, trace):
        ok = True
        for name, prm in stage_tests:
            if not run_test(self, "hold", name, prm, a, b, trace):
                ok = False
                break
        return ok

    def _leave(self, ent, reason, events):
        g = ent.group
        members = self.groups[g]
        members.remove(ent.key)
        ent.group = None
        ent.hold_failures = 0
        events.append({"ev": "leave", "group": g, "entity": ent.key, "reason": reason})
        if len(members) == 1:
            last = members[0]
            self.entities[last].group = None
            self.entities[last].hold_failures = 0
            del self.groups[g]
            self.group_order.remove(g)
            events.append({"ev": "dissolve", "group": g, "entity": last})

    def _group_has_source(self, g, source):
        return any(self.entities[k].source == source for k in self.groups[g])

    def ingest(self, report):
        events, trace = [], []
        if self._bounds is not None:
            self._memo = {}
        try:
            return self._ingest(report, events, trace)
        finally:
            self._memo = None

    def _ingest(self, report, events, trace):
        ent = self._accept(report, events, trace)
        if ent is None:
            return events, trace
        key, source = ent.key, ent.source

        if ent.group is not None and self._bounds is not None:
            # The link: the other member whose pair ratio is highest (no
            # ratio reads 0; ties to key order). Only that pair is updated.
            lo = self._bounds[1]
            link = None
            for k in sorted(self.groups[ent.group]):
                if k == key:
                    continue
                v = self.llr.get(self._pair(key, k), 0.0)
                if link is None or v > link[0]:
                    link = (v, k)
            b = self.entities[link[1]]
            ok = run_same(self, "gate", self.pack.gate, ent, b, trace)
            if self._sprt_update(ent, b, ok, trace) <= lo:
                self._leave(ent, "release", events)
                for pk in [pk for pk in self.llr if key in pk.split("|") and self.llr[pk] <= lo]:
                    del self.llr[pk]
            return events, trace

        if ent.group is not None:
            ok = False
            for k in sorted(self.groups[ent.group]):
                if k == key:
                    continue
                if self._hold_ok(self.pack.hold, ent, self.entities[k], trace):
                    ok = True
                    break
            if ok:
                ent.hold_failures = 0
            else:
                ent.hold_failures += 1
                if ent.hold_failures >= self.pack.hold_failures:
                    self._leave(ent, "hold", events)
            return events, trace

        allow = self.pack.same_source == "allow"
        ready = []
        for k in sorted(self.entities):
            if k == key:
                continue
            b = self.entities[k]
            if not allow:
                if b.source == source:
                    continue
                if b.group is not None and self._group_has_source(b.group, source):
                    continue
            pk = self._pair(key, k)
            ok = self._run_stage("gate", ent, b, trace) and self._run_stage("confirm", ent, b, trace)
            if self._bounds is not None:
                if not ok:
                    if pk not in self.llr:
                        continue
                    ok = run_same(self, "gate", self.pack.gate, ent, b, [])
                new = self._sprt_update(ent, b, ok, trace)
                if new <= self._bounds[1]:
                    del self.llr[pk]
                if new >= self._bounds[0]:
                    ready.append(b)
                continue
            c = self.counts.get(pk, 0) + 1 if ok else 0
            self.counts[pk] = c
            trace.append({"stage": "confirm", "a": key, "b": k, "test": "count",
                          "value": c, "limit": self.pack.confirm_count,
                          "pass": c >= self.pack.confirm_count})
            if c >= self.pack.confirm_count:
                ready.append(b)
        if ready:
            best, best_d2 = None, None
            for b in ready:
                d2 = self._d2(ent, b)
                trace.append({"stage": "rank", "a": key, "b": b.key, "test": "rank",
                              "value": d2, "limit": None, "pass": True})
                if best is None or d2 < best_d2:
                    best, best_d2 = b, d2
            if self._bounds is None:
                self.counts[self._pair(key, best.key)] = 0
            if best.group is not None:
                ent.group = best.group
                self.groups[best.group].append(key)
                self.groups[best.group].sort()
                events.append({"ev": "join", "group": best.group, "entity": key})
            else:
                g = "g%d" % self.next_group
                self.next_group += 1
                self.groups[g] = sorted([key, best.key])
                self.group_order.append(g)
                ent.group = best.group = g
                ent.hold_failures = best.hold_failures = 0
                events.append({"ev": "correlate", "group": g, "members": list(self.groups[g])})
        return events, trace

    def tick(self, now_ms):
        events, trace = [], []
        limits = {}
        fixed = self.pack.stale_ms if self.pack.stale_rate is None else None
        for k in sorted(self.entities):
            ent = self.entities[k]
            lim = fixed
            if lim is None:
                lim = limits.get(ent.source)
                if lim is None:
                    lim = limits[ent.source] = self._stale_limit(ent.source)
            stale = now_ms - ent.last_time_ms > lim
            sm = ent.report.get("stale_ms")
            if sm is not None and now_ms >= int(sm):
                stale = True
            if not stale:
                continue
            if ent.group is not None:
                self._leave(ent, "stale", events)
            del self.entities[k]
            for pk in [pk for pk in self.counts if k in pk.split("|")]:
                del self.counts[pk]
            for pk in [pk for pk in self.llr if k in pk.split("|")]:
                del self.llr[pk]
            events.append({"ev": "drop", "entity": k})
        for g in self.group_order:
            members = self.groups[g]
            if self.pack.output == "fused":
                events.append(self._fused_event(g, members, now_ms))
                continue
            if self.pack.output == "priority":
                primary = min(members, key=lambda m: (self.pack.priority.get(self.entities[m].source, 100), m))
            else:
                primary = min(members, key=lambda m: (-self.entities[m].last_time_ms, m))
            p = self.entities[primary]
            pe, pn = self._predict(p, now_ms)
            lat, lon = self._to_deg(pe[0], pn[0])
            course = course_deg(pe[1], pn[1])
            ev = {"ev": "fused", "group": g, "primary": primary, "members": list(members),
                  "lat": lat, "lon": lon, "course": course, "speed_ms": math.hypot(pe[1], pn[1])}
            if p.report.get("hae") is not None:
                ev["hae"] = float(p.report["hae"])
            events.append(ev)
        return events, trace

    def _fused_event(self, g, members, now_ms):
        """Output `fused`: per axis the inverse-variance combination of the
        members' predictions to now_ms, members in key order; hae of the
        member that reported it last."""
        acc = [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]
        hae, hae_t = None, None
        f = self.pack.filter
        for m in members:
            e = self.entities[m]
            dt = (now_ms - e.last_time_ms) / 1000.0
            q = f["accel_var"] if e.models is None else (f["accel_var"], self.pack.maneuver["accel_var"])
            for x, a in enumerate(estimate.predict_out(e.east, e.north, e.models, e.mode, dt, q)):
                o = acc[x]
                o[0] += 1.0 / a[2]
                o[1] += a[0] / a[2]
                o[2] += 1.0 / a[3]
                o[3] += a[1] / a[3]
            if e.report.get("hae") is not None and (hae_t is None or e.last_time_ms > hae_t):
                hae, hae_t = float(e.report["hae"]), e.last_time_ms
        pe = acc[0][1] / acc[0][0]
        pn = acc[1][1] / acc[1][0]
        ve = acc[0][3] / acc[0][2]
        vn = acc[1][3] / acc[1][2]
        lat, lon = self._to_deg(pe, pn)
        ev = {"ev": "fused", "group": g, "primary": None, "members": list(members),
              "lat": lat, "lon": lon, "course": course_deg(ve, vn), "speed_ms": math.hypot(ve, vn)}
        if hae is not None:
            ev["hae"] = hae
        return ev

    def snapshot(self):
        return _snapshot.confirm(self)
