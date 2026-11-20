"""Correlate, method assign (spec/correlate-assign.md): every track in one
system track; per source, the exact least-cost assignment at each tick,
ranked and kept over a window of ticks; sensor bias and time offset per
pair of sources; fused estimate by inverse-variance weights."""

import math

from . import estimate
from . import snapshot as _snapshot
from .correlate import Correlator
from .model import course_deg

INF = float("inf")


def min_cost_assignment(cost):
    """Exact minimum-cost assignment of every row to a distinct column.

    `cost` is a list of rows, each a list of column costs (INF = forbidden),
    with at least as many columns as rows. Shortest augmenting path
    (Hungarian, potentials). Returns the column of each row, or None when no
    assignment of finite cost exists."""
    n = len(cost)
    if n == 0:
        return []
    m = len(cost[0])
    u = [0.0] * (n + 1)
    v = [0.0] * (m + 1)
    p = [0] * (m + 1)
    way = [0] * (m + 1)
    for i in range(1, n + 1):
        p[0] = i
        j0 = 0
        minv = [INF] * (m + 1)
        used = [False] * (m + 1)
        while True:
            used[j0] = True
            i0 = p[j0]
            delta = INF
            j1 = -1
            for j in range(1, m + 1):
                if not used[j]:
                    c = cost[i0 - 1][j - 1]
                    cur = INF if c == INF else c - u[i0] - v[j]
                    if cur < minv[j]:
                        minv[j] = cur
                        way[j] = j0
                    if minv[j] < delta:
                        delta = minv[j]
                        j1 = j
            if j1 == -1:
                return None
            for j in range(m + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minv[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while True:
            j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
            if j0 == 0:
                break
    out = [None] * n
    for j in range(1, m + 1):
        if p[j]:
            out[p[j] - 1] = j - 1
    return out


def assignment_total(matrix, cols):
    """correlate-assign.md, Ranking: the chosen entries in ascending order of
    value, added left to right from 0."""
    t = 0.0
    for x in sorted(matrix[i][j] for i, j in enumerate(cols)):
        t += x
    return t


def _choice_vector(cols, c):
    """Column index per row; every alone column counts as c, after the system columns."""
    return [j if j < c else c for j in cols]


def _constrained(matrix, fixed, forbidden):
    out = [list(r) for r in matrix]
    for i, j in forbidden:
        out[i][j] = INF
    for i, j in fixed:
        for jj in range(len(out[i])):
            if jj != j:
                out[i][jj] = INF
        for ii in range(len(out)):
            if ii != i:
                out[ii][j] = INF
    return out


def _order_key(matrix, cols, c):
    return (assignment_total(matrix, cols), _choice_vector(cols, c))


def _first_assignment(matrix, c):
    """The first assignment in ranking order (least total, then the smallest
    choice vector), found with the exact assignment and row-by-row fixing."""
    if min_cost_assignment(matrix) is None:
        return None
    n = len(matrix)
    fixed = []
    best = None
    for i in range(n):
        best = None
        cands = list(range(c)) + [c + i]
        for j in cands:
            if matrix[i][j] == INF:
                continue
            cols = min_cost_assignment(_constrained(matrix, fixed + [(i, j)], ()))
            if cols is None:
                continue
            key = _order_key(matrix, cols, c)
            if best is None or key[0] < best[0][0]:
                best = (key, j, cols)
        fixed.append((i, best[1]))
    if best is None:
        return []
    return best[2]


def ranked_assignments(matrix, c, k):
    """correlate-assign.md, Ranking: the first k assignments in ranking order,
    by Murty's partition of the solution space around each one found."""
    n = len(matrix)
    first = _first_assignment(matrix, c)
    if first is None:
        return []
    out = [first]
    queue = []

    def partition(cols, fixed, forbidden):
        fixed_rows = {i for i, _ in fixed}
        prefix = list(fixed)
        for i in range(n):
            if i in fixed_rows:
                continue
            forb = list(forbidden) + [(i, cols[i])]
            sub = _constrained(matrix, prefix, forb)
            got = _first_assignment(sub, c)
            if got is not None:
                queue.append((_order_key(matrix, got, c), got, list(prefix), forb))
            prefix.append((i, cols[i]))

    partition(first, [], [])
    while len(out) < k and queue:
        queue.sort(key=lambda e: e[0])
        _, cols, fixed, forbidden = queue.pop(0)
        out.append(cols)
        partition(cols, fixed, forbidden)
    return out


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

    def __init__(self, pack):
        super().__init__(pack)
        self.committed = _Members()
        self.histories = [_History([])]
        self.reported = set()
        self.bias = {}

    def ingest(self, report):
        events, trace = [], []
        ent = self._accept(report, events, trace)
        if ent is not None:
            self.reported.add(ent.key)
        return events, trace

    def _offset(self, src, dst, vel):
        """Per axis (shift, variance) that moves a position of source src, with
        velocity vel, into the frame of source dst: the pair estimate, or 0
        with the prior."""
        if self.pack.bias is None or src == dst:
            return None
        key = self._pair(src, dst)
        st = self.bias.get(key)
        if st is None:
            v = self.pack.bias["sigma_m"] ** 2
            return ((0.0, v), (0.0, v))
        sign = 1.0 if src < dst else -1.0
        out = []
        for x in (0, 1):
            o = st[x][0]
            if self.pack.time_offset is not None:
                o = o - vel[x] * st[3]
            out.append((sign * o, st[x][1]))
        return tuple(out)

    def _predict_in(self, b, t, a):
        pr = estimate.with_variance(self._predict(b, t), b.t_var)
        off = self._offset(b.source, a if isinstance(a, str) else a.source, (pr[0][1], pr[1][1]))
        if off is None:
            return pr
        return tuple((x[0] + o[0], x[1], x[2] + o[1]) + tuple(x[3:]) for x, o in zip(pr, off))

    def _fused(self, members, t, frame=None):
        """Fused estimate: per axis (p, pp, v, vv) at time t; with `frame` (an
        entity), each member is first moved into that entity's frame."""
        out = [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]
        for k in members:
            pr = self._predict(self.entities[k], t) if frame is None \
                else self._predict_in(self.entities[k], t, frame)
            for x in (0, 1):
                a = pr[x]
                o = out[x]
                o[0] += 1.0 / a[2]
                o[1] += a[0] / a[2]
                o[2] += 1.0 / a[4]
                o[3] += a[1] / a[4]
        res = []
        for ip, sp, iv, sv in out:
            pp = 1.0 / ip
            vv = 1.0 / iv
            res.append((pp * sp, pp, vv * sv, vv))
        return res

    def _cost(self, a, members):
        fe, fn = self._fused(members, a.last_time_ms, a)
        return ((a.east[0] - fe[0]) ** 2 / (a.east[2] + a.t_var[0] + fe[1])
                + (a.north[0] - fn[0]) ** 2 / (a.north[2] + a.t_var[1] + fn[1]))

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
            self._bias_update(now_ms, tick_rows, trace)

        # Output: committed system tracks (with a margin, the best history's
        # latest membership), then the best history's memberships.
        shown = self._latest(self.histories[0]) if self.pack.margin is not None else self.committed
        for s in shown.order:
            members = shown.systems[s]
            fe, fn = self._fused(members, now_ms)
            lat, lon = self._to_deg(fe[0], fn[0])
            course = course_deg(fe[2], fn[2])
            ev = {"ev": "system", "system": s, "members": list(members),
                  "lat": lat, "lon": lon, "course": course, "speed_ms": math.hypot(fe[2], fn[2])}
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
        """correlate-assign.md, Sensor bias: every pair of members of one
        committed system track, from two sources, one of which reported."""
        prm = self.pack.bias
        floor2 = prm["floor_m"] ** 2
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
                    timed = self.pack.time_offset is not None
                    if st is None:
                        v = prm["sigma_m"] ** 2
                        st = [[0.0, v, 0.0], [0.0, v, 0.0], 0]
                        if timed:
                            st += [0.0, [0.0] * 8]
                    pl, ph = self._predict(lo, now_ms), self._predict(hi, now_ms)
                    ys, rs, vs = [], [], []
                    d2 = 0.0
                    for x in (0, 1):
                        y = ph[x][0] - pl[x][0]
                        r = pl[x][2] + ph[x][2]
                        vx = (pl[x][1] + ph[x][1]) / 2
                        ys.append(y)
                        rs.append(r)
                        vs.append(vx)
                        want = st[x][0] - vx * st[3] if timed else st[x][0]
                        d2 += (y - want) ** 2 / (st[x][1] + r)
                    ok = d2 < prm["gate"]
                    if ok and timed:
                        st = self._time_fit(st, ys, rs, vs)
                        self.bias[key] = st
                    elif ok:
                        n = st[2] + 1
                        pv = prm["sigma_m"] ** 2 / (n + 1)
                        if pv < floor2:
                            pv = floor2
                        new = []
                        for x in (0, 1):
                            w = 1.0 / rs[x]
                            ws = st[x][2] + w
                            new.append([st[x][0] + (w / ws) * (ys[x] - st[x][0]), pv, ws])
                        st = [new[0], new[1], n]
                        self.bias[key] = st
                    rec = {"stage": "bias", "a": lo.key, "b": hi.key, "test": "offset",
                           "value": d2, "limit": prm["gate"], "pass": ok,
                           "east": st[0][0], "north": st[1][0], "var": st[0][1],
                           "pairs": st[2]}
                    if timed:
                        rec["time_offset_ms"] = st[3] * 1000.0
                    trace.append(rec)

    def _time_fit(self, st, ys, rs, vs):
        """correlate-assign.md, Sensor bias, Time offset: add one pair to the
        sums and solve for the offsets o east, o north and the time offset."""
        prm = self.pack.bias
        n = st[2] + 1
        var = prm["sigma_m"] ** 2 / (n + 1)
        if var < prm["floor_m"] ** 2:
            var = prm["floor_m"] ** 2
        S = list(st[4])
        we, wn = 1.0 / rs[0], 1.0 / rs[1]
        ve, vn = vs[0], vs[1]
        S[0] += we
        S[1] += wn
        S[2] += we * ve
        S[3] += wn * vn
        S[4] += we * ve * ve + wn * vn * vn
        S[5] += we * ys[0]
        S[6] += wn * ys[1]
        S[7] += we * ve * ys[0] + wn * vn * ys[1]
        po = 1.0 / prm["sigma_m"] ** 2
        pt = 1.0 / (self.pack.time_offset / 1000.0) ** 2
        a11 = po + S[0]
        a22 = po + S[1]
        a13 = -S[2]
        a23 = -S[3]
        a33 = pt + S[4]
        b1, b2, b3 = S[5], S[6], -S[7]
        tau = (b3 - a13 * b1 / a11 - a23 * b2 / a22) / (a33 - a13 * a13 / a11 - a23 * a23 / a22)
        oe = (b1 - a13 * tau) / a11
        on = (b2 - a23 * tau) / a22
        return [[oe, var, S[0]], [on, var, S[1]], n, tau, S]

    def snapshot(self):
        return _snapshot.assign(self)
