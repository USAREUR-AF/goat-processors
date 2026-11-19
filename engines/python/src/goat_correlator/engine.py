"""Correlate engine (spec/correlate.md 0.5, spec/correlate-assign.md 0.3). Standard library only."""

import math
import os

R = 6371008.8

TESTS = {
    "distance": ("max_m",),
    "window": ("multiplier", "window_m", "err_min_m", "err_max_m"),
    "mahalanobis": ("gate",),
    "course": ("max_deg", "min_speed_ms"),
    "speed": ("max_pct", "min_speed_ms"),
    "altitude": ("max_m",),
    "same": ("key",),
}
FILTER_PARAMS = ("accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms")
MANOEUVRE_PARAMS = ("accel_var", "p_enter", "p_leave")
MODELS = ("quiet", "manoeuvre")
REQUIRED = (("track.source_id", "str"), ("uid", "str"), ("time_ms", "int"),
            ("lat", "num"), ("lon", "num"))
OPTIONAL = {"hae": "num", "ce": "num", "course": "num", "speed_ms": "num",
            "type": "str", "stale_ms": "int"}


def _is(v, kind):
    if isinstance(v, bool) or v is None:
        return False
    if kind == "str":
        return isinstance(v, str)
    if kind == "int":
        return isinstance(v, int)
    return isinstance(v, (int, float))


def _normalise(report):
    """Spec, Reports: optional keys of the wrong type are absent."""
    out = {}
    for k, v in report.items():
        if v is None:
            continue
        if k in OPTIONAL and not _is(v, OPTIONAL[k]):
            continue
        if k == "ce" and v <= 0:
            continue
        out[k] = v
    return out


class PackError(Exception):
    pass


class Pack:
    def __init__(self):
        self.name = None
        self.version = None
        self.filter = None
        self.gate = []
        self.confirm = []
        self.hold = []
        self.confirm_count = None
        self.hold_failures = None
        self.stale_ms = None
        self.same_source = "forbid"
        self.output = "priority"
        self.priority = {}
        self.method = "confirm"
        self.new_cost = None
        self.keep_bonus = None
        self.manoeuvre = None
        self.window = 1
        self.hypotheses = 1


def _params(args, line_no):
    out = {}
    for a in args:
        if "=" not in a:
            raise PackError("line %d: parameter without '=': %s" % (line_no, a))
        k, v = a.split("=", 1)
        if k in out:
            raise PackError("line %d: repeated parameter %s" % (line_no, k))
        out[k] = v
    return out


def _num(v, line_no):
    try:
        x = float(v)
    except ValueError:
        raise PackError("line %d: not a number: %s" % (line_no, v))
    if math.isnan(x) or math.isinf(x):
        raise PackError("line %d: not a finite number: %s" % (line_no, v))
    return x


def _int(v, line_no):
    try:
        return int(v, 10)
    except ValueError:
        raise PackError("line %d: not an integer: %s" % (line_no, v))


def parse_pack(text):
    p = Pack()
    seen = set()
    for i, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        d, args = parts[0], parts[1:]
        if d in ("pack", "version", "filter", "confirm_count", "hold_failures",
                 "stale_ms", "same_source", "output", "method", "new_cost", "keep_bonus",
                 "manoeuvre", "window", "hypotheses"):
            if d in seen:
                raise PackError("line %d: repeated directive %s" % (i, d))
            seen.add(d)
        if d in ("pack", "version"):
            if len(args) != 1:
                raise PackError("line %d: %s takes one value" % (i, d))
            setattr(p, "name" if d == "pack" else "version", args[0])
        elif d == "filter":
            kv = _params(args, i)
            if set(kv) != set(FILTER_PARAMS):
                raise PackError("line %d: filter needs exactly %s" % (i, ", ".join(FILTER_PARAMS)))
            p.filter = {k: _num(v, i) for k, v in kv.items()}
            if p.filter["accel_var"] < 0 or min(p.filter[k] for k in ("default_ce_m", "vel_sigma_ms", "unknown_vel_ms")) <= 0:
                raise PackError("line %d: filter variances must be above 0 (accel_var 0 or above)" % i)
        elif d in ("gate", "confirm", "hold"):
            if not args:
                raise PackError("line %d: %s needs a test" % (i, d))
            name = args[0]
            if name not in TESTS:
                raise PackError("line %d: unknown test %s" % (i, name))
            kv = _params(args[1:], i)
            if set(kv) != set(TESTS[name]):
                raise PackError("line %d: test %s needs exactly %s" % (i, name, ", ".join(TESTS[name])))
            params = {k: (v if name == "same" else _num(v, i)) for k, v in kv.items()}
            getattr(p, d).append((name, params))
        elif d == "manoeuvre":
            kv = _params(args, i)
            if set(kv) != set(MANOEUVRE_PARAMS):
                raise PackError("line %d: manoeuvre needs exactly %s" % (i, ", ".join(MANOEUVRE_PARAMS)))
            m = {k: _num(v, i) for k, v in kv.items()}
            if m["p_enter"] <= 0 or m["p_leave"] <= 0 or m["p_enter"] + m["p_leave"] >= 1:
                raise PackError("line %d: p_enter and p_leave must be above 0 with a sum below 1" % i)
            p.manoeuvre = m
        elif d in ("window", "hypotheses"):
            if len(args) != 1:
                raise PackError("line %d: %s takes one value" % (i, d))
            n = _int(args[0], i)
            if n < 1:
                raise PackError("line %d: %s must be 1 or above" % (i, d))
            setattr(p, d, n)
        elif d in ("confirm_count", "hold_failures", "stale_ms"):
            if len(args) != 1:
                raise PackError("line %d: %s takes one value" % (i, d))
            setattr(p, d, _int(args[0], i))
        elif d == "same_source":
            if args not in (["forbid"], ["allow"]):
                raise PackError("line %d: same_source is forbid or allow" % i)
            p.same_source = args[0]
        elif d == "output":
            if args not in (["priority"], ["latest"]):
                raise PackError("line %d: output is priority or latest" % i)
            p.output = args[0]
        elif d == "priority":
            if len(args) != 2:
                raise PackError("line %d: priority takes a source and a number" % i)
            p.priority[args[0]] = _int(args[1], i)
            seen.add("priority")
        elif d == "method":
            if args not in (["confirm"], ["assign"]):
                raise PackError("line %d: method is confirm or assign" % i)
            p.method = args[0]
        elif d in ("new_cost", "keep_bonus"):
            if len(args) != 1:
                raise PackError("line %d: %s takes one value" % (i, d))
            setattr(p, d, _num(args[0], i))
            if (d == "new_cost" and p.new_cost <= 0) or (d == "keep_bonus" and p.keep_bonus < 0):
                raise PackError("line %d: new_cost must be above 0 and keep_bonus 0 or above" % i)
        else:
            raise PackError("line %d: unknown directive %s" % (i, d))
    if p.method == "assign":
        required = ("pack", "version", "filter", "new_cost", "keep_bonus", "stale_ms")
        refused = ("confirm_count", "hold_failures", "same_source", "output", "priority")
        if p.confirm or p.hold or any(d in seen for d in refused):
            raise PackError("method assign takes only pack, version, method, filter, manoeuvre, gate, "
                            "new_cost, keep_bonus, stale_ms, window, hypotheses")
    else:
        required = ("pack", "version", "filter", "confirm_count", "hold_failures", "stale_ms")
        if any(d in seen for d in ("new_cost", "keep_bonus", "window", "hypotheses")):
            raise PackError("new_cost, keep_bonus, window and hypotheses need method assign")
    for d in required:
        if d not in seen:
            raise PackError("missing directive %s" % d)
    if p.manoeuvre is not None and p.manoeuvre["accel_var"] <= p.filter["accel_var"]:
        raise PackError("manoeuvre accel_var must be above the filter's accel_var")
    if p.window == 1 and p.hypotheses > 1:
        raise PackError("hypotheses above 1 needs a window above 1")
    return p


def load_pack(directory):
    with open(os.path.join(directory, "pack.def"), encoding="utf-8") as f:
        return parse_pack(f.read())


def _wrap180(x):
    while x > 180.0:
        x -= 360.0
    while x <= -180.0:
        x += 360.0
    return x


def _predict_axis(a, dt, q):
    p, v, pp, pv, vv = a
    return [p + v * dt,
            v,
            pp + 2 * dt * pv + dt * dt * vv + q * dt ** 4 / 4,
            pv + dt * vv + q * dt ** 3 / 2,
            vv + q * dt * dt]


def _pos_step(a, z, r):
    """Position update; returns the new axis, the innovation y and its variance s."""
    p, v, pp, pv, vv = a
    s = pp + r
    k1 = pp / s
    k2 = pv / s
    y = z - p
    return [p + k1 * y, v + k2 * y, (1 - k1) * pp, (1 - k1) * pv, vv - k2 * pv], y, s


def _vel_step(a, z, r):
    """Velocity update; returns the new axis, the innovation y and its variance s."""
    p, v, pp, pv, vv = a
    s = vv + r
    k1 = pv / s
    k2 = vv / s
    y = z - v
    return [p + k1 * y, v + k2 * y, pp - k1 * pv, (1 - k2) * pv, (1 - k2) * vv], y, s


def _pos_update(a, z, r):
    return _pos_step(a, z, r)[0]


def _vel_update(a, z, r):
    return _vel_step(a, z, r)[0]


def _blend(a1, a2, w1, w2):
    """correlate.md, Two-model filter: the weighted combination of two axes,
    with the spread of the means added to the covariance."""
    p1, v1, pp1, pv1, vv1 = a1
    p2, v2, pp2, pv2, vv2 = a2
    p = w1 * p1 + w2 * p2
    v = w1 * v1 + w2 * v2
    dp1, dv1, dp2, dv2 = p1 - p, v1 - v, p2 - p, v2 - v
    return [p, v,
            w1 * (pp1 + dp1 * dp1) + w2 * (pp2 + dp2 * dp2),
            w1 * (pv1 + dp1 * dv1) + w2 * (pv2 + dp2 * dv2),
            w1 * (vv1 + dv1 * dv1) + w2 * (vv2 + dv2 * dv2)]


def _transition(man, dt):
    """Switching probabilities over dt seconds: t[i][j] from model i to model j."""
    a, b = man["p_enter"], man["p_leave"]
    s = a + b
    lam = math.pow(1.0 - s, dt)
    t12 = a / s * (1.0 - lam)
    t21 = b / s * (1.0 - lam)
    return [[1.0 - t12, t12], [t21, 1.0 - t21]]


class _Entity:
    def __init__(self, key, source):
        self.key = key
        self.source = source
        self.report = None
        self.last_time_ms = None
        self.group = None
        self.hold_failures = 0
        self.system = None
        self.east = None
        self.north = None
        self.models = None  # two-model filter: [[east, north] quiet, [east, north] manoeuvre]
        self.mode = None    # [mu_quiet, mu_manoeuvre]

    def ce(self, pack):
        v = self.report.get("ce")
        return pack.filter["default_ce_m"] if v is None else float(v)


def _env(report):
    t = report.get("type")
    if t is None:
        return None
    parts = str(t).split("-")
    return parts[2] if len(parts) >= 3 else None


def _filter_snap(e):
    """The snapshot fields of an entity's track estimate."""
    out = {"filter": {"east": list(e.east), "north": list(e.north)}}
    if e.models is not None:
        out["models"] = {MODELS[j]: {"east": list(m[0]), "north": list(m[1])} for j, m in enumerate(e.models)}
        out["mode"] = list(e.mode)
    return out


class Engine:
    def __init__(self, pack):
        self.pack = pack
        self.ref = None
        self.entities = {}
        self.groups = {}
        self.group_order = []
        self.counts = {}
        self.next_group = 1
        self.retiring = set()

    # frame -------------------------------------------------------------
    def _to_plane(self, lat, lon):
        lat0, lon0 = self.ref
        dlon = _wrap180(lon - lon0)
        return (R * math.radians(dlon) * math.cos(math.radians(lat0)),
                R * math.radians(lat - lat0))

    def _to_deg(self, east, north):
        lat0, lon0 = self.ref
        lat = lat0 + math.degrees(north / R)
        lon = lon0 + math.degrees(east / (R * math.cos(math.radians(lat0))))
        return lat, _wrap180(lon)

    # helpers -----------------------------------------------------------
    def _predict(self, ent, t):
        dt = (t - ent.last_time_ms) / 1000.0
        if ent.models is not None:
            q = (self.pack.filter["accel_var"], self.pack.manoeuvre["accel_var"])
            pr = [(_predict_axis(m[0], dt, q[j]), _predict_axis(m[1], dt, q[j]))
                  for j, m in enumerate(ent.models)]
            mu = ent.mode
            return (_blend(pr[0][0], pr[1][0], mu[0], mu[1]),
                    _blend(pr[0][1], pr[1][1], mu[0], mu[1]))
        q = self.pack.filter["accel_var"]
        return _predict_axis(ent.east, dt, q), _predict_axis(ent.north, dt, q)

    def _two_model_update(self, ent, dt, e, n, r, vel, rv, trace):
        """correlate.md, Two-model filter, later reports: mixing, per-model
        predict and update, likelihood, mode probability, combination."""
        man = self.pack.manoeuvre
        t = _transition(man, dt)
        mu = ent.mode
        models = ent.models
        c = [t[0][j] * mu[0] + t[1][j] * mu[1] for j in (0, 1)]
        mixed = []
        for j in (0, 1):
            if c[j] == 0:
                mixed.append(models[j])
                continue
            w1 = t[0][j] * mu[0] / c[j]
            w2 = t[1][j] * mu[1] / c[j]
            mixed.append([_blend(models[0][x], models[1][x], w1, w2) for x in (0, 1)])
        q = (self.pack.filter["accel_var"], man["accel_var"])
        new_models, lam = [], []
        for j in (0, 1):
            east = _predict_axis(mixed[j][0], dt, q[j])
            north = _predict_axis(mixed[j][1], dt, q[j])
            terms = []
            east, y, s = _pos_step(east, e, r)
            terms.append(y * y / s + math.log(s))
            north, y, s = _pos_step(north, n, r)
            terms.append(y * y / s + math.log(s))
            if vel:
                east, y, s = _vel_step(east, vel[0], rv)
                terms.append(y * y / s + math.log(s))
                north, y, s = _vel_step(north, vel[1], rv)
                terms.append(y * y / s + math.log(s))
            g = 0.0
            for x in terms:
                g += x
            lam.append(-0.5 * g)
            new_models.append([east, north])
        m = max(lam[j] for j in (0, 1) if c[j] > 0)
        w = [c[j] * math.exp(lam[j] - m) if c[j] > 0 else 0.0 for j in (0, 1)]
        tot = w[0] + w[1]
        mu = [w[0] / tot, w[1] / tot]
        ent.models = new_models
        ent.mode = mu
        ent.east = _blend(new_models[0][0], new_models[1][0], mu[0], mu[1])
        ent.north = _blend(new_models[0][1], new_models[1][1], mu[0], mu[1])
        for j in (0, 1):
            trace.append({"stage": "filter", "a": ent.key, "b": MODELS[j], "test": "likelihood",
                          "value": lam[j], "limit": None, "pass": True})
        for j in (0, 1):
            trace.append({"stage": "filter", "a": ent.key, "b": MODELS[j], "test": "mode",
                          "value": mu[j], "limit": None, "pass": True})

    @staticmethod
    def _pair(a, b):
        return a + "|" + b if a < b else b + "|" + a

    def _d2(self, a, b):
        be, bn = self._predict(b, a.last_time_ms)
        ce2 = a.ce(self.pack) ** 2
        return ((a.east[0] - be[0]) ** 2 / (be[2] + ce2)
                + (a.north[0] - bn[0]) ** 2 / (bn[2] + ce2))

    def _dist(self, a, b):
        be, bn = self._predict(b, a.last_time_ms)
        return math.hypot(a.east[0] - be[0], a.north[0] - bn[0])

    def _run_test(self, stage, name, prm, a, b, trace):
        rec = {"stage": stage, "a": a.key, "b": b.key, "test": name}
        ra, rb = a.report, b.report
        if name == "distance":
            value, limit = self._dist(a, b), prm["max_m"]
            ok = value < limit
        elif name == "window":
            lo, hi = prm["err_min_m"], prm["err_max_m"]
            ea = min(max(a.ce(self.pack), lo), hi)
            eb = min(max(b.ce(self.pack), lo), hi)
            value = self._dist(a, b)
            limit = prm["multiplier"] * math.sqrt(ea * ea + eb * eb) + prm["window_m"]
            ok = value < limit
        elif name == "mahalanobis":
            value, limit = self._d2(a, b), prm["gate"]
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
            va = _env(ra) if k == "@env" else ra.get(k)
            vb = _env(rb) if k == "@env" else rb.get(k)
            value, limit, ok = va, vb, va == vb
        else:
            raise AssertionError(name)
        rec.update(value=value, limit=limit, **{"pass": ok})
        trace.append(rec)
        return ok

    def _run_stage(self, stage, a, b, trace):
        for name, prm in getattr(self.pack, stage):
            if not self._run_test(stage, name, prm, a, b, trace):
                return False
        return True

    def _hold_ok(self, stage_tests, a, b, trace):
        ok = True
        for name, prm in stage_tests:
            if not self._run_test("hold", name, prm, a, b, trace):
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

    # operations --------------------------------------------------------
    def _accept(self, report, events, trace):
        """Spec, Reports and Track estimate: validate, then update the filter.
        Returns the entity, or None when the report is rejected."""
        for k, kind in REQUIRED:
            if not _is(report.get(k), kind):
                events.append({"ev": "reject", "reason": "missing:" + k})
                return None
        report = _normalise(report)
        source = str(report["track.source_id"])
        key = source + "/" + str(report["uid"])
        t = int(report["time_ms"])
        ent = self.entities.get(key)
        if key in self.retiring:
            events.append({"ev": "reject", "entity": key, "reason": "retiring"})
            return None
        if ent is not None and t < ent.last_time_ms:
            events.append({"ev": "reject", "entity": key, "reason": "out-of-order"})
            return None
        lat, lon = float(report["lat"]), float(report["lon"])
        if self.ref is None:
            self.ref = (lat, lon)
        e, n = self._to_plane(lat, lon)
        f = self.pack.filter
        vel = None
        if report.get("course") is not None and report.get("speed_ms") is not None:
            c, s = math.radians(float(report["course"])), float(report["speed_ms"])
            vel = (s * math.sin(c), s * math.cos(c))
        ce = f["default_ce_m"] if report.get("ce") is None else float(report["ce"])
        if ent is None:
            ent = _Entity(key, source)
            self.entities[key] = ent
            vv = (f["vel_sigma_ms"] if vel else f["unknown_vel_ms"]) ** 2
            ent.east = [e, vel[0] if vel else 0.0, ce * ce, 0.0, vv]
            ent.north = [n, vel[1] if vel else 0.0, ce * ce, 0.0, vv]
            if self.pack.manoeuvre is not None:
                a, b = self.pack.manoeuvre["p_enter"], self.pack.manoeuvre["p_leave"]
                ent.models = [[list(ent.east), list(ent.north)], [list(ent.east), list(ent.north)]]
                ent.mode = [b / (a + b), a / (a + b)]
            events.append({"ev": "new", "entity": key})
        elif ent.models is not None:
            dt = (t - ent.last_time_ms) / 1000.0
            self._two_model_update(ent, dt, e, n, ce * ce, vel, f["vel_sigma_ms"] ** 2, trace)
        else:
            dt = (t - ent.last_time_ms) / 1000.0
            q = f["accel_var"]
            ent.east = _pos_update(_predict_axis(ent.east, dt, q), e, ce * ce)
            ent.north = _pos_update(_predict_axis(ent.north, dt, q), n, ce * ce)
            if vel:
                r = f["vel_sigma_ms"] ** 2
                ent.east = _vel_update(ent.east, vel[0], r)
                ent.north = _vel_update(ent.north, vel[1], r)
        ent.report = dict(report)
        ent.last_time_ms = t
        return ent

    def ingest(self, report):
        events, trace = [], []
        ent = self._accept(report, events, trace)
        if ent is None:
            return events, trace
        key, source = ent.key, ent.source

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
        for k in sorted(self.entities):
            ent = self.entities[k]
            stale = now_ms - ent.last_time_ms > self.pack.stale_ms
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
            events.append({"ev": "drop", "entity": k})
        for g in self.group_order:
            members = self.groups[g]
            if self.pack.output == "priority":
                primary = min(members, key=lambda m: (self.pack.priority.get(self.entities[m].source, 100), m))
            else:
                primary = min(members, key=lambda m: (-self.entities[m].last_time_ms, m))
            p = self.entities[primary]
            pe, pn = self._predict(p, now_ms)
            lat, lon = self._to_deg(pe[0], pn[0])
            course = math.degrees(math.atan2(pe[1], pn[1]))
            if course < 0:
                course += 360.0
            if course >= 360.0:
                course -= 360.0
            ev = {"ev": "fused", "group": g, "primary": primary, "members": list(members),
                  "lat": lat, "lon": lon, "course": course, "speed_ms": math.hypot(pe[1], pn[1])}
            if p.report.get("hae") is not None:
                ev["hae"] = float(p.report["hae"])
            events.append(ev)
        return events, trace

    def snapshot(self):
        return {
            "ref": list(self.ref) if self.ref else None,
            "entities": {k: dict({"last_time_ms": e.last_time_ms, "group": e.group,
                                  "hold_failures": e.hold_failures}, **_filter_snap(e))
                         for k, e in sorted(self.entities.items())},
            "groups": {g: list(self.groups[g]) for g in self.group_order},
            "counts": dict(sorted(self.counts.items())),
            "next_group": self.next_group,
        }


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


class AssignEngine(Engine):
    """spec/correlate-assign.md: every track in one system track; per-source
    exact assignment at each tick, ranked and kept over a window of ticks;
    fused estimate by inverse-variance weights."""

    def __init__(self, pack):
        super().__init__(pack)
        self.committed = _Members()
        self.histories = [_History([])]
        self.reported = set()

    def ingest(self, report):
        events, trace = [], []
        ent = self._accept(report, events, trace)
        if ent is not None:
            self.reported.add(ent.key)
        return events, trace

    def _fused(self, members, t):
        """Fused estimate: per axis (p, pp, v, vv) at time t."""
        out = [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]
        for k in members:
            pr = self._predict(self.entities[k], t)
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
        fe, fn = self._fused(members, a.last_time_ms)
        return ((a.east[0] - fe[0]) ** 2 / (a.east[2] + fe[1])
                + (a.north[0] - fn[0]) ** 2 / (a.north[2] + fn[1]))

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
        for h in self.histories:
            mem = self._latest(h).copy()
            evs = []
            for k in stale:
                if mem.system_of(k) is not None:
                    mem.leave(k, "stale", evs)
                evs.append({"ev": "drop", "entity": k})
            h.records = h.records + [_Record(0.0, [], evs, mem)]
        self.retiring.update(stale)
        self.reported.difference_update(stale)

        # Assignment, per source in key order, extending every history.
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
            if multi:
                for pos, (tot, hi, r, _) in enumerate(cands):
                    trace.append({"stage": "history", "a": hi, "b": r, "test": "total",
                                  "value": tot, "limit": None, "pass": pos < k_max})
            self.histories = [e[3] for e in cands[:k_max]]

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

        # Output: committed system tracks, then the best history's memberships.
        for s in self.committed.order:
            members = self.committed.systems[s]
            fe, fn = self._fused(members, now_ms)
            lat, lon = self._to_deg(fe[0], fn[0])
            course = math.degrees(math.atan2(fe[2], fn[2]))
            if course < 0:
                course += 360.0
            if course >= 360.0:
                course -= 360.0
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

    def snapshot(self):
        out = {
            "ref": list(self.ref) if self.ref else None,
            "entities": {k: dict({"last_time_ms": e.last_time_ms, "system": e.system}, **_filter_snap(e))
                         for k, e in sorted(self.entities.items())},
            "systems": self.committed.snap(),
            "next_system": self.committed.next,
            "reported": sorted(self.reported),
        }
        if self.pack.window > 1:
            out["retiring"] = sorted(self.retiring)
            out["histories"] = [
                {"total": h.total(),
                 "records": [{"cost": r.cost, "choices": [list(x) for x in r.choices],
                              "events": [dict(e) for e in r.events],
                              "systems": r.members.snap(), "next_system": r.members.next}
                             for r in h.records]}
                for h in self.histories]
        return out


def make_engine(pack):
    """The engine for a pack's method."""
    return AssignEngine(pack) if pack.method == "assign" else Engine(pack)
