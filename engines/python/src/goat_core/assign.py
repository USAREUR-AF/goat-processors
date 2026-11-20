"""Correlate, method assign (spec/correlate-assign.md): every track in one
system track; per source, the exact least-cost assignment at each tick,
ranked and kept over a window of ticks; sensor bias and time offset per
pair of sources; fused estimate by inverse-variance weights."""

import math

from . import bias as _bias
from . import estimate
from . import snapshot as _snapshot
from . import trace as _trace
from .tracks import Correlator
from .model import course_deg
from .ranking import INF, assignment_total, ranked_assignments


class _Members:
    """One membership picture: system tracks, their creation order, the counter."""

    def __init__(self):
        self.systems = {}
        self.order = []
        self.next = 1

    def copy(self):
        m = _Members()
        m.systems = {s: list(v) for s, v in self.systems.items()}
        m.order = list(self.order)
        m.next = self.next
        return m

    def system_of(self, key):
        for s in self.order:
            if key in self.systems[s]:
                return s
        return None

    def leave(self, key, reason, events):
        s = self.system_of(key)
        self.systems[s].remove(key)
        events.append({"ev": "leave", "system": s, "entity": key, "reason": reason})
        if not self.systems[s]:
            del self.systems[s]
            self.order.remove(s)
            events.append({"ev": "end", "system": s})

    def snap(self):
        return {s: list(self.systems[s]) for s in self.order}


class _Record:
    """One pending tick of one history."""

    def __init__(self, cost, choices, events, members):
        self.cost = cost
        self.choices = choices
        self.events = events
        self.members = members


class _History:
    def __init__(self, records):
        self.records = records

    def total(self):
        t = 0.0
        for r in self.records:
            t += r.cost
        return t


class AssignEngine(Correlator):
    """spec/correlate-assign.md: every track in one system track; per-source
    exact assignment at each tick, ranked and kept over a window of ticks;
    fused estimate by inverse-variance weights."""

    keeps_restarts = True

    def __init__(self, pack):
        super().__init__(pack)
        self.committed = _Members()
        self.histories = [_History([])]
        self.reported = set()
        self.bias = {}
        # During a tick no filter and (until the bias update) no bias
        # changes: each prediction and pair test value is computed once per
        # tick. None outside a tick. A memo, not state: never in snapshot().
        self._memo = None

    def _predict(self, ent, t):
        memo = self._memo
        if memo is None:
            return Correlator._predict(self, ent, t)
        key = ("p", ent.key, t)
        pr = memo.get(key)
        if pr is None:
            pr = memo[key] = Correlator._predict(self, ent, t)
        return pr

    def _d2(self, a, b):
        memo = self._memo
        if memo is None:
            return Correlator._d2(self, a, b)
        key = ("d2", a.key, b.key)
        v = memo.get(key)
        if v is None:
            v = memo[key] = Correlator._d2(self, a, b)
        return v

    def _dist(self, a, b):
        memo = self._memo
        if memo is None:
            return Correlator._dist(self, a, b)
        key = ("dist", a.key, b.key)
        v = memo.get(key)
        if v is None:
            v = memo[key] = Correlator._dist(self, a, b)
        return v

    def ingest(self, report):
        events, trace = [], []
        ent = self._accept(report, events, trace)
        if ent is not None:
            self.reported.add(ent.key)
        return events, trace

    def _offset(self, src, dst, vel):
        """Per axis (shift, variance) that moves a position of source src, with
        velocity vel, into the frame of source dst, or None."""
        if self.pack.bias is None or src == dst:
            return None
        return _bias.offset(self.bias.get(self._pair(src, dst)), self.pack.bias,
                            self.pack.time_offset is not None, src < dst, vel)

    def _predict_in(self, b, t, a):
        pr = estimate.with_variance(self._predict(b, t), b.t_var)
        off = self._offset(b.source, a if isinstance(a, str) else a.source, (pr[0][1], pr[1][1]))
        return pr if off is None else _bias.shifted(pr, off)

    def _fused(self, members, t, frame=None):
        """Fused estimate: per axis [p, v, pp, 0, vv] at time t; with `frame`
        (an entity), each member is first moved into that entity's frame."""
        if frame is None:
            preds = [self._predict(self.entities[k], t) for k in members]
        else:
            preds = [self._predict_in(self.entities[k], t, frame) for k in members]
        return estimate.inverse_variance(preds)

    def _cost(self, a, members):
        return assignment_cost(a.east, a.north, a.t_var, self._fused(members, a.last_time_ms, a))

    def _stale(self, ent, now_ms):
        if now_ms - ent.last_time_ms > self.pack.stale_ms:
            return True
        sm = ent.report.get("stale_ms")
        return sm is not None and now_ms >= int(sm)

    def _entries(self, source, rows, mem, tag, trace):
        """Columns, entries and the matrix of one source against one membership."""
        rowset = set(rows)
        columns = []
        for s in mem.order:
            others = [m for m in mem.systems[s] if m not in rowset]
            if others and all(self.entities[m].source != source for m in others):
                columns.append((s, sorted(others)))
        n, c = len(rows), len(columns)
        matrix, entries = [], []
        for i, k in enumerate(rows):
            a = self.entities[k]
            own = mem.system_of(k)
            row, rec = [], []
            for s, others in columns:
                ok = True
                for m in others:
                    if not self._gate(a, self.entities[m], tag, trace):
                        ok = False
                        break
                if ok:
                    cost = self._cost(a, others)
                    if own == s:
                        cost -= self.pack.keep_bonus
                    row.append(cost)
                    rec.append((s, cost))
                else:
                    row.append(INF)
                    rec.append((s, None))
            alone = self.pack.new_cost
            if own is not None and mem.systems[own] == [k]:
                alone -= self.pack.keep_bonus
            row.extend(alone if j == i else INF for j in range(n))
            rec.append(("alone", alone))
            matrix.append(row)
            entries.append(rec)
        for k, rec in zip(rows, entries):
            for b, cost in rec:
                trace.append(dict({"stage": "assign", "a": k, "b": b, "test": "cost",
                                   "value": cost, "limit": None, "pass": cost is not None}, **tag))
        return columns, matrix

    def _gate(self, a, b, tag, trace):
        start = len(trace)
        ok = self._run_stage("gate", a, b, trace)
        if tag:
            for r in trace[start:]:
                r.update(tag)
        return ok

    @staticmethod
    def _apply(rows, cols, columns, mem, events):
        """correlate-assign.md, Assignment step 4, on one membership picture."""
        c = len(columns)
        for i, k in enumerate(rows):
            j = cols[i]
            cur = mem.system_of(k)
            if j < c:
                target = columns[j][0]
                if cur == target:
                    continue
                if cur is not None:
                    mem.leave(k, "assign", events)
                mem.systems[target].append(k)
                mem.systems[target].sort()
                events.append({"ev": "join", "system": target, "entity": k})
            else:
                if cur is not None and mem.systems[cur] == [k]:
                    continue
                if cur is not None:
                    mem.leave(k, "assign", events)
                s = "s%d" % mem.next
                mem.next += 1
                mem.systems[s] = [k]
                mem.order.append(s)
                events.append({"ev": "start", "system": s, "entity": k})

    def _latest(self, h):
        return h.records[-1].members if h.records else self.committed

    def tick(self, now_ms):
        self._memo = {}
        try:
            return self._tick(now_ms)
        finally:
            self._memo = None

    def _tick(self, now_ms):
        events, trace = [], []
        window, k_max = self.pack.window, self.pack.hypotheses
        multi = window > 1

        # Staleness: one decision for every history, recorded in each.
        stale = [k for k in sorted(self.entities)
                 if k not in self.retiring and self._stale(self.entities[k], now_ms)]
        moved = sorted(k for k in self.restarted if k not in stale)
        self.restarted = set()
        for h in self.histories:
            mem = self._latest(h).copy()
            evs = []
            for k in stale:
                if mem.system_of(k) is not None:
                    mem.leave(k, "stale", evs)
                evs.append({"ev": "drop", "entity": k})
            for k in moved:
                if mem.system_of(k) is not None:
                    mem.leave(k, "restart", evs)
            h.records = h.records + [_Record(0.0, [], evs, mem)]
        self.retiring.update(stale)
        self.reported.difference_update(stale)

        # Assignment, per source in key order, extending every history.
        tick_rows = set(self.reported)
        by_source = {}
        for k in sorted(self.reported):
            by_source.setdefault(self.entities[k].source, []).append(k)
        self.reported = set()
        for source in sorted(by_source):
            rows = by_source[source]
            cands = []
            for hi, h in enumerate(self.histories):
                tag = {"h": hi} if multi else {}
                rec = h.records[-1]
                columns, matrix = self._entries(source, rows, rec.members, tag, trace)
                c = len(columns)
                ranked = ranked_assignments(matrix, c, k_max)
                for r, cols in enumerate(ranked):
                    rtag = dict(tag, r=r) if multi else {}
                    for i, key in enumerate(rows):
                        j = cols[i]
                        b = columns[j][0] if j < c else "alone"
                        trace.append(dict({"stage": "assign", "a": key, "b": b, "test": "choice",
                                           "value": matrix[i][j], "limit": None, "pass": True}, **rtag))
                    mem = rec.members.copy()
                    evs = list(rec.events)
                    self._apply(rows, cols, columns, mem, evs)
                    choices = rec.choices + [[key, columns[cols[i]][0] if cols[i] < c else "alone"]
                                             for i, key in enumerate(rows)]
                    nh = _History(h.records[:-1] + [_Record(rec.cost + assignment_total(matrix, cols),
                                                            choices, evs, mem)])
                    cands.append((nh.total(), hi, r, nh))
            cands.sort(key=lambda e: (e[0], e[1], e[2]))
            cut = None if self.pack.margin is None else cands[0][0] + self.pack.margin
            kept = [pos < k_max and (cut is None or e[0] <= cut) for pos, e in enumerate(cands)]
            if multi:
                for pos, (tot, hi, r, _) in enumerate(cands):
                    rec = {"stage": "history", "a": hi, "b": r, "test": "total",
                           "value": tot, "limit": cut, "pass": kept[pos]}
                    trace.append(rec)
            self.histories = [e[3] for e, k in zip(cands, kept) if k]

        # Commit the oldest tick of the best history once the window is full.
        best = self.histories[0]
        if len(best.records) == window:
            done = best.records[0]
            survivors = []
            for h in self.histories:
                agree = h.records[0].choices == done.choices
                if multi:
                    trace.append({"stage": "history", "a": self.histories.index(h), "b": None,
                                  "test": "commit", "value": h.total(), "limit": None, "pass": agree})
                if agree:
                    survivors.append(_History(h.records[1:]))
            events.extend(done.events)
            self.committed = done.members
            for ev in done.events:
                if ev["ev"] == "drop":
                    del self.entities[ev["entity"]]
                    self.retiring.discard(ev["entity"])
            self.histories = survivors
            for key, ent in self.entities.items():
                ent.system = self.committed.system_of(key)

        if self.pack.bias is not None:
            # the bias changes here: the pair values computed before it are
            # not valid after it (predictions are)
            self._memo = {k: v for k, v in self._memo.items() if k[0] == "p"}
            self._bias_update(now_ms, tick_rows, trace)

        # Output: committed system tracks (with a margin, the best history's
        # latest membership), then the best history's memberships.
        shown = self._latest(self.histories[0]) if self.pack.margin is not None else self.committed
        for s in shown.order:
            members = shown.systems[s]
            fe, fn = self._fused(members, now_ms)
            lat, lon = self._to_deg(fe[0], fn[0])
            course = course_deg(fe[1], fn[1])
            ev = {"ev": "system", "system": s, "members": list(members),
                  "lat": lat, "lon": lon, "course": course, "speed_ms": math.hypot(fe[1], fn[1])}
            best_e = None
            for m in members:
                e = self.entities[m]
                if e.report.get("hae") is not None and (best_e is None or e.last_time_ms > best_e.last_time_ms):
                    best_e = e
            if best_e is not None:
                ev["hae"] = float(best_e.report["hae"])
            events.append(ev)
        if multi:
            mem = self._latest(self.histories[0])
            for s in mem.order:
                events.append({"ev": "provisional", "system": s, "members": list(mem.systems[s])})
        return events, trace

    def _bias_update(self, now_ms, rows, trace):
        """Sensor bias: every pair of members of one committed system track,
        from two sources, one of which reported."""
        prm = self.pack.bias
        timed = self.pack.time_offset is not None
        for s in self.committed.order:
            members = [m for m in self.committed.systems[s] if m not in self.retiring]
            for i in range(len(members)):
                for j in range(i + 1, len(members)):
                    a, b = self.entities[members[i]], self.entities[members[j]]
                    if a.source == b.source or (a.key not in rows and b.key not in rows):
                        continue
                    lo, hi = (a, b) if a.source < b.source else (b, a)
                    key = self._pair(a.source, b.source)
                    st = self.bias.get(key)
                    if st is None:
                        st = _bias.prior(prm, timed)
                    d2, ys, rs, vs = _bias.residual(st, self._predict(lo, now_ms),
                                                    self._predict(hi, now_ms), timed)
                    ok = d2 < prm["gate"]
                    if ok:
                        st = (_bias.time_fit(st, ys, rs, vs, prm, self.pack.time_offset) if timed
                              else _bias.update(st, ys, rs, prm))
                        self.bias[key] = st
                    trace.append(_trace.bias(lo.key, hi.key, d2, prm["gate"], ok, st, timed))

    def snapshot(self):
        return _snapshot.assign(self)


def assignment_cost(east, north, t_var, fused):
    """Assignment of one source, Cost: the squared distance of the entity
    from the fused estimate of the other members, over the sum of the
    variances, on both axes."""
    fe, fn = fused
    return ((east[0] - fe[0]) ** 2 / (east[2] + t_var[0] + fe[2])
            + (north[0] - fn[0]) ** 2 / (north[2] + t_var[1] + fn[2]))
