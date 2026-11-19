"""Correlator engine (spec/correlator-spec.md, version 0.1). Standard library only."""

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
REQUIRED = ("track.source_id", "uid", "time_ms", "lat", "lon")


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
                 "stale_ms", "same_source", "output"):
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
        else:
            raise PackError("line %d: unknown directive %s" % (i, d))
    for d in ("pack", "version", "filter", "confirm_count", "hold_failures", "stale_ms"):
        if d not in seen:
            raise PackError("missing directive %s" % d)
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


def _pos_update(a, z, r):
    p, v, pp, pv, vv = a
    s = pp + r
    k1 = pp / s
    k2 = pv / s
    y = z - p
    return [p + k1 * y, v + k2 * y, (1 - k1) * pp, (1 - k1) * pv, vv - k2 * pv]


def _vel_update(a, z, r):
    p, v, pp, pv, vv = a
    s = vv + r
    k1 = pv / s
    k2 = vv / s
    y = z - v
    return [p + k1 * y, v + k2 * y, pp - k1 * pv, (1 - k2) * pv, (1 - k2) * vv]


class _Entity:
    def __init__(self, key, source):
        self.key = key
        self.source = source
        self.report = None
        self.last_time_ms = None
        self.group = None
        self.hold_failures = 0
        self.east = None
        self.north = None

    def ce(self, pack):
        v = self.report.get("ce")
        return pack.filter["default_ce_m"] if v is None else float(v)


def _env(report):
    t = report.get("type")
    if t is None:
        return None
    parts = str(t).split("-")
    return parts[2] if len(parts) >= 3 else None


class Engine:
    def __init__(self, pack):
        self.pack = pack
        self.ref = None
        self.entities = {}
        self.groups = {}
        self.group_order = []
        self.counts = {}
        self.next_group = 1

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
        q = self.pack.filter["accel_var"]
        return _predict_axis(ent.east, dt, q), _predict_axis(ent.north, dt, q)

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
                value, limit = abs(1.0 - slow / fast) * 100.0, prm["max_pct"]
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
    def ingest(self, report):
        events, trace = [], []
        for k in REQUIRED:
            if report.get(k) is None:
                events.append({"ev": "reject", "reason": "missing:" + k})
                return events, trace
        source = str(report["track.source_id"])
        key = source + "/" + str(report["uid"])
        t = int(report["time_ms"])
        ent = self.entities.get(key)
        if ent is not None and t < ent.last_time_ms:
            events.append({"ev": "reject", "entity": key, "reason": "out-of-order"})
            return events, trace
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
            events.append({"ev": "new", "entity": key})
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
            "entities": {k: {"last_time_ms": e.last_time_ms, "group": e.group,
                             "hold_failures": e.hold_failures,
                             "filter": {"east": list(e.east), "north": list(e.north)}}
                         for k, e in sorted(self.entities.items())},
            "groups": {g: list(self.groups[g]) for g in self.group_order},
            "counts": dict(sorted(self.counts.items())),
            "next_group": self.next_group,
        }
