"""The filter function (spec/filter.md): keep or drop each report by the
first rule whose conditions all hold; forget entities at a tick."""

import math
import re
from types import MappingProxyType
from typing import Callable, FrozenSet, NamedTuple, Tuple

from . import snapshot as _snapshot
from . import trace as _trace
from .io import read_pack_def
from .model import missing_key, normalize
from .packdef import PackError

R = 6371008.8
INT_MAX = 9223372036854775807
NUMBER = re.compile(r"-?[0-9]+(\.[0-9]+)?\Z")
INTEGER = re.compile(r"[0-9]+\Z")
SINGLE = ("pack", "version", "default", "forget_ms")
ACTIONS = ("keep", "drop")


# --- pack values (spec/filter.md, Pack: Values) ---------------------------

def _number(v, what):
    if not NUMBER.match(v):
        raise PackError("%s: not a number: %r" % (what, v))
    return float(v)


def _integer(v, what, minimum):
    if not INTEGER.match(v):
        raise PackError("%s: not an integer: %r" % (what, v))
    digits = v.lstrip("0") or "0"
    if len(digits) > len(str(INT_MAX)):
        raise PackError("%s: out of range: %r" % (what, v))
    x = int(digits, 10)
    if x > INT_MAX or x < minimum:
        raise PackError("%s: out of range: %r" % (what, v))
    return x


def _lat(v, what):
    x = _number(v, what)
    if not -90.0 <= x <= 90.0:
        raise PackError("%s: latitude out of range: %r" % (what, v))
    return x


def _lon(v, what):
    x = _number(v, what)
    if not -180.0 <= x <= 180.0:
        raise PackError("%s: longitude out of range: %r" % (what, v))
    return x


def _list(v, what):
    items = v.split(",")
    if any(i == "" for i in items):
        raise PackError("%s: empty item in list %r" % (what, v))
    return items


def _token(v, what):
    if v == "":
        raise PackError("%s: empty value" % what)
    return v


def _vertices(v, what):
    pairs = v.split(";")
    if len(pairs) < 3:
        raise PackError("%s: a polygon needs at least three vertices" % what)
    out = []
    for p in pairs:
        ll = p.split(",")
        if len(ll) != 2:
            raise PackError("%s: vertex is not <lat>,<lon>: %r" % (what, p))
        out.append((_lat(ll[0], what), _lon(ll[1], what)))
    return out


class Condition:
    """One `when` line: the condition's name, its kind (from the table the
    pack was parsed with), `not`, and its parameters."""

    def __init__(self, name, negated, params, kind=None):
        self.name = name
        self.negated = negated
        self.p = params
        self.kind = kind


class Rule:
    def __init__(self, name, action):
        self.name = name
        self.action = action
        self.conditions = []


class Pack:
    def __init__(self):
        self.name = None
        self.version = None
        self.default = None
        self.forget_ms = None
        self.rules = []


def _condition(args, where, conditions):
    negated = False
    if args and args[0] == "not":
        negated, args = True, args[1:]
    if not args:
        raise PackError("%s: when needs a condition" % where)
    name, raw = args[0], {}
    kind = conditions.get(name)
    if kind is None:
        raise PackError("%s: unknown condition %s" % (where, name))
    for a in args[1:]:
        if "=" not in a:
            raise PackError("%s: parameter without '=': %s" % (where, a))
        k, v = a.split("=", 1)
        if k in raw:
            raise PackError("%s: repeated parameter %s" % (where, k))
        raw[k] = v
    if set(raw) not in kind.params:
        raise PackError("%s: %s does not take parameters %s" % (where, name, sorted(raw)))
    p = {}
    for k, v in raw.items():
        w = "%s %s=" % (where, k)
        if k == "lat":
            p[k] = _lat(v, w)
        elif k == "lon":
            p[k] = _lon(v, w)
        elif k == "radius_m":
            p[k] = _number(v, w)
            if p[k] < 0:
                raise PackError("%s: radius_m below 0" % w)
        elif k in ("min", "max"):
            p[k] = _number(v, w)
        elif k == "max_age_ms":
            p[k] = _integer(v, w, 0)
        elif k == "min_ms":
            p[k] = _integer(v, w, 1)
        elif k == "vertices":
            p[k] = _vertices(v, w)
        elif k == "in":
            p[k] = _list(v, w)
        else:  # reference, name, eq
            p[k] = _token(v, w)
    if "min" in p and "max" in p and p["min"] > p["max"]:
        raise PackError("%s: min above max" % where)
    return Condition(name, negated, p, kind)


def parse_pack(text, conditions=None):
    """A filter pack.def, its `when` lines naming conditions of `conditions`
    (CONDITIONS by default); raises PackError."""
    if conditions is None:
        conditions = CONDITIONS
    pack = Pack()
    seen = set()
    names = set()
    for i, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        d, args = parts[0], parts[1:]
        where = "line %d" % i
        if d in SINGLE:
            if d in seen:
                raise PackError("%s: repeated directive %s" % (where, d))
            seen.add(d)
            if len(args) != 1:
                raise PackError("%s: %s takes one value" % (where, d))
            v = args[0]
            if d == "pack":
                pack.name = v
            elif d == "version":
                pack.version = v
            elif d == "default":
                if v not in ACTIONS:
                    raise PackError("%s: default is keep or drop" % where)
                pack.default = v
            else:
                pack.forget_ms = _integer(v, where + " forget_ms", 1)
        elif d == "rule":
            if len(args) != 2:
                raise PackError("%s: rule takes a name and an action" % where)
            name, action = args
            if action not in ACTIONS:
                raise PackError("%s: rule action is keep or drop" % where)
            if name == "default" or name in names:
                raise PackError("%s: rule name %s is taken" % (where, name))
            names.add(name)
            pack.rules.append(Rule(name, action))
        elif d == "when":
            if not pack.rules:
                raise PackError("%s: when before the first rule" % where)
            pack.rules[-1].conditions.append(_condition(args, where, conditions))
        else:
            raise PackError("%s: unknown directive %s" % (where, d))
    for d in SINGLE:
        if d not in seen:
            raise PackError("missing directive %s" % d)
    for r in pack.rules:
        if not r.conditions:
            raise PackError("rule %s has no condition" % r.name)
    return pack


def load_pack(directory, conditions=None):
    return parse_pack(read_pack_def(directory), conditions)


# --- geometry (spec/filter.md, Geometry) ----------------------------------

def rad(x):
    return x * math.pi / 180.0


def deg(x):
    return x * 180.0 / math.pi


def wrap(x):
    while x > 180.0:
        x -= 360.0
    while x <= -180.0:
        x += 360.0
    return x


def distance(lat1, lon1, lat2, lon2):
    p1, p2 = rad(lat1), rad(lat2)
    dp = rad(lat2 - lat1)
    dl = rad(wrap(lon2 - lon1))
    s1 = math.sin(dp / 2.0)
    s2 = math.sin(dl / 2.0)
    h = s1 * s1 + math.cos(p1) * math.cos(p2) * s2 * s2
    return (2.0 * R) * math.asin(min(1.0, math.sqrt(h)))


def polygon(vertices, lat, lon):
    lon0 = vertices[0][1]
    xs = [lon0] + [lon0 + wrap(v[1] - lon0) for v in vertices[1:]]
    ys = [v[0] for v in vertices]
    px, py = lon0 + wrap(lon - lon0), lat
    n = len(vertices)
    for i in range(n):
        j = (i + 1) % n
        c = (xs[j] - xs[i]) * (py - ys[i]) - (ys[j] - ys[i]) * (px - xs[i])
        if (c == 0.0 and min(xs[i], xs[j]) <= px <= max(xs[i], xs[j])
                and min(ys[i], ys[j]) <= py <= max(ys[i], ys[j])):
            return "boundary"
    inside = False
    for i in range(n):
        j = (i + 1) % n
        if (ys[i] > py) != (ys[j] > py):
            xc = (xs[j] - xs[i]) * (py - ys[i]) / (ys[j] - ys[i]) + xs[i]
            if px < xc:
                inside = not inside
    return "inside" if inside else "outside"


def predict(state, t):
    dt = (t - state["time_ms"]) / 1000.0
    dn = de = 0.0
    if state["course"] is not None and state["speed_ms"] is not None:
        c, s = float(state["course"]), float(state["speed_ms"])
        dn = s * math.cos(rad(c)) * dt
        de = s * math.sin(rad(c)) * dt
    lat = float(state["lat"])
    return lat + deg(dn / R), wrap(float(state["lon"]) + deg(de / (R * math.cos(rad(lat)))))


# --- report helpers (spec/filter.md, Reports) -----------------------------

def environment(report):
    t = report.get("type")
    if t is None:
        return None
    parts = t.split("-")
    return parts[2] if len(parts) >= 3 else None


def affiliation(report):
    t = report.get("type")
    if t is None:
        return None
    parts = t.split("-")
    return parts[1] if len(parts) >= 2 and parts[0] == "a" else None


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def key_equal(v, t):
    """spec/filter.md, Conditions: key equality between report value v and pack text t."""
    if isinstance(v, str):
        return v == t
    if isinstance(v, bool):
        return t == ("true" if v else "false")
    if _is_number(v):
        return bool(NUMBER.match(t)) and float(t) == v
    return False


def _in_range(v, p):
    lo, hi = p.get("min"), p.get("max")
    return (lo is None or lo <= v) and (hi is None or v <= hi)


# --- conditions (spec/filter.md, Conditions) ----------------------------
# Each takes the condition's parameters p, the report, the entity's state
# (or None) and every entity's state (for near), and returns (value, limit,
# result) with result True, False or None (unknown).

def _circle(p, report, state, entities):
    value = distance(float(report["lat"]), float(report["lon"]), p["lat"], p["lon"])
    return value, p["radius_m"], value <= p["radius_m"]


def _polygon(p, report, state, entities):
    value = polygon(p["vertices"], float(report["lat"]), float(report["lon"]))
    return value, None, value != "outside"


def _near(p, report, state, entities):
    t = report["time_ms"]
    ref = entities.get(p["reference"])
    if (ref is None or abs(t - ref["time_ms"]) > p["max_age_ms"]
            or (ref["stale_ms"] is not None and t >= ref["stale_ms"])):
        return None, p["radius_m"], None
    rlat, rlon = predict(ref, t)
    value = distance(float(report["lat"]), float(report["lon"]), rlat, rlon)
    return value, p["radius_m"], value <= p["radius_m"]


def _member_of(read):
    """env, affiliation, source, uid: the value read from the report is in the list."""
    def evaluate(p, report, state, entities):
        value = read(report)
        if value is None:
            return None, list(p["in"]), None
        return value, list(p["in"]), value in p["in"]
    return evaluate


def _key(p, report, state, entities):
    value = report.get(p["name"])
    if "eq" in p:
        limit = p["eq"]
    elif "in" in p:
        limit = list(p["in"])
    else:
        limit = [p.get("min"), p.get("max")]
    if value is None:
        return None, limit, None
    if "eq" in p:
        return value, limit, key_equal(value, p["eq"])
    if "in" in p:
        return value, limit, any(key_equal(value, x) for x in p["in"])
    if not _is_number(value):
        return value, limit, None
    return value, limit, _in_range(value, p)


def _has(p, report, state, entities):
    value = report.get(p["name"]) is not None
    return value, None, value


def _range_of(key):
    """speed, altitude: the report's key is within [min, max]."""
    def evaluate(p, report, state, entities):
        value = report.get(key)
        limit = [p.get("min"), p.get("max")]
        if value is None:
            return None, limit, None
        return value, limit, _in_range(value, p)
    return evaluate


def _interval(p, report, state, entities):
    kept = state["kept_ms"] if state else None
    value = None if kept is None else report["time_ms"] - kept
    return value, p["min_ms"], value is not None and value < p["min_ms"]


def _order(p, report, state, entities):
    kept = state["kept_ms"] if state else None
    t = report["time_ms"]
    return t, kept, kept is not None and t < kept


class ConditionKind(NamedTuple):
    """One condition: the parameter sets it accepts (any one of them, by
    name) and evaluate(p, report, state, entities)."""
    params: Tuple[FrozenSet[str], ...]
    evaluate: Callable


def _sets(*sets):
    return tuple(frozenset(x) for x in sets)


RANGE_SETS = _sets({"min"}, {"max"}, {"min", "max"})

# The one table of conditions.
CONDITIONS = MappingProxyType({
    "circle": ConditionKind(_sets({"lat", "lon", "radius_m"}), _circle),
    "polygon": ConditionKind(_sets({"vertices"}), _polygon),
    "near": ConditionKind(_sets({"reference", "radius_m", "max_age_ms"}), _near),
    "env": ConditionKind(_sets({"in"}), _member_of(environment)),
    "affiliation": ConditionKind(_sets({"in"}), _member_of(affiliation)),
    "source": ConditionKind(_sets({"in"}), _member_of(lambda r: r["track.source_id"])),
    "uid": ConditionKind(_sets({"in"}), _member_of(lambda r: r["uid"])),
    "key": ConditionKind(_sets({"name", "eq"}, {"name", "in"}) + tuple(s | {"name"} for s in RANGE_SETS), _key),
    "has": ConditionKind(_sets({"name"}), _has),
    "speed": ConditionKind(RANGE_SETS, _range_of("speed_ms")),
    "altitude": ConditionKind(RANGE_SETS, _range_of("hae")),
    "interval": ConditionKind(_sets({"min_ms"}), _interval),
    "order": ConditionKind(_sets(set()), _order),
})


def extend_conditions(conditions, name, kind):
    """A new table: `conditions` with one more condition. The table given is unchanged."""
    if name in conditions:
        raise ValueError("condition %s is already in the table" % name)
    out = dict(conditions)
    out[name] = kind
    return MappingProxyType(out)


def evaluate(cond, report, state, entities):
    """Conditions: one condition on a report. Returns (value, limit, result)."""
    return cond.kind.evaluate(cond.p, report, state, entities)


# --- engine ---------------------------------------------------------------

class Engine:
    def __init__(self, pack):
        self.pack = pack
        self.entities = {}

    def ingest(self, report):
        k = missing_key(report)
        if k is not None:
            return [{"ev": "reject", "reason": "missing:" + k}], []
        report = normalize(report)
        key = report["track.source_id"] + "/" + report["uid"]
        t = report["time_ms"]
        state = self.entities.get(key)
        trace = []
        decided, action = "default", self.pack.default
        for rule in self.pack.rules:
            matched = True
            for cond in rule.conditions:
                value, limit, result = evaluate(cond, report, state, self.entities)
                passed = result is not None and (result != cond.negated)
                trace.append(_trace.filter_rule(rule.name, key, cond.name, cond.negated,
                                                value, limit, passed, result is None))
                if not passed:
                    matched = False
                    break
            if matched:
                decided, action = rule.name, rule.action
                break
        # State, after the decision.
        if state is None:
            state = {"kept_ms": None}
            self.entities[key] = state
            newer = True
        else:
            newer = t >= state["time_ms"]
        if newer:
            state["time_ms"] = t
            for k in ("lat", "lon", "course", "speed_ms", "stale_ms"):
                state[k] = report.get(k)
        if action == "keep" and (state["kept_ms"] is None or state["kept_ms"] < t):
            state["kept_ms"] = t
        return [{"ev": action, "entity": key, "rule": decided}], trace

    def tick(self, now_ms):
        events, trace = [], []
        for k in sorted(self.entities):
            age = now_ms - self.entities[k]["time_ms"]
            gone = age > self.pack.forget_ms
            trace.append(_trace.filter_forget(k, age, self.pack.forget_ms, gone))
            if gone:
                del self.entities[k]
                events.append({"ev": "forget", "entity": k})
        return events, trace

    def snapshot(self):
        return _snapshot.filter_(self)


def make_engine(pack):
    return Engine(pack)


def restore(pack, snap):
    """An engine of `pack` in the state `snap` (a snapshot() of one)."""
    return _snapshot.restore_filter(Engine(pack), snap)
