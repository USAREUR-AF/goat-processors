"""Filter engine (spec/filter.md 0.1). Standard library only."""

import math
import os
import re

# Report validation is the correlate function's (spec/filter.md, Reports).
from goat_correlator.engine import REQUIRED, _is, _normalize

R = 6371008.8
INT_MAX = 9223372036854775807
NUMBER = re.compile(r"-?[0-9]+(\.[0-9]+)?\Z")
INTEGER = re.compile(r"[0-9]+\Z")
SINGLE = ("pack", "version", "default", "forget_ms")
ACTIONS = ("keep", "drop")
RANGE_SETS = ({"min"}, {"max"}, {"min", "max"})
PARAMS = {
    "circle": [{"lat", "lon", "radius_m"}],
    "polygon": [{"vertices"}],
    "near": [{"reference", "radius_m", "max_age_ms"}],
    "env": [{"in"}],
    "affiliation": [{"in"}],
    "source": [{"in"}],
    "uid": [{"in"}],
    "key": [{"name", "eq"}, {"name", "in"}] + [{"name"} | s for s in RANGE_SETS],
    "has": [{"name"}],
    "speed": list(RANGE_SETS),
    "altitude": list(RANGE_SETS),
    "interval": [{"min_ms"}],
    "order": [set()],
}


class PackError(Exception):
    pass


# --- pack values (spec/filter.md, Pack: Values) ---------------------------

def _number(v, what):
    if not NUMBER.match(v):
        raise PackError("%s: not a number: %r" % (what, v))
    return float(v)


def _integer(v, what, minimum):
    if not INTEGER.match(v):
        raise PackError("%s: not an integer: %r" % (what, v))
    x = int(v, 10)
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
    def __init__(self, name, negated, params):
        self.name = name
        self.negated = negated
        self.p = params


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


def _condition(args, where):
    negated = False
    if args and args[0] == "not":
        negated, args = True, args[1:]
    if not args:
        raise PackError("%s: when needs a condition" % where)
    name, raw = args[0], {}
    if name not in PARAMS:
        raise PackError("%s: unknown condition %s" % (where, name))
    for a in args[1:]:
        if "=" not in a:
            raise PackError("%s: parameter without '=': %s" % (where, a))
        k, v = a.split("=", 1)
        if k in raw:
            raise PackError("%s: repeated parameter %s" % (where, k))
        raw[k] = v
    if set(raw) not in PARAMS[name]:
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
    return Condition(name, negated, p)


def parse_pack(text):
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
            pack.rules[-1].conditions.append(_condition(args, where))
        else:
            raise PackError("%s: unknown directive %s" % (where, d))
    for d in SINGLE:
        if d not in seen:
            raise PackError("missing directive %s" % d)
    for r in pack.rules:
        if not r.conditions:
            raise PackError("rule %s has no condition" % r.name)
    return pack


def load_pack(directory):
    with open(os.path.join(directory, "pack.def"), encoding="utf-8") as f:
        return parse_pack(f.read())


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


# --- engine ---------------------------------------------------------------

class Engine:
    def __init__(self, pack):
        self.pack = pack
        self.entities = {}

    def _evaluate(self, cond, report, key, state):
        """One condition: returns (value, limit, result) with result True, False or None (unknown)."""
        p, name = cond.p, cond.name
        lat, lon, t = float(report["lat"]), float(report["lon"]), report["time_ms"]
        if name == "circle":
            value = distance(lat, lon, p["lat"], p["lon"])
            return value, p["radius_m"], value <= p["radius_m"]
        if name == "polygon":
            value = polygon(p["vertices"], lat, lon)
            return value, None, value != "outside"
        if name == "near":
            ref = self.entities.get(p["reference"])
            if (ref is None or abs(t - ref["time_ms"]) > p["max_age_ms"]
                    or (ref["stale_ms"] is not None and t >= ref["stale_ms"])):
                return None, p["radius_m"], None
            rlat, rlon = predict(ref, t)
            value = distance(lat, lon, rlat, rlon)
            return value, p["radius_m"], value <= p["radius_m"]
        if name in ("env", "affiliation", "source", "uid"):
            value = {"env": environment, "affiliation": affiliation,
                     "source": lambda r: r["track.source_id"], "uid": lambda r: r["uid"]}[name](report)
            if value is None:
                return None, list(p["in"]), None
            return value, list(p["in"]), value in p["in"]
        if name == "key":
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
        if name == "has":
            value = report.get(p["name"]) is not None
            return value, None, value
        if name in ("speed", "altitude"):
            value = report.get("speed_ms" if name == "speed" else "hae")
            limit = [p.get("min"), p.get("max")]
            if value is None:
                return None, limit, None
            return value, limit, _in_range(value, p)
        kept = state["kept_ms"] if state else None
        if name == "interval":
            value = None if kept is None else t - kept
            return value, p["min_ms"], value is not None and value < p["min_ms"]
        if name == "order":
            return t, kept, kept is not None and t < kept
        raise AssertionError(name)

    def ingest(self, report):
        for k, kind in REQUIRED:
            if not _is(report.get(k), kind):
                return [{"ev": "reject", "reason": "missing:" + k}], []
        report = _normalize(report)
        key = report["track.source_id"] + "/" + report["uid"]
        t = report["time_ms"]
        state = self.entities.get(key)
        trace = []
        decided, action = "default", self.pack.default
        for rule in self.pack.rules:
            matched = True
            for cond in rule.conditions:
                value, limit, result = self._evaluate(cond, report, key, state)
                passed = result is not None and (result != cond.negated)
                rec = {"stage": "rule", "rule": rule.name, "entity": key, "test": cond.name,
                       "negated": cond.negated, "value": value, "limit": limit, "pass": passed}
                if result is None:
                    rec["unknown"] = True
                trace.append(rec)
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
            trace.append({"stage": "forget", "entity": k, "test": "age", "value": age,
                          "limit": self.pack.forget_ms, "pass": gone})
            if gone:
                del self.entities[k]
                events.append({"ev": "forget", "entity": k})
        return events, trace

    def snapshot(self):
        fields = ("time_ms", "lat", "lon", "course", "speed_ms", "stale_ms", "kept_ms")
        return {"entities": {k: {f: s[f] for f in fields} for k, s in sorted(self.entities.items())}}


def make_engine(pack):
    return Engine(pack)
