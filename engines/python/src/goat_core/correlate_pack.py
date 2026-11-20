"""The correlate pack (spec/correlate.md, Pack; spec/correlate-assign.md, Pack).

parse_pack takes the two tables a pack's names come from: `tests` (a test
name and its parameters, gate.TESTS) and `methods` (a method name and the
directives it requires and refuses, correlate.METHODS)."""

import math

from .model import TIME_STATES
from .packdef import PackError

FILTER_PARAMS = ("accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms")
MANEUVER_PARAMS = ("accel_var", "p_enter", "p_leave")
BIAS_PARAMS = ("sigma_m", "floor_m", "gate")
SPRT_PARAMS = ("false", "missed", "pos_m", "vel_ms", "hae_sigma_m")
STALE_RATE_PARAMS = ("factor", "floor_ms", "ceiling_ms", "samples")


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
        self.output = "fused"
        self.priority = {}
        self.sprt = None
        self.stale_rate = None
        self.method = "confirm"
        self.tests = None    # the table of tests the pack was parsed with
        self.methods = None  # the table of methods
        self.new_cost = None
        self.keep_bonus = None
        self.maneuver = None
        self.window = 1
        self.hypotheses = 1
        self.bias = None
        self.restart = None
        self.margin = None
        self.time_default = {}
        self.time_offset = None


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


def parse_pack(text, tests, methods):
    p = Pack()
    p.tests = tests
    p.methods = methods
    seen = set()
    for i, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        d, args = parts[0], parts[1:]
        if d in ("pack", "version", "filter", "confirm_count", "hold_failures",
                 "stale_ms", "same_source", "output", "method", "new_cost", "keep_bonus",
                 "maneuver", "window", "hypotheses", "bias", "restart", "margin", "time_offset",
                 "sprt", "stale_rate"):
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
            kind = tests.get(name)
            if kind is None:
                raise PackError("line %d: unknown test %s" % (i, name))
            kv = _params(args[1:], i)
            if set(kv) != set(kind.params):
                raise PackError("line %d: test %s needs exactly %s" % (i, name, ", ".join(kind.params)))
            params = {k: (v if kind.text else _num(v, i)) for k, v in kv.items()}
            if kind.check is not None:
                err = kind.check(params)
                if err:
                    raise PackError("line %d: %s" % (i, err))
            getattr(p, d).append((name, params))
        elif d == "maneuver":
            kv = _params(args, i)
            if set(kv) != set(MANEUVER_PARAMS):
                raise PackError("line %d: maneuver needs exactly %s" % (i, ", ".join(MANEUVER_PARAMS)))
            m = {k: _num(v, i) for k, v in kv.items()}
            if m["p_enter"] <= 0 or m["p_leave"] <= 0 or m["p_enter"] + m["p_leave"] >= 1:
                raise PackError("line %d: p_enter and p_leave must be above 0 with a sum below 1" % i)
            p.maneuver = m
        elif d == "stale_rate":
            kv = _params(args, i)
            if set(kv) != set(STALE_RATE_PARAMS):
                raise PackError("line %d: stale_rate needs exactly %s" % (i, ", ".join(sorted(STALE_RATE_PARAMS))))
            sr = {"factor": _num(kv["factor"], i), "floor_ms": _int(kv["floor_ms"], i),
                  "ceiling_ms": _int(kv["ceiling_ms"], i), "samples": _int(kv["samples"], i)}
            if sr["factor"] <= 0 or sr["floor_ms"] < 0 or sr["ceiling_ms"] < sr["floor_ms"] or sr["samples"] < 1:
                raise PackError("line %d: stale_rate needs factor above 0, 0 <= floor_ms <= ceiling_ms, "
                                "samples 1 or above" % i)
            p.stale_rate = sr
        elif d == "sprt":
            kv = _params(args, i)
            if set(kv) != set(SPRT_PARAMS):
                raise PackError("line %d: sprt needs exactly %s" % (i, ", ".join(sorted(SPRT_PARAMS))))
            sp = {k: _num(v, i) for k, v in kv.items()}
            if (not (0 < sp["false"] < 0.5 and 0 < sp["missed"] < 0.5)
                    or min(sp["pos_m"], sp["vel_ms"], sp["hae_sigma_m"]) <= 0):
                raise PackError("line %d: sprt false and missed in (0, 0.5), spreads above 0" % i)
            p.sprt = sp
        elif d == "time_offset":
            kv = _params(args, i)
            if set(kv) != {"sigma_ms"}:
                raise PackError("line %d: time_offset needs exactly sigma_ms" % i)
            p.time_offset = _num(kv["sigma_ms"], i)
            if p.time_offset <= 0:
                raise PackError("line %d: time_offset sigma_ms must be above 0" % i)
        elif d == "time_default":
            if not args or "=" in args[0]:
                raise PackError("line %d: time_default needs a source id" % i)
            src = args[0]
            if src in p.time_default:
                raise PackError("line %d: time_default repeated for %s" % (i, src))
            kv = _params(args[1:], i)
            if not kv or set(kv) - {"error_ms", "state"}:
                raise PackError("line %d: time_default takes error_ms, state or both" % i)
            td = {}
            if "error_ms" in kv:
                td["error_ms"] = _num(kv["error_ms"], i)
                if td["error_ms"] < 0:
                    raise PackError("line %d: time_default error_ms must be 0 or above" % i)
            if "state" in kv:
                if kv["state"] not in TIME_STATES:
                    raise PackError("line %d: time_default state is one of %s" % (i, ", ".join(TIME_STATES)))
                td["state"] = kv["state"]
            p.time_default[src] = td
        elif d == "margin":
            if len(args) != 1:
                raise PackError("line %d: margin takes one value" % i)
            p.margin = _num(args[0], i)
            if p.margin <= 0:
                raise PackError("line %d: margin must be above 0" % i)
        elif d == "restart":
            kv = _params(args, i)
            if set(kv) != {"gate"}:
                raise PackError("line %d: restart needs exactly gate" % i)
            g = _num(kv["gate"], i)
            if g <= 0:
                raise PackError("line %d: restart gate must be above 0" % i)
            p.restart = g
        elif d == "bias":
            kv = _params(args, i)
            if set(kv) != set(BIAS_PARAMS):
                raise PackError("line %d: bias needs exactly %s" % (i, ", ".join(BIAS_PARAMS)))
            b = {k: _num(v, i) for k, v in kv.items()}
            if b["sigma_m"] <= 0 or b["floor_m"] <= 0 or b["floor_m"] > b["sigma_m"] or b["gate"] <= 0:
                raise PackError("line %d: bias needs sigma_m above 0, floor_m above 0 and at most sigma_m, gate above 0" % i)
            p.bias = b
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
            if args not in (["priority"], ["latest"], ["fused"]):
                raise PackError("line %d: output is fused, priority or latest" % i)
            p.output = args[0]
        elif d == "priority":
            if len(args) != 2:
                raise PackError("line %d: priority takes a source and a number" % i)
            p.priority[args[0]] = _int(args[1], i)
            seen.add("priority")
        elif d == "method":
            if len(args) != 1 or args[0] not in methods:
                raise PackError("line %d: method is one of %s" % (i, ", ".join(methods)))
            p.method = args[0]
        elif d in ("new_cost", "keep_bonus"):
            if len(args) != 1:
                raise PackError("line %d: %s takes one value" % (i, d))
            setattr(p, d, _num(args[0], i))
            if (d == "new_cost" and p.new_cost <= 0) or (d == "keep_bonus" and p.keep_bonus < 0):
                raise PackError("line %d: new_cost must be above 0 and keep_bonus 0 or above" % i)
        else:
            raise PackError("line %d: unknown directive %s" % (i, d))
    method = methods[p.method]
    for d in method.refused:
        if d in seen or (d in ("gate", "confirm", "hold") and getattr(p, d)):
            raise PackError("method %s does not take %s" % (p.method, d))
    required = method.required
    if p.sprt is not None:
        # Association, Sequential test: sprt replaces the counts and the hold.
        if p.hold or any(d in seen for d in ("confirm_count", "hold_failures")):
            raise PackError("sprt replaces confirm_count, hold and hold_failures")
        required = tuple(d for d in required if d not in ("confirm_count", "hold_failures"))
    if p.stale_rate is not None:
        if "stale_ms" in seen:
            raise PackError("stale_ms and stale_rate exclude each other")
        required = tuple(d for d in required if d != "stale_ms")
    for d in required:
        if d not in seen:
            raise PackError("missing directive %s" % d)
    if p.maneuver is not None and p.maneuver["accel_var"] <= p.filter["accel_var"]:
        raise PackError("maneuver accel_var must be above the filter's accel_var")
    if p.window == 1 and p.hypotheses > 1:
        raise PackError("hypotheses above 1 needs a window above 1")
    if p.time_offset is not None and p.bias is None:
        raise PackError("time_offset needs bias")
    if p.margin is not None and p.hypotheses == 1:
        raise PackError("margin needs hypotheses above 1")
    return p


