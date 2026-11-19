"""Fuse engine (spec/fuse.md 0.2). Standard library only.

The per-entity filter, the frame and report validation are those of
spec/correlate.md and come from goat_correlator."""

import math
import os
import re

from goat_correlator.engine import (
    REQUIRED,
    Engine as _CorrelateEngine,
    _is,
    _normalize,
    _pos_update,
    _predict_axis,
    _vel_update,
)

FILTER_PARAMS = ("accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms")
METHODS = ("inverse_variance", "covariance_intersection", "best", "priority", "latest")
RULES = ("priority", "latest", "majority", "max", "min")
ONCE = ("pack", "version", "filter", "kinematics", "stale_ms")
NUMBER = re.compile(r"-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\Z")
INTEGER = re.compile(r"[0-9]+\Z")


class PackError(Exception):
    pass


class Pack:
    def __init__(self):
        self.name = None
        self.version = None
        self.filter = None
        self.kinematics = None
        self.attributes = []  # (key, rule) in pack order
        self.sources = []  # rank order
        self.stale_ms = None


def _num(v, i):
    if not NUMBER.match(v):
        raise PackError("line %d: not a number: %s" % (i, v))
    return float(v)


def parse_pack(text):
    p = Pack()
    seen = set()
    for i, raw in enumerate(text.split("\n"), 1):
        if raw.endswith("\r"):
            raw = raw[:-1]
        parts = [x for x in re.split(r"[ \t]+", raw.split("#", 1)[0]) if x]
        if not parts:
            continue
        d, args = parts[0], parts[1:]
        if d in ONCE:
            if d in seen:
                raise PackError("line %d: repeated directive %s" % (i, d))
            seen.add(d)
        if d in ("pack", "version"):
            if len(args) != 1:
                raise PackError("line %d: %s takes one value" % (i, d))
            setattr(p, "name" if d == "pack" else "version", args[0])
        elif d == "filter":
            kv = {}
            for a in args:
                if "=" not in a:
                    raise PackError("line %d: parameter without '=': %s" % (i, a))
                k, v = a.split("=", 1)
                if k in kv or k not in FILTER_PARAMS:
                    raise PackError("line %d: unknown or repeated parameter %s" % (i, k))
                kv[k] = _num(v, i)
            if set(kv) != set(FILTER_PARAMS):
                raise PackError("line %d: filter needs %s" % (i, ", ".join(FILTER_PARAMS)))
            if kv["accel_var"] < 0 or min(kv["default_ce_m"], kv["vel_sigma_ms"], kv["unknown_vel_ms"]) <= 0:
                raise PackError("line %d: filter variances must be above 0 (accel_var 0 or above)" % i)
            p.filter = kv
        elif d == "kinematics":
            if len(args) != 1 or args[0] not in METHODS:
                raise PackError("line %d: kinematics is one of %s" % (i, ", ".join(METHODS)))
            p.kinematics = args[0]
        elif d == "stale_ms":
            if len(args) != 1 or not INTEGER.match(args[0]):
                raise PackError("line %d: stale_ms takes one integer, 0 or above" % i)
            p.stale_ms = int(args[0])
        elif d == "attribute":
            if len(args) != 2:
                raise PackError("line %d: attribute takes a key and rule=<rule>" % i)
            key, prm = args
            if "=" in key:
                raise PackError("line %d: attribute key cannot contain '='" % i)
            if "=" not in prm:
                raise PackError("line %d: parameter without '=': %s" % (i, prm))
            k, v = prm.split("=", 1)
            if k != "rule" or v not in RULES:
                raise PackError("line %d: attribute needs rule=%s" % (i, "|".join(RULES)))
            if any(key == a for a, _ in p.attributes):
                raise PackError("line %d: repeated attribute %s" % (i, key))
            p.attributes.append((key, v))
        elif d == "source":
            if len(args) != 1:
                raise PackError("line %d: source takes one value" % i)
            if args[0] in p.sources:
                raise PackError("line %d: repeated source %s" % (i, args[0]))
            p.sources.append(args[0])
        else:
            raise PackError("line %d: unknown directive %s" % (i, d))
    for d in ONCE:
        if d not in seen:
            raise PackError("missing directive %s" % d)
    return p


def load_pack(directory):
    with open(os.path.join(directory, "pack.def"), encoding="utf-8") as f:
        return parse_pack(f.read())


def _group_of(report):
    g = report.get("fuse.group")
    return g if isinstance(g, str) and g != "" else None


def _usable(v, rule):
    if isinstance(v, bool):
        return rule not in ("max", "min")
    if isinstance(v, str):
        return rule not in ("max", "min")
    return isinstance(v, (int, float))


def _same(a, b):
    """spec/fuse.md, Attributes: equality for majority."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if isinstance(a, str) or isinstance(b, str):
        return isinstance(a, str) and isinstance(b, str) and a == b
    return a == b


def ci_weight(x, y):
    """spec/fuse.md, covariance_intersection, Weight. x, y: (east, north) axes."""
    ae = 1.0 / y[0][2]
    an = 1.0 / y[1][2]
    de = 1.0 / x[0][2] - ae
    dn = 1.0 / x[1][2] - an
    c2 = de * dn
    c1 = ae * dn + an * de
    if c2 < 0:
        w = -c1 / (2.0 * c2)
        if w < 0:
            w = 0.0
        if w > 1:
            w = 1.0
        return w
    s = c1 + c2
    if s > 0:
        return 1.0
    if s < 0:
        return 0.0
    return 0.5


def ci_fold(x, y, w):
    if w == 1.0:
        return x
    if w == 0.0:
        return y
    out = []
    for X, Y in zip(x, y):
        a = w / X[2]
        b = (1.0 - w) / Y[2]
        pp = 1.0 / (a + b)
        p = pp * (a * X[0] + b * Y[0])
        c = w / X[4]
        d = (1.0 - w) / Y[4]
        vv = 1.0 / (c + d)
        v = vv * (c * X[1] + d * Y[1])
        out.append([p, v, pp, 0.0, vv])
    return out


def inverse_variance(axes_list):
    out = []
    for ax in (0, 1):
        ip = sp = iv = sv = 0.0
        for axes in axes_list:
            a = axes[ax]
            ip += 1.0 / a[2]
            sp += a[0] / a[2]
            iv += 1.0 / a[4]
            sv += a[1] / a[4]
        pp = 1.0 / ip
        vv = 1.0 / iv
        out.append([pp * sp, vv * sv, pp, 0.0, vv])
    return out


class _Entity:
    def __init__(self, key, source):
        self.key = key
        self.source = source
        self.report = None
        self.last_time_ms = None
        self.group = None
        self.east = None
        self.north = None


class Engine:
    def __init__(self, pack):
        self.pack = pack
        self.ref = None
        self.entities = {}

    _to_plane = _CorrelateEngine._to_plane
    _to_deg = _CorrelateEngine._to_deg

    def _rank(self, ent):
        s = self.pack.sources
        return s.index(ent.source) if ent.source in s else None

    def _rank_key(self, ent):
        r = self._rank(ent)
        return (len(self.pack.sources) if r is None else r, ent.key)

    # operations --------------------------------------------------------
    def ingest(self, report):
        events = []
        for k, kind in REQUIRED:
            if not _is(report.get(k), kind):
                return [{"ev": "reject", "reason": "missing:" + k}], []
        report = _normalize(report)
        if "fuse.group" in report and _group_of(report) is None:
            del report["fuse.group"]
        source = report["track.source_id"]
        key = source + "/" + report["uid"]
        t = report["time_ms"]
        ent = self.entities.get(key)
        if ent is not None and t < ent.last_time_ms:
            return [{"ev": "stale-report", "entity": key, "time_ms": t,
                     "last_time_ms": ent.last_time_ms}], []
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
        group = _group_of(report)
        if ent is None:
            ent = _Entity(key, source)
            self.entities[key] = ent
            vv = (f["vel_sigma_ms"] if vel else f["unknown_vel_ms"]) ** 2
            ent.east = [e, vel[0] if vel else 0.0, ce * ce, 0.0, vv]
            ent.north = [n, vel[1] if vel else 0.0, ce * ce, 0.0, vv]
            events.append({"ev": "new", "entity": key, "group": group})
        else:
            dt = (t - ent.last_time_ms) / 1000.0
            q = f["accel_var"]
            ent.east = _pos_update(_predict_axis(ent.east, dt, q), e, ce * ce)
            ent.north = _pos_update(_predict_axis(ent.north, dt, q), n, ce * ce)
            if vel:
                r = f["vel_sigma_ms"] ** 2
                ent.east = _vel_update(ent.east, vel[0], r)
                ent.north = _vel_update(ent.north, vel[1], r)
            if group != ent.group:
                events.append({"ev": "move", "entity": key, "from": ent.group, "to": group})
        ent.group = group
        ent.report = report
        ent.last_time_ms = t
        return events, []

    def _groups(self):
        named = {}
        alone = []
        for k in sorted(self.entities):
            g = self.entities[k].group
            if g is None:
                alone.append((None, [k]))
            else:
                named.setdefault(g, []).append(k)
        return [(g, named[g]) for g in sorted(named)] + alone

    def _attribute(self, g, members, key, rule, trace):
        cands = []
        for m in members:
            ent = self.entities[m]
            v = ent.report.get(key)
            if v is not None and _usable(v, rule):
                cands.append(ent)
        win = None
        if cands:
            if rule == "priority":
                win = min(cands, key=self._rank_key)
            elif rule == "latest":
                win = min(cands, key=lambda e: (-e.last_time_ms, e.key))
            elif rule == "max":
                win = cands[0]
                for e in cands[1:]:
                    if e.report[key] > win.report[key]:
                        win = e
            elif rule == "min":
                win = cands[0]
                for e in cands[1:]:
                    if e.report[key] < win.report[key]:
                        win = e
            else:  # majority
                firsts, counts = [], []
                for e in cands:
                    for j, h in enumerate(firsts):
                        if _same(h.report[key], e.report[key]):
                            counts[j] += 1
                            break
                    else:
                        firsts.append(e)
                        counts.append(1)
                best = 0
                for j in range(1, len(firsts)):
                    if counts[j] > counts[best]:
                        best = j
                win = firsts[best]
        trace.append({"stage": "attribute", "group": g, "key": key, "rule": rule,
                      "candidates": [{"member": e.key, "value": e.report[key],
                                      "time_ms": e.last_time_ms, "rank": self._rank(e)}
                                     for e in cands],
                      "winner": win.key if win else None,
                      "value": win.report[key] if win else None})
        return win

    def tick(self, now_ms):
        events, trace = [], []
        for k in sorted(self.entities):
            ent = self.entities[k]
            stale = now_ms - ent.last_time_ms > self.pack.stale_ms
            sm = ent.report.get("stale_ms")
            if sm is not None and now_ms >= sm:
                stale = True
            if stale:
                del self.entities[k]
                events.append({"ev": "drop", "entity": k, "group": ent.group})
        q = self.pack.filter["accel_var"]
        method = self.pack.kinematics
        for g, members in self._groups():
            ents = [self.entities[m] for m in members]
            pred = {}
            for e in ents:
                dt = (now_ms - e.last_time_ms) / 1000.0
                pred[e.key] = [_predict_axis(e.east, dt, q), _predict_axis(e.north, dt, q)]
            var = {m: pred[m][0][2] + pred[m][1][2] for m in members}
            src = None
            if method == "inverse_variance":
                est = inverse_variance([pred[m] for m in members])
            elif method == "covariance_intersection":
                est = pred[members[0]]
                for m in members[1:]:
                    w = ci_weight(est, pred[m])
                    trace.append({"stage": "intersect", "group": g, "member": m, "value": w})
                    est = ci_fold(est, pred[m], w)
            else:
                if method == "best":
                    src = min(ents, key=lambda e: (var[e.key], e.key))
                elif method == "priority":
                    src = min(ents, key=self._rank_key)
                else:
                    src = min(ents, key=lambda e: (-e.last_time_ms, e.key))
                est = pred[src.key]
            trace.append({"stage": "kinematics", "group": g, "method": method,
                          "candidates": [{"member": e.key, "var": var[e.key],
                                          "time_ms": e.last_time_ms, "rank": self._rank(e)}
                                         for e in ents],
                          "winner": src.key if src else None})
            east, north = est
            lat, lon = self._to_deg(east[0], north[0])
            course = math.degrees(math.atan2(east[1], north[1]))
            if course < 0:
                course += 360.0
            if course >= 360.0:
                course -= 360.0
            ev = {"ev": "fused", "group": g, "members": list(members),
                  "from": src.key if src else None,
                  "lat": lat, "lon": lon, "course": course,
                  "speed_ms": math.hypot(east[1], north[1]),
                  "ce": math.sqrt((east[2] + north[2]) / 2.0)}
            if src is not None:
                h = src if src.report.get("hae") is not None else None
            else:
                withh = [e for e in ents if e.report.get("hae") is not None]
                h = min(withh, key=lambda e: (-e.last_time_ms, e.key)) if withh else None
            if h is not None:
                ev["hae"] = float(h.report["hae"])
                ev["hae_from"] = h.key
            attrs = {}
            for key, rule in self.pack.attributes:
                win = self._attribute(g, members, key, rule, trace)
                if win is not None:
                    attrs[key] = {"value": win.report[key], "from": win.key}
            ev["attributes"] = attrs
            events.append(ev)
        return events, trace

    def snapshot(self):
        return {
            "ref": list(self.ref) if self.ref else None,
            "entities": {k: {"last_time_ms": e.last_time_ms, "group": e.group,
                             "filter": {"east": list(e.east), "north": list(e.north)},
                             "report": dict(sorted(e.report.items()))}
                         for k, e in sorted(self.entities.items())},
        }
