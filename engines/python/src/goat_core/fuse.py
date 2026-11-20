"""The fuse function (spec/fuse.md): one estimate per group of tracks
(those whose reports carry the same fuse.group), by the pack's kinematics
method, and each attribute by its rule. The per-entity filter, the frame
and report validation are correlate's (model.py, estimate.py)."""

import math
import re
from types import MappingProxyType

from . import estimate
from . import snapshot as _snapshot
from . import trace as _trace
from . import trace as _trace
from .model import course_deg, missing_key, normalize, to_deg, to_plane, velocity
from .packdef import PackError, decimal_int, read_pack_def

FILTER_PARAMS = ("accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms")
ONCE = ("pack", "version", "filter", "kinematics", "stale_ms")
NUMBER = re.compile(r"-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?\Z")
INTEGER = re.compile(r"[0-9]+\Z")


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
            if len(args) != 1 or args[0] not in KINEMATICS:
                raise PackError("line %d: kinematics is one of %s" % (i, ", ".join(KINEMATICS)))
            p.kinematics = args[0]
        elif d == "stale_ms":
            if len(args) != 1 or not INTEGER.match(args[0]):
                raise PackError("line %d: stale_ms takes one integer, 0 or above" % i)
            p.stale_ms = decimal_int(args[0], "line %d: stale_ms" % i)
        elif d == "attribute":
            if len(args) != 2:
                raise PackError("line %d: attribute takes a key and rule=<rule>" % i)
            key, prm = args
            if "=" in key:
                raise PackError("line %d: attribute key cannot contain '='" % i)
            if "=" not in prm:
                raise PackError("line %d: parameter without '=': %s" % (i, prm))
            k, v = prm.split("=", 1)
            if k != "rule" or v not in ATTRIBUTE_RULES:
                raise PackError("line %d: attribute needs rule=%s" % (i, "|".join(ATTRIBUTE_RULES)))
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
    return parse_pack(read_pack_def(directory))


def _group_of(report):
    g = report.get("fuse.group")
    return g if isinstance(g, str) and g != "" else None


def _usable(v, rule):
    """Attributes: a value the rule can use (a number; a string or boolean
    too unless the rule takes numbers only)."""
    return _usable_value(v, ATTRIBUTE_RULES[rule].numbers_only)


def _usable_value(v, numbers_only):
    if isinstance(v, (bool, str)):
        return not numbers_only
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


inverse_variance = estimate.inverse_variance


def _latest_key(e):
    """latest: the member reported last, ties to the smaller key."""
    return (-e.last_time_ms, e.key)


# --- kinematics (spec/fuse.md, Kinematics) --------------------------------
# Each takes the group's members ents (key order), their predictions pred and
# position variances var, and the priority order rank_key; it returns
# (estimate, the member it came from or None, the covariance intersection
# weights as (member, w)).

def _inverse_variance(ents, pred, var, rank_key):
    return inverse_variance([pred[e.key] for e in ents]), None, []


def _covariance_intersection(ents, pred, var, rank_key):
    est = pred[ents[0].key]
    weights = []
    for e in ents[1:]:
        w = ci_weight(est, pred[e.key])
        weights.append((e.key, w))
        est = ci_fold(est, pred[e.key], w)
    return est, None, weights


def _choose(key_of):
    """best, priority, latest: one member's prediction, the least by key_of."""
    def method(ents, pred, var, rank_key):
        src = min(ents, key=key_of(var, rank_key))
        return pred[src.key], src, []
    return method


# The one table of kinematics methods.
KINEMATICS = MappingProxyType({
    "inverse_variance": _inverse_variance,
    "covariance_intersection": _covariance_intersection,
    "best": _choose(lambda var, rank_key: lambda e: (var[e.key], e.key)),
    "priority": _choose(lambda var, rank_key: rank_key),
    "latest": _choose(lambda var, rank_key: _latest_key),
})


def kinematics(method, ents, pred, var, rank_key):
    """Kinematics: the estimate of one group by `method`."""
    return KINEMATICS[method](ents, pred, var, rank_key)


def height_source(ents, src):
    """Fused event, hae: the chosen member's, or for a combining method the
    latest member with one."""
    if src is not None:
        return src if src.report.get("hae") is not None else None
    withh = [e for e in ents if e.report.get("hae") is not None]
    return min(withh, key=_latest_key) if withh else None


# --- attributes (spec/fuse.md, Attributes) --------------------------------
# Each takes the candidates (key order, each holding a usable value of key),
# the key and the priority order, and returns the winning member.

def _max_or_min(better):
    def rule(cands, key, rank_key):
        win = cands[0]
        for e in cands[1:]:
            if better(e.report[key], win.report[key]):
                win = e
        return win
    return rule


def _majority(cands, key, rank_key):
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
    return firsts[best]


class AttributeRule:
    """One attribute rule: winner(cands, key, rank_key), and whether it
    takes numbers only (a string or boolean value is then not usable)."""

    __slots__ = ("winner", "numbers_only")

    def __init__(self, winner, numbers_only=False):
        self.winner = winner
        self.numbers_only = numbers_only


# The one table of attribute rules.
ATTRIBUTE_RULES = MappingProxyType({
    "priority": AttributeRule(lambda cands, key, rank_key: min(cands, key=rank_key)),
    "latest": AttributeRule(lambda cands, key, rank_key: min(cands, key=_latest_key)),
    "majority": AttributeRule(_majority),
    "max": AttributeRule(_max_or_min(lambda a, b: a > b), numbers_only=True),
    "min": AttributeRule(_max_or_min(lambda a, b: a < b), numbers_only=True),
})


def attribute_winner(cands, key, rule, rank_key):
    """Attributes: the member whose value of `key` wins by `rule`, or None
    without a candidate."""
    if not cands:
        return None
    return ATTRIBUTE_RULES[rule].winner(cands, key, rank_key)


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
        self.ranks = {src: i for i, src in enumerate(pack.sources)}  # from the pack, not state

    def _to_plane(self, lat, lon):
        return to_plane(self.ref, lat, lon)

    def _to_deg(self, east, north):
        return to_deg(self.ref, east, north)

    def _rank(self, ent):
        """Pack: a source's rank is its line's place among the source lines."""
        return self.ranks.get(ent.source)

    def _rank_key(self, ent):
        r = self.ranks.get(ent.source)
        return (len(self.pack.sources) if r is None else r, ent.key)

    # operations --------------------------------------------------------
    def ingest(self, report):
        events = []
        k = missing_key(report)
        if k is not None:
            return [{"ev": "reject", "reason": "missing:" + k}], []
        report = normalize(report)
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
        e, n = to_plane(self.ref, lat, lon)
        f = self.pack.filter
        vel = None
        if report.get("course") is not None and report.get("speed_ms") is not None:
            vel = velocity(float(report["course"]), float(report["speed_ms"]))
        ce = f["default_ce_m"] if report.get("ce") is None else float(report["ce"])
        group = _group_of(report)
        if ent is None:
            ent = _Entity(key, source)
            self.entities[key] = ent
            ent.east, ent.north = estimate.first_axes(e, n, ce * ce, ce * ce, vel, f)
            events.append({"ev": "new", "entity": key, "group": group})
        else:
            dt = (t - ent.last_time_ms) / 1000.0
            ent.east, ent.north = estimate.update_axes(
                ent.east, ent.north, dt, f["accel_var"], e, n, ce * ce, ce * ce, vel,
                f["vel_sigma_ms"] ** 2)
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
        numbers_only = ATTRIBUTE_RULES[rule].numbers_only
        cands = []
        entities = self.entities
        for m in members:
            ent = entities[m]
            v = ent.report.get(key)
            if v is not None and _usable_value(v, numbers_only):
                cands.append(ent)
        win = attribute_winner(cands, key, rule, self._rank_key)
        trace.append(_trace.fuse_attribute(
            g, key, rule, _trace.fuse_attribute_candidates(cands, key, self.ranks),
            win.key if win else None, win.report[key] if win else None))
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
        combine = KINEMATICS[method]
        rank_key = self._rank_key
        predict_axis = estimate.predict_axis
        entities = self.entities
        for g, members in self._groups():
            ents = [entities[m] for m in members]
            pred = {}
            for e in ents:
                dt = (now_ms - e.last_time_ms) / 1000.0
                pred[e.key] = [predict_axis(e.east, dt, q), predict_axis(e.north, dt, q)]
            var = {m: pred[m][0][2] + pred[m][1][2] for m in members}
            est, src, weights = combine(ents, pred, var, rank_key)
            for m, w in weights:
                trace.append(_trace.fuse_intersect(g, m, w))
            trace.append(_trace.fuse_kinematics(
                g, method,
                _trace.fuse_candidates(ents, var, self.ranks),
                src.key if src else None))
            east, north = est
            lat, lon = to_deg(self.ref, east[0], north[0])
            course = course_deg(east[1], north[1])
            ev = {"ev": "fused", "group": g, "members": list(members),
                  "from": src.key if src else None,
                  "lat": lat, "lon": lon, "course": course,
                  "speed_ms": math.hypot(east[1], north[1]),
                  "ce": math.sqrt((east[2] + north[2]) / 2.0)}
            h = height_source(ents, src)
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
        return _snapshot.fuse(self)


def make_engine(pack):
    return Engine(pack)


def restore(pack, snap):
    """An engine of `pack` in the state `snap` (a snapshot() of one)."""
    return _snapshot.restore_fuse(Engine(pack), snap, _Entity)
