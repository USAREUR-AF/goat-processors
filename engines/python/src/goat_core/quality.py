"""The quality function (spec/quality.md): samples per report, measures
per entity and per source over a window, and rules that mark, downgrade,
drop or alert. The per-entity filter is correlate's (estimate.py)."""

import math
import re
from functools import partial, reduce
from operator import add, is_not, itemgetter
from types import MappingProxyType
from typing import Callable, NamedTuple

from . import estimate
from . import snapshot as _snapshot
from . import trace as _trace
from .io import read_pack_def
from .model import REQUIRED, TIME_STATES, is_kind as _is, to_plane
from .packdef import PackError, decimal_int

FILTER_PARAMS = ("accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms")
WINDOW_PARAMS = ("window_ms", "min_samples", "forget_ms")
RULE_PARAMS = ("scope", "measure", "op", "limit", "for", "clear", "action")

TIME_CODE = MappingProxyType({"coherent": 0, "drifting": 1, "free-running": 2})
OPS = ("<", "<=", ">", ">=")
ACTIONS = ("mark", "downgrade", "drop", "alert")

NUM_RE = re.compile(r"-?[0-9]+(\.[0-9]+)?\Z")
INT_RE = re.compile(r"[0-9]+\Z")
NAME_RE = re.compile(r"[A-Za-z0-9._-]+\Z")
CONTROL_RE = re.compile(r"[\x00-\x08\x0a-\x1f\x7f]")
SEP_RE = re.compile(r"[ \t]+")
MAX_FINITE = 1.7976931348623157e308


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
        self.time_default = {}
        self.measures = None  # the table of measures the pack was parsed with


def _num(v, line_no):
    if not NUM_RE.match(v):
        raise PackError("line %d: not a decimal number: %s" % (line_no, v))
    x = float(v)
    if math.isinf(x):
        raise PackError("line %d: number not finite in binary64: %s" % (line_no, v))
    return x


def _int(v, line_no):
    if not INT_RE.match(v):
        raise PackError("line %d: not an integer: %s" % (line_no, v))
    return decimal_int(v, "line %d" % line_no)


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


def parse_pack(text, measures=None):
    """A quality pack.def, its rules naming measures of `measures` (MEASURES
    by default); raises PackError."""
    if measures is None:
        measures = MEASURES
    p = Pack()
    p.measures = measures
    seen = set()
    names = set()
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    for i, raw in enumerate(lines, 1):
        if raw.endswith("\r"):
            raw = raw[:-1]
        if CONTROL_RE.search(raw):
            raise PackError("line %d: control character" % i)
        line = raw.split("#", 1)[0].strip(" \t")
        if not line:
            continue
        parts = SEP_RE.split(line)
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
            if measure not in measures and not (scope == "source" and measure == "entities"):
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
        elif d == "time_default":
            if not args or "=" in args[0]:
                raise PackError("line %d: time_default needs a source id" % i)
            src = args[0]
            if src in p.time_default:
                raise PackError("line %d: time_default repeated for %s" % (i, src))
            kv = _params(args[1:], i, ("error_ms", "state"), ())
            if not kv:
                raise PackError("line %d: time_default takes error_ms, state or both" % i)
            td = {}
            if "error_ms" in kv:
                td["error_ms"] = _num(kv["error_ms"], i)
                if td["error_ms"] < 0:
                    raise PackError("line %d: time_default error_ms must be 0 or above" % i)
            if "state" in kv:
                if kv["state"] not in TIME_STATES:
                    raise PackError("line %d: time_default state is coherent, drifting or free-running" % i)
                td["state"] = kv["state"]
            p.time_default[src] = td
        else:
            raise PackError("line %d: unknown directive %s" % (i, d))
    for d in ("pack", "version", "filter", "window"):
        if d not in seen:
            raise PackError("missing directive %s" % d)
    return p


def load_pack(directory, measures=None):
    return parse_pack(read_pack_def(directory), measures)


class _Entity:
    def __init__(self, key, source):
        self.key = key
        self.source = source
        self.last_time_ms = None
        self.last_pos = None
        self.east = None
        self.north = None
        self.window = []
        self.version = 0   # changes with the window
        self.known = None  # (version, window_measures of that version): a memo, not state


def _mean(xs):
    """The sum from 0.0, left to right (reduce makes the same binary64
    additions as the loop; the builtin sum does not: it compensates), over
    the count."""
    return reduce(add, xs, 0.0) / len(xs)


def _median(xs):
    n = len(xs)
    if n % 2:
        return xs[n // 2]
    return (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def input_clock(entities, source):
    """Input clock: the median over the other sources of each one's latest
    report time, and this source's latest (each None when there is none)."""
    latest = {}
    for other in entities:
        if other.source not in latest or other.last_time_ms > latest[other.source]:
            latest[other.source] = other.last_time_ms
    src_latest = latest.pop(source, None)
    clock = _median(sorted(latest.values())) if latest else None
    return clock, src_latest


_not_none = partial(is_not, None)


class Window:
    """The samples of one entity's window, for its measures: `column(name)`
    is every sample's `name` and `values(name)` the non-null ones, in window
    order, each built once."""

    __slots__ = ("records", "age", "k", "_values", "_columns")

    def __init__(self, records, age, k):
        self.records = records
        self.age = age
        self.k = k
        self._values = {}
        self._columns = {}

    def column(self, name):
        xs = self._columns.get(name)
        if xs is None:
            xs = list(map(itemgetter(name), self.records))
            self._columns[name] = xs
        return xs

    def values(self, name):
        xs = self._values.get(name)
        if xs is None:
            xs = list(filter(_not_none, self.column(name)))
            self._values[name] = xs
        return xs

    def time_codes(self):
        xs = self._values.get("@time_code")
        if xs is None:
            xs = [TIME_CODE[x] for x in self.values("time_state")]
            self._values["@time_code"] = xs
        return xs


class Measure(NamedTuple):
    """One entity measure: compute(window) gives its value (None when it has
    too few samples); `aggregate` (sum, mean, max or min) is how a source
    combines it over its entities. `uses_age`: it reads the window's age
    (the tick's time), not only its samples; the others are computed again
    only when the window changes."""
    aggregate: str
    compute: Callable
    uses_age: bool = False


def _last(xs):
    return xs[-1]


def _windowed(name, reduce):
    """A measure of the samples `name`: reduce(values) with min_samples of them, else None."""
    def compute(w):
        xs = w.values(name)
        return reduce(xs) if len(xs) >= w.k else None
    return compute


def _time_state(reduce):
    def compute(w):
        xs = w.time_codes()
        return reduce(xs) if len(xs) >= w.k else None
    return compute


def _count(name, value):
    """A measure that counts the window's samples whose `name` is `value`."""
    def compute(w):
        return w.column(name).count(value)
    return compute


def _fraction(name, value):
    """The fraction of the window's samples whose `name` is `value`, with min_samples of them."""
    def compute(w):
        return w.column(name).count(value) / len(w.records) if len(w.records) >= w.k else None
    return compute


# Entity measures, in the order of the spec's measures table (and of every
# measures object): the one table of measures.
MEASURES = MappingProxyType({
    "reports": Measure("sum", lambda w: len(w.records)),
    "interval_last": Measure("mean", _windowed("interval", _last)),
    "interval_mean": Measure("mean", _windowed("interval", _mean)),
    "interval_max": Measure("max", _windowed("interval", max)),
    "age": Measure("min", lambda w: w.age, uses_age=True),
    "latency_mean": Measure("mean", _windowed("latency", _mean)),
    "latency_max": Measure("max", _windowed("latency", max)),
    "lateness_mean": Measure("mean", _windowed("lateness", _mean)),
    "lateness_max": Measure("max", _windowed("lateness", max)),
    "lateness_min": Measure("min", _windowed("lateness", min)),
    "nis_mean": Measure("mean", _windowed("nis", _mean)),
    "speed_err_mean": Measure("mean", _windowed("speed_err", _mean)),
    # (order is a string, the flags are booleans, time_state a string or null)
    "out_of_order": Measure("sum", _count("order", "out-of-order")),
    "duplicate": Measure("sum", _count("order", "duplicate")),
    "source_out_of_order": Measure("sum", _count("source_out_of_order", True)),
    "missing_ce": Measure("mean", _fraction("ce", False)),
    "missing_vel": Measure("mean", _fraction("vel", False)),
    "missing_hae": Measure("mean", _fraction("hae", False)),
    "time_error_mean": Measure("mean", _windowed("time_error", _mean)),
    "time_error_max": Measure("max", _windowed("time_error", max)),
    "time_state_last": Measure("max", _time_state(_last)),
    "time_state_worst": Measure("max", _time_state(max)),
    "missing_time": Measure("mean", _fraction("time_state", None)),
})


def extend_measures(measures, name, measure):
    """A new table: `measures` with one more measure (last in every
    measures object). The table given is unchanged."""
    if name in measures or name == "entities":
        raise ValueError("measure %s is already in the table" % name)
    out = dict(measures)
    out[name] = measure
    return MappingProxyType(out)


def entity_measures(measures, records, age, k, known=None):
    """Entity measures of one entity's window `records`, with k = min_samples.
    `known`: the values of the measures that do not use the age, from the
    same records and k (window_measures), when the caller has them."""
    w = Window(records, age, k)
    if known is None:
        return {name: m.compute(w) for name, m in measures.items()}
    return {name: (m.compute(w) if m.uses_age else known[name]) for name, m in measures.items()}


def window_measures(measures, records, k):
    """The measures that do not use the age, of one window."""
    w = Window(records, None, k)
    return {name: m.compute(w) for name, m in measures.items() if not m.uses_age}


def source_measures(measures, ms):
    """Source measures: each entity measure aggregated over the source's
    entities, then the number of entities."""
    out = {}
    for m, kind in measures.items():
        how = kind.aggregate
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


def rule_step(rule, count, active, v):
    """Rules: one evaluation of a rule on a subject whose state is (count,
    active), with measure value v. Returns (count, active, pass, limit)."""
    if not active:
        ok = v is not None and _met(rule.op, v, rule.limit)
        count = count + 1 if ok else 0
        if count >= rule.n:
            return 0, True, ok, rule.limit
        return count, False, ok, rule.limit
    ok = v is not None and (v < rule.clear if rule.op in (">", ">=") else v > rule.clear)
    return count, not ok, ok, rule.clear


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
        return to_plane(self.ref, lat, lon)

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
        te = report.get("time_error_ms")
        if _is(te, "num") and math.isfinite(te) and te >= 0:
            opt["time_error_ms"] = float(te)
        ts = report.get("time_state")
        if _is(ts, "str") and ts in TIME_STATES:
            opt["time_state"] = ts
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
               "interval": None, "latency": None, "lateness": None,
               "source_out_of_order": False, "time_error": None, "time_state": None,
               "nis": None, "speed_err": None,
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
        clock, src_latest = input_clock(self.entities.values(), source)
        if clock is not None:
            rec["lateness"] = clock - t
            trace.append({"stage": "sample", "entity": key, "sample": "lateness",
                          "value": rec["lateness"], "inputs": [clock, t]})
        td = self.pack.time_default.get(source, {})
        rec["time_error"] = opt.get("time_error_ms", td.get("error_ms"))
        rec["time_state"] = opt.get("time_state", td.get("state"))
        if rec["time_error"] is not None:
            trace.append({"stage": "sample", "entity": key, "sample": "time_error",
                          "value": rec["time_error"],
                          "inputs": [opt.get("time_error_ms"), td.get("error_ms")]})
        if rec["time_state"] is not None:
            trace.append({"stage": "sample", "entity": key, "sample": "time_state",
                          "value": rec["time_state"],
                          "inputs": [opt.get("time_state"), td.get("state")]})
        rec["source_out_of_order"] = src_latest is not None and t < src_latest
        trace.append({"stage": "sample", "entity": key, "sample": "source_order",
                      "value": "out-of-order" if rec["source_out_of_order"] else "in-order",
                      "inputs": [t, src_latest]})
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
            pe = estimate.predict_axis(ent.east, dt, q)
            pn = estimate.predict_axis(ent.north, dt, q)
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
            ent.east = estimate.pos_update(pe, e, r)
            ent.north = estimate.pos_update(pn, n, r)
            if vel:
                rv = f["vel_sigma_ms"] ** 2
                ent.east = estimate.vel_update(ent.east, vel[0], rv)
                ent.north = estimate.vel_update(ent.north, vel[1], rv)
            ent.last_time_ms = t
            ent.last_pos = [e, n]
        ent.window.append(rec)
        ent.version += 1

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
                out["ce"] = MAX_FINITE if math.isinf(x) else x
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
    def _evaluate(self, scope, subject, measures, events, trace):
        """Rules: each rule of this scope, in pack order, on one subject."""
        for rule in self.pack.rules:
            if rule.scope != scope:
                continue
            states = self.rules[rule.name]
            st = states.get(subject)
            count, active = (0, False) if st is None else (st["count"], st["active"])
            v = measures[rule.measure]
            count, now_active, ok, limit = rule_step(rule, count, active, v)
            states[subject] = {"count": count, "active": now_active}
            if now_active and not active:
                events.append({"ev": "action-start", "rule": rule.name, "scope": scope,
                               "subject": subject, "action": rule.action, "value": v})
            elif active and not now_active:
                events.append({"ev": "action-end", "rule": rule.name, "scope": scope,
                               "subject": subject, "action": rule.action,
                               "reason": "clear", "value": v})
            trace.append(_trace.quality_rule(rule.name, subject, rule.measure, v, limit, ok,
                                             count, now_active))

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
            # Window: the samples with wt above start. wt never decreases
            # along a window (it is the entity's latest time), so they are a
            # suffix: drop the prefix at or before start.
            w = ent.window
            i = 0
            while i < len(w) and w[i]["wt"] <= start:
                i += 1
            if i:
                ent.window = w[i:]
                ent.version += 1
        by_source = {}
        for k in sorted(self.entities):
            ent = self.entities[k]
            if ent.known is None or ent.known[0] != ent.version:
                ent.known = (ent.version, window_measures(self.pack.measures, ent.window, self.pack.min_samples))
            m = entity_measures(self.pack.measures, ent.window, now_ms - ent.last_time_ms,
                                self.pack.min_samples, ent.known[1])
            by_source.setdefault(ent.source, []).append(m)
            events.append({"ev": "quality", "scope": "entity", "subject": k, "measures": m})
            self._evaluate("entity", k, m, events, trace)
        for s in sorted(by_source):
            m = source_measures(self.pack.measures, by_source[s])
            events.append({"ev": "quality", "scope": "source", "subject": s, "measures": m})
            self._evaluate("source", s, m, events, trace)
        return events, trace

    def snapshot(self):
        return _snapshot.quality(self)


def make_engine(pack):
    return Engine(pack)


def restore(pack, snap):
    """An engine of `pack` in the state `snap` (a snapshot() of one)."""
    return _snapshot.restore_quality(Engine(pack), snap, _Entity)
