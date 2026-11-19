"""Quality engine (spec/quality.md 0.1). Standard library only.

The per-entity filter is the correlate filter (spec/correlate.md, Track
estimate), imported from goat_correlator."""

import math
import os
import re

from goat_correlator.engine import R, _predict_axis, _pos_update, _vel_update, _wrap180

FILTER_PARAMS = ("accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms")
WINDOW_PARAMS = ("window_ms", "min_samples", "forget_ms")
RULE_PARAMS = ("scope", "measure", "op", "limit", "for", "clear", "action")
REQUIRED = (("track.source_id", "str"), ("uid", "str"), ("time_ms", "int"),
            ("lat", "num"), ("lon", "num"))

# Entity measures, in the order of the spec's measures table, with the way a
# source aggregates each over its entities.
MEASURES = (
    ("reports", "sum"),
    ("interval_last", "mean"),
    ("interval_mean", "mean"),
    ("interval_max", "max"),
    ("age", "min"),
    ("latency_mean", "mean"),
    ("latency_max", "max"),
    ("nis_mean", "mean"),
    ("speed_err_mean", "mean"),
    ("out_of_order", "sum"),
    ("duplicate", "sum"),
    ("missing_ce", "mean"),
    ("missing_vel", "mean"),
    ("missing_hae", "mean"),
)
ENTITY_MEASURES = tuple(m for m, _ in MEASURES)
SOURCE_MEASURES = ENTITY_MEASURES + ("entities",)
OPS = ("<", "<=", ">", ">=")
ACTIONS = ("mark", "downgrade", "drop", "alert")

NUM_RE = re.compile(r"-?[0-9]+(\.[0-9]+)?\Z")
INT_RE = re.compile(r"[0-9]+\Z")
NAME_RE = re.compile(r"[A-Za-z0-9._-]+\Z")


def _is(v, kind):
    if isinstance(v, bool) or v is None:
        return False
    if kind == "str":
        return isinstance(v, str)
    if kind == "int":
        return isinstance(v, int)
    return isinstance(v, (int, float))


class PackError(Exception):
    pass


class Rule:
    def __init__(self, name, scope, measure, op, limit, n, clear, action, factor):
        self.name, self.scope, self.measure, self.op = name, scope, measure, op
        self.limit, self.n, self.clear, self.action, self.factor = limit, n, clear, action, factor


class Pack:
    def __init__(self):
        self.name = None
        self.version = None
        self.filter = None
        self.window_ms = None
        self.min_samples = None
        self.forget_ms = None
        self.rules = []


def _num(v, line_no):
    if not NUM_RE.match(v):
        raise PackError("line %d: not a decimal number: %s" % (line_no, v))
    return float(v)


def _int(v, line_no):
    if not INT_RE.match(v):
        raise PackError("line %d: not an integer: %s" % (line_no, v))
    return int(v, 10)


def _params(args, line_no, allowed, required):
    out = {}
    for a in args:
        if "=" not in a:
            raise PackError("line %d: parameter without '=': %s" % (line_no, a))
        k, v = a.split("=", 1)
        if k in out:
            raise PackError("line %d: repeated parameter %s" % (line_no, k))
        if k not in allowed:
            raise PackError("line %d: unknown parameter %s" % (line_no, k))
        out[k] = v
    for k in required:
        if k not in out:
            raise PackError("line %d: missing parameter %s" % (line_no, k))
    return out


def parse_pack(text):
    p = Pack()
    seen = set()
    names = set()
    for i, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        d, args = parts[0], parts[1:]
        if d in ("pack", "version", "filter", "window"):
            if d in seen:
                raise PackError("line %d: repeated directive %s" % (i, d))
            seen.add(d)
        if d in ("pack", "version"):
            if len(args) != 1:
                raise PackError("line %d: %s takes one value" % (i, d))
            setattr(p, "name" if d == "pack" else "version", args[0])
        elif d == "filter":
            kv = _params(args, i, FILTER_PARAMS, FILTER_PARAMS)
            p.filter = {k: _num(v, i) for k, v in kv.items()}
            if p.filter["accel_var"] < 0 or min(p.filter[k] for k in FILTER_PARAMS[1:]) <= 0:
                raise PackError("line %d: filter variances must be above 0 (accel_var 0 or above)" % i)
        elif d == "window":
            kv = _params(args, i, WINDOW_PARAMS, WINDOW_PARAMS)
            p.window_ms = _int(kv["window_ms"], i)
            p.min_samples = _int(kv["min_samples"], i)
            p.forget_ms = _int(kv["forget_ms"], i)
            if p.window_ms < 1 or p.min_samples < 1 or p.forget_ms < 1:
                raise PackError("line %d: window_ms, min_samples and forget_ms must be 1 or above" % i)
        elif d == "rule":
            if not args or "=" in args[0]:
                raise PackError("line %d: rule needs a name" % i)
            name = args[0]
            if not NAME_RE.match(name):
                raise PackError("line %d: rule name must be letters, digits, '.', '_' or '-'" % i)
            if name in names:
                raise PackError("line %d: repeated rule name %s" % (i, name))
            names.add(name)
            kv = _params(args[1:], i, RULE_PARAMS + ("factor",), RULE_PARAMS)
            scope, measure, op, action = kv["scope"], kv["measure"], kv["op"], kv["action"]
            if scope not in ("entity", "source"):
                raise PackError("line %d: scope is entity or source" % i)
            if measure not in (ENTITY_MEASURES if scope == "entity" else SOURCE_MEASURES):
                raise PackError("line %d: no measure %s for scope %s" % (i, measure, scope))
            if op not in OPS:
                raise PackError("line %d: op is <, <=, > or >=" % i)
            if action not in ACTIONS:
                raise PackError("line %d: action is mark, downgrade, drop or alert" % i)
            limit, clear = _num(kv["limit"], i), _num(kv["clear"], i)
            n = _int(kv["for"], i)
            if n < 1:
                raise PackError("line %d: for must be 1 or above" % i)
            if (op in (">", ">=") and clear > limit) or (op in ("<", "<=") and clear < limit):
                raise PackError("line %d: clear is on the wrong side of limit" % i)
            factor = None
            if action == "downgrade":
                if "factor" not in kv:
                    raise PackError("line %d: downgrade needs factor" % i)
                factor = _num(kv["factor"], i)
                if factor < 1:
                    raise PackError("line %d: factor must be 1 or above" % i)
            elif "factor" in kv:
                raise PackError("line %d: factor is only for downgrade" % i)
            p.rules.append(Rule(name, scope, measure, op, limit, n, clear, action, factor))
        else:
            raise PackError("line %d: unknown directive %s" % (i, d))
    for d in ("pack", "version", "filter", "window"):
        if d not in seen:
            raise PackError("missing directive %s" % d)
    return p


def load_pack(directory):
    with open(os.path.join(directory, "pack.def"), encoding="utf-8") as f:
        return parse_pack(f.read())


class _Entity:
    def __init__(self, key, source):
        self.key = key
        self.source = source
        self.last_time_ms = None
        self.last_pos = None
        self.east = None
        self.north = None
        self.window = []


def _mean(xs):
    s = 0.0
    for x in xs:
        s += x
    return s / len(xs)


def _met(op, v, x):
    if op == "<":
        return v < x
    if op == "<=":
        return v <= x
    if op == ">":
        return v > x
    return v >= x


class Engine:
    def __init__(self, pack):
        self.pack = pack
        self.ref = None
        self.last_tick = None
        self.entities = {}
        self.rules = {r.name: {} for r in pack.rules}

    def _to_plane(self, lat, lon):
        lat0, lon0 = self.ref
        dlon = _wrap180(lon - lon0)
        return (R * math.radians(dlon) * math.cos(math.radians(lat0)),
                R * math.radians(lat - lat0))

    def _active(self, rule, subject):
        st = self.rules[rule.name].get(subject)
        return st is not None and st["active"]

    # ingest ------------------------------------------------------------
    def ingest(self, report):
        events, trace = [], []
        for k, kind in REQUIRED:
            if not _is(report.get(k), kind):
                events.append({"ev": "reject", "reason": "missing:" + k})
                return events, trace
        opt = {}
        for k in ("hae", "ce", "course", "speed_ms"):
            if _is(report.get(k), "num"):
                opt[k] = float(report[k])
        if "ce" in opt and opt["ce"] <= 0:
            del opt["ce"]
        if _is(report.get("received_ms"), "int"):
            opt["received_ms"] = report["received_ms"]
        source = report["track.source_id"]
        key = source + "/" + report["uid"]
        t = report["time_ms"]
        lat, lon = float(report["lat"]), float(report["lon"])
        if self.ref is None:
            self.ref = (lat, lon)
        f = self.pack.filter
        ent = self.entities.get(key)
        last = None if ent is None else ent.last_time_ms
        if ent is None:
            order = "first"
        elif t > last:
            order = "advance"
        elif t == last:
            order = "duplicate"
        else:
            order = "out-of-order"
        rec = {"wt": t if last is None or t > last else last, "time_ms": t, "order": order,
               "interval": None, "latency": None, "nis": None, "speed_err": None,
               "ce": "ce" in opt, "vel": "course" in opt and "speed_ms" in opt, "hae": "hae" in opt}
        trace.append({"stage": "sample", "entity": key, "sample": "order", "value": order,
                      "inputs": [t, last]})
        if order == "advance":
            rec["interval"] = t - last
            trace.append({"stage": "sample", "entity": key, "sample": "interval",
                          "value": rec["interval"], "inputs": [t, last]})
        if "received_ms" in opt:
            rec["latency"] = opt["received_ms"] - t
            trace.append({"stage": "sample", "entity": key, "sample": "latency",
                          "value": rec["latency"], "inputs": [opt["received_ms"], t]})
        e, n = self._to_plane(lat, lon)
        ce = opt.get("ce", f["default_ce_m"])
        r = ce * ce
        vel = None
        if rec["vel"]:
            c = math.radians(opt["course"])
            vel = (opt["speed_ms"] * math.sin(c), opt["speed_ms"] * math.cos(c))
        if order == "first":
            ent = _Entity(key, source)
            self.entities[key] = ent
            vv = (f["vel_sigma_ms"] if vel else f["unknown_vel_ms"]) ** 2
            ent.east = [e, vel[0] if vel else 0.0, r, 0.0, vv]
            ent.north = [n, vel[1] if vel else 0.0, r, 0.0, vv]
            ent.last_time_ms = t
            ent.last_pos = [e, n]
            events.append({"ev": "new", "entity": key})
        elif order == "advance":
            dt = (t - last) / 1000.0
            q = f["accel_var"]
            pe = _predict_axis(ent.east, dt, q)
            pn = _predict_axis(ent.north, dt, q)
            de, dn = e - pe[0], n - pn[0]
            se, sn = pe[2] + r, pn[2] + r
            rec["nis"] = de * de / se + dn * dn / sn
            trace.append({"stage": "sample", "entity": key, "sample": "nis",
                          "value": rec["nis"], "inputs": [de, dn, se, sn]})
            if "speed_ms" in opt:
                implied = math.hypot(e - ent.last_pos[0], n - ent.last_pos[1]) / dt
                rec["speed_err"] = abs(implied - opt["speed_ms"])
                trace.append({"stage": "sample", "entity": key, "sample": "speed_err",
                              "value": rec["speed_err"], "inputs": [implied, opt["speed_ms"]]})
            ent.east = _pos_update(pe, e, r)
            ent.north = _pos_update(pn, n, r)
            if vel:
                rv = f["vel_sigma_ms"] ** 2
                ent.east = _vel_update(ent.east, vel[0], rv)
                ent.north = _vel_update(ent.north, vel[1], rv)
            ent.last_time_ms = t
            ent.last_pos = [e, n]
        ent.window.append(rec)

        # Actions on the forwarded report.
        applied, marks, factors, withheld = [], [], [], False
        for rule in self.pack.rules:
            if rule.action == "alert":
                continue
            subject = key if rule.scope == "entity" else source
            if not self._active(rule, subject):
                continue
            applied.append(rule.name)
            if rule.action == "drop":
                withheld = True
            elif rule.action == "mark":
                marks.append(rule.name)
            else:
                factors.append(rule.factor)
        ev = {"ev": "pass", "entity": key, "rules": applied, "withheld": withheld}
        if not withheld:
            out = dict(report)
            if factors:
                x = opt.get("ce", f["default_ce_m"])
                for fa in factors:
                    x = x * fa
                out["ce"] = x
            if marks:
                old = report.get("quality.marks")
                lst = list(old) if isinstance(old, list) and all(isinstance(m, str) for m in old) else []
                for m in marks:
                    if m not in lst:
                        lst.append(m)
                out["quality.marks"] = lst
            ev["report"] = out
        events.append(ev)
        return events, trace

    # measures ----------------------------------------------------------
    def _entity_measures(self, ent, now):
        w = ent.window
        k = self.pack.min_samples
        iv = [x["interval"] for x in w if x["interval"] is not None]
        lt = [x["latency"] for x in w if x["latency"] is not None]
        ns = [x["nis"] for x in w if x["nis"] is not None]
        se = [x["speed_err"] for x in w if x["speed_err"] is not None]
        enough = len(w) >= k
        return {
            "reports": len(w),
            "interval_last": iv[-1] if len(iv) >= k else None,
            "interval_mean": _mean(iv) if len(iv) >= k else None,
            "interval_max": max(iv) if len(iv) >= k else None,
            "age": now - ent.last_time_ms,
            "latency_mean": _mean(lt) if len(lt) >= k else None,
            "latency_max": max(lt) if len(lt) >= k else None,
            "nis_mean": _mean(ns) if len(ns) >= k else None,
            "speed_err_mean": _mean(se) if len(se) >= k else None,
            "out_of_order": sum(1 for x in w if x["order"] == "out-of-order"),
            "duplicate": sum(1 for x in w if x["order"] == "duplicate"),
            "missing_ce": sum(1 for x in w if not x["ce"]) / len(w) if enough else None,
            "missing_vel": sum(1 for x in w if not x["vel"]) / len(w) if enough else None,
            "missing_hae": sum(1 for x in w if not x["hae"]) / len(w) if enough else None,
        }

    @staticmethod
    def _source_measures(ms):
        out = {}
        for m, how in MEASURES:
            xs = [x[m] for x in ms if x[m] is not None]
            if how == "sum":
                out[m] = sum(xs)
            elif not xs:
                out[m] = None
            elif how == "mean":
                out[m] = _mean(xs)
            elif how == "max":
                out[m] = max(xs)
            else:
                out[m] = min(xs)
        out["entities"] = len(ms)
        return out

    def _evaluate(self, scope, subject, measures, events, trace):
        for rule in self.pack.rules:
            if rule.scope != scope:
                continue
            st = self.rules[rule.name].setdefault(subject, {"count": 0, "active": False})
            v = measures[rule.measure]
            if not st["active"]:
                ok = v is not None and _met(rule.op, v, rule.limit)
                st["count"] = st["count"] + 1 if ok else 0
                limit = rule.limit
                if st["count"] >= rule.n:
                    st["active"] = True
                    st["count"] = 0
                    events.append({"ev": "action-start", "rule": rule.name, "scope": scope,
                                   "subject": subject, "action": rule.action, "value": v})
            else:
                limit = rule.clear
                ok = v is not None and (v < rule.clear if rule.op in (">", ">=") else v > rule.clear)
                if ok:
                    st["active"] = False
                    events.append({"ev": "action-end", "rule": rule.name, "scope": scope,
                                   "subject": subject, "action": rule.action,
                                   "reason": "clear", "value": v})
            trace.append({"stage": "rule", "rule": rule.name, "subject": subject,
                          "measure": rule.measure, "value": v, "limit": limit, "pass": ok,
                          "count": st["count"], "active": st["active"]})

    def _forget_subject(self, scope, subject, events):
        for rule in self.pack.rules:
            if rule.scope != scope:
                continue
            st = self.rules[rule.name].pop(subject, None)
            if st is not None and st["active"]:
                events.append({"ev": "action-end", "rule": rule.name, "scope": scope,
                               "subject": subject, "action": rule.action,
                               "reason": "forget", "value": None})
        events.append({"ev": "forget", scope: subject})

    # tick --------------------------------------------------------------
    def tick(self, now_ms):
        events, trace = [], []
        if self.last_tick is not None and now_ms < self.last_tick:
            events.append({"ev": "reject", "reason": "tick-out-of-order"})
            return events, trace
        self.last_tick = now_ms
        before = sorted({e.source for e in self.entities.values()})
        for k in sorted(self.entities):
            if now_ms - self.entities[k].last_time_ms > self.pack.forget_ms:
                del self.entities[k]
                self._forget_subject("entity", k, events)
        after = {e.source for e in self.entities.values()}
        for s in before:
            if s not in after:
                self._forget_subject("source", s, events)
        start = now_ms - self.pack.window_ms
        for ent in self.entities.values():
            ent.window = [x for x in ent.window if x["wt"] > start]
        by_source = {}
        for k in sorted(self.entities):
            ent = self.entities[k]
            m = self._entity_measures(ent, now_ms)
            by_source.setdefault(ent.source, []).append(m)
            events.append({"ev": "quality", "scope": "entity", "subject": k, "measures": m})
            self._evaluate("entity", k, m, events, trace)
        for s in sorted(by_source):
            m = self._source_measures(by_source[s])
            events.append({"ev": "quality", "scope": "source", "subject": s, "measures": m})
            self._evaluate("source", s, m, events, trace)
        return events, trace

    def snapshot(self):
        return {
            "ref": list(self.ref) if self.ref else None,
            "last_tick": self.last_tick,
            "entities": {k: {"source": e.source, "last_time_ms": e.last_time_ms,
                             "last_pos": list(e.last_pos),
                             "filter": {"east": list(e.east), "north": list(e.north)},
                             "window": [dict(x) for x in e.window]}
                         for k, e in sorted(self.entities.items())},
            "rules": {name: {s: dict(st) for s, st in sorted(states.items())}
                      for name, states in self.rules.items()},
        }
