"""Correlate engine (spec/correlate.md 0.6, spec/correlate-assign.md 0.4). Standard library only."""

import math
import os

R = 6371008.8

TESTS = {
    "distance": ("max_m",),
    "mahalanobis": ("gate",),
    "course": ("max_deg", "min_speed_ms"),
    "speed": ("max_pct", "min_speed_ms"),
    "altitude": ("max_m",),
    "same": ("key",),
    "state": ("probability", "hae_sigma_m"),
}
# Chi-square quantiles for 4 and 5 degrees of freedom (spec/correlate.md, the
# `state` test): probability -> (4 dof, 5 dof).
CHI2 = {0.95: (9.4877, 11.0705), 0.99: (13.2767, 15.0863),
        0.995: (14.8603, 16.7496), 0.999: (18.4668, 20.5150)}
FILTER_PARAMS = ("accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms")
MANEUVER_PARAMS = ("accel_var", "p_enter", "p_leave")
MODELS = ("quiet", "maneuver")
BIAS_PARAMS = ("sigma_m", "floor_m", "gate")
TIME_STATES = ("coherent", "drifting", "free-running")
REQUIRED = (("track.source_id", "str"), ("uid", "str"), ("time_ms", "int"),
            ("lat", "num"), ("lon", "num"))
OPTIONAL = {"hae": "num", "ce": "num", "course": "num", "speed_ms": "num",
            "type": "str", "stale_ms": "int", "time_error_ms": "num", "time_state": "str"}


def _is(v, kind):
    if isinstance(v, bool) or v is None:
        return False
    if kind == "str":
        return isinstance(v, str)
    if kind == "int":
        return isinstance(v, int)
    return isinstance(v, (int, float))


def _normalize(report):
    """Spec, Reports: optional keys of the wrong type are absent."""
    out = {}
    for k, v in report.items():
        if v is None:
            continue
        if k in OPTIONAL and not _is(v, OPTIONAL[k]):
            continue
        if k == "ce" and v <= 0:
            continue
        if k == "time_error_ms" and (v < 0 or not math.isfinite(v)):
            continue
        if k == "time_state" and v not in TIME_STATES:
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
        self.output = "fused"
        self.priority = {}
        self.sprt = None
        self.stale_rate = None
        self.method = "confirm"
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
                 "maneuver", "window", "hypotheses", "bias", "restart", "margin", "time_offset", "sprt", "stale_rate"):
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
            if name == "state" and (params["probability"] not in CHI2 or params["hae_sigma_m"] <= 0):
                raise PackError("line %d: state needs probability one of %s and hae_sigma_m above 0"
                                % (i, ", ".join(str(x) for x in sorted(CHI2))))
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
            want = {"factor", "floor_ms", "ceiling_ms", "samples"}
            if set(kv) != want:
                raise PackError("line %d: stale_rate needs exactly %s" % (i, ", ".join(sorted(want))))
            sr = {"factor": _num(kv["factor"], i), "floor_ms": _int(kv["floor_ms"], i),
                  "ceiling_ms": _int(kv["ceiling_ms"], i), "samples": _int(kv["samples"], i)}
            if sr["factor"] <= 0 or sr["floor_ms"] < 0 or sr["ceiling_ms"] < sr["floor_ms"] or sr["samples"] < 1:
                raise PackError("line %d: stale_rate needs factor above 0, 0 <= floor_ms <= ceiling_ms, samples 1 or above" % i)
            p.stale_rate = sr
        elif d == "sprt":
            kv = _params(args, i)
            want = {"false", "missed", "pos_m", "vel_ms", "hae_sigma_m"}
            if set(kv) != want:
                raise PackError("line %d: sprt needs exactly %s" % (i, ", ".join(sorted(want))))
            sp = {k: _num(v, i) for k, v in kv.items()}
            if not (0 < sp["false"] < 0.5 and 0 < sp["missed"] < 0.5) or min(sp["pos_m"], sp["vel_ms"], sp["hae_sigma_m"]) <= 0:
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
            raise PackError("method assign takes only pack, version, method, filter, maneuver, gate, "
                            "new_cost, keep_bonus, stale_ms, window, hypotheses, margin, bias, time_offset, restart, time_default")
    else:
        required = ("pack", "version", "filter", "confirm_count", "hold_failures", "stale_ms")
        if p.sprt is not None:
            required = ("pack", "version", "filter", "stale_ms")
            if p.hold or any(d in seen for d in ("confirm_count", "hold_failures")):
                raise PackError("sprt replaces confirm_count, hold and hold_failures")
        if any(d in seen for d in ("new_cost", "keep_bonus", "window", "hypotheses", "bias", "margin", "time_offset")):
            raise PackError("new_cost, keep_bonus, window, hypotheses, margin, bias and time_offset need method assign")
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
        self.models = None  # two-model filter: [[east, north] quiet, [east, north] maneuver]
        self.mode = None    # [mu_quiet, mu_maneuver]
        self.r_meas = None  # per-axis measurement variance of the last report
        self.t_var = (0.0, 0.0)  # per-axis timing variance of the last report
        self.time_err = 0.0      # time error of the last report, ms

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
    if e.time_err > 0:
        out["time"] = {"var_east": e.t_var[0], "var_north": e.t_var[1]}
    return out


class Engine:
    def __init__(self, pack):
        self.pack = pack
        self.ref = None
        self.entities = {}
        self.groups = {}
        self.group_order = []
        self.counts = {}
        self.llr = {}
        self.intervals = {}
        self._memo = {}
        self.next_group = 1
        self.retiring = set()
        self.restarted = set()

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
            q = (self.pack.filter["accel_var"], self.pack.maneuver["accel_var"])
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
        man = self.pack.maneuver
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
            east, y, s = _pos_step(east, e, r[0])
            terms.append(y * y / s + math.log(s))
            north, y, s = _pos_step(north, n, r[1])
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

    def _predict_in(self, b, t, a):
        """B's prediction to t for a comparison with A: B's timing variance
        added to pp (no shift without a bias estimate)."""
        memo = self._memo
        k = (b.key, t)
        pr = memo.get(k)
        if pr is None:
            pr = memo[k] = self._with_time(self._predict(b, t), b)
        return pr

    @staticmethod
    def _with_time(pr, b):
        if b.t_var == (0.0, 0.0):
            return pr
        return tuple((x[0], x[1], x[2] + tv) + tuple(x[3:]) for x, tv in zip(pr, b.t_var))

    def _d2(self, a, b):
        be, bn = self._predict_in(b, a.last_time_ms, a)
        re_, rn_ = a.r_meas
        return ((a.east[0] - be[0]) ** 2 / (be[2] + re_)
                + (a.north[0] - bn[0]) ** 2 / (bn[2] + rn_))

    def _state_d2(self, a, b, hae_sigma):
        """Track-to-track statistic on the full kinematic state: per axis the
        position and velocity difference of A's filter and B's prediction to
        A's time, with the sum of their covariances (timing variances added to
        position), plus the height difference when both report hae."""
        pb = self._predict_in(b, a.last_time_ms, a)
        total = 0.0
        for x, fa in ((0, a.east), (1, a.north)):
            dp = fa[0] - pb[x][0]
            dv = fa[1] - pb[x][1]
            spp = fa[2] + a.t_var[x] + pb[x][2]
            spv = fa[3] + pb[x][3]
            svv = fa[4] + pb[x][4]
            det = spp * svv - spv * spv
            total += (svv * dp * dp - 2.0 * spv * dp * dv + spp * dv * dv) / det
        ha, hb = a.report.get("hae"), b.report.get("hae")
        if ha is None or hb is None:
            return total, 4
        dh = float(ha) - float(hb)
        return total + dh * dh / (2.0 * hae_sigma * hae_sigma), 5

    def _sprt_step(self, a, b):
        """correlate.md, Sequential test: d² of the full state under "same
        object" (covariance S) and the log-likelihood ratio increment against
        "different objects" (covariance S + diag(pos_m², vel_ms²))."""
        sp = self.pack.sprt
        pb = self._predict_in(b, a.last_time_ms, a)
        q1 = 0.0
        lam = 0.0
        p0, v0 = sp["pos_m"] ** 2, sp["vel_ms"] ** 2
        for x, fa in ((0, a.east), (1, a.north)):
            dp = fa[0] - pb[x][0]
            dv = fa[1] - pb[x][1]
            spp = fa[2] + a.t_var[x] + pb[x][2]
            spv = fa[3] + pb[x][3]
            svv = fa[4] + pb[x][4]
            det = spp * svv - spv * spv
            qa = (svv * dp * dp - 2.0 * spv * dp * dv + spp * dv * dv) / det
            tpp, tvv = spp + p0, svv + v0
            det0 = tpp * tvv - spv * spv
            qb = (tvv * dp * dp - 2.0 * spv * dp * dv + tpp * dv * dv) / det0
            q1 += qa
            lam += 0.5 * (qb - qa) + 0.5 * math.log(det0 / det)
        ha, hb = a.report.get("hae"), b.report.get("hae")
        if ha is not None and hb is not None:
            dh = float(ha) - float(hb)
            h1 = 2.0 * sp["hae_sigma_m"] ** 2
            h0 = h1 + p0
            q1 += dh * dh / h1
            lam += 0.5 * (dh * dh / h0 - dh * dh / h1) + 0.5 * math.log(h0 / h1)
        return q1, lam

    def _run_same(self, a, b, trace):
        """The categorical (`same`) tests of the gate stage only."""
        for name, prm in self.pack.gate:
            if name == "same" and not self._run_test("gate", name, prm, a, b, trace):
                return False
        return True

    def _sprt_update(self, a, b, gate_ok, trace):
        """Add one report's evidence to the pair's log-likelihood ratio,
        clamped to [ln B, ln A]; returns the new value."""
        sp = self.pack.sprt
        up = math.log((1.0 - sp["missed"]) / sp["false"])
        lo = math.log(sp["missed"] / (1.0 - sp["false"]))
        pk = self._pair(a.key, b.key)
        old = self.llr.get(pk, 0.0)
        if gate_ok:
            q1, lam = self._sprt_step(a, b)
            new = min(max(old + lam, lo), up)
        else:
            q1, lam, new = None, None, lo
        self.llr[pk] = new
        trace.append({"stage": "sprt", "a": a.key, "b": b.key, "test": "llr", "value": new,
                      "limit": up, "pass": new >= up, "lower": lo, "increment": lam, "d2": q1})
        return new, up, lo

    def _dist(self, a, b):
        be, bn = self._predict_in(b, a.last_time_ms, a)
        return math.hypot(a.east[0] - be[0], a.north[0] - bn[0])

    def _run_test(self, stage, name, prm, a, b, trace):
        rec = {"stage": stage, "a": a.key, "b": b.key, "test": name}
        ra, rb = a.report, b.report
        if name == "distance":
            value, limit = self._dist(a, b), prm["max_m"]
            ok = value < limit
        elif name == "mahalanobis":
            value, limit = self._d2(a, b), prm["gate"]
            ok = value < limit
        elif name == "state":
            value, dof = self._state_d2(a, b, prm["hae_sigma_m"])
            limit = CHI2[prm["probability"]][dof - 4]
            ok = value < limit
            rec["dof"] = dof
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
        report = _normalize(report)
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
        re_, rn_ = ce * ce, ce * ce
        ae = an = 0.0
        te = self._time_error_ms(report, source)
        pred = self._predict(ent, t) if ent is not None else None
        if te > 0:
            if pred is not None:
                ve, vn = pred[0][1], pred[1][1]
            else:
                ve, vn = vel if vel else (0.0, 0.0)
            ts = te / 1000.0
            ae, an = (ve * ts) ** 2, (vn * ts) ** 2
            re_, rn_ = re_ + ae, rn_ + an
            trace.append({"stage": "filter", "a": key, "b": None, "test": "time",
                          "value": te, "limit": None, "pass": True,
                          "var_east": ae, "var_north": an})
        fresh = ent is None
        fresh_entity = ent is None
        if ent is not None and self.pack.restart is not None:
            pe, pn = pred
            d2 = (e - pe[0]) ** 2 / (pe[2] + re_) + (n - pn[0]) ** 2 / (pn[2] + rn_)
            ok = d2 < self.pack.restart
            trace.append({"stage": "filter", "a": key, "b": None, "test": "restart",
                          "value": d2, "limit": self.pack.restart, "pass": ok})
            fresh = not ok
            if fresh and self.pack.method == "assign":
                self.restarted.add(key)
        if fresh:
            if ent is None:
                ent = _Entity(key, source)
                self.entities[key] = ent
                events.append({"ev": "new", "entity": key})
            vv = (f["vel_sigma_ms"] if vel else f["unknown_vel_ms"]) ** 2
            ent.east = [e, vel[0] if vel else 0.0, re_, 0.0, vv]
            ent.north = [n, vel[1] if vel else 0.0, rn_, 0.0, vv]
            if self.pack.maneuver is not None:
                a, b = self.pack.maneuver["p_enter"], self.pack.maneuver["p_leave"]
                ent.models = [[list(ent.east), list(ent.north)], [list(ent.east), list(ent.north)]]
                ent.mode = [b / (a + b), a / (a + b)]
        elif ent.models is not None:
            dt = (t - ent.last_time_ms) / 1000.0
            self._two_model_update(ent, dt, e, n, (re_, rn_), vel, f["vel_sigma_ms"] ** 2, trace)
        else:
            dt = (t - ent.last_time_ms) / 1000.0
            q = f["accel_var"]
            ent.east = _pos_update(_predict_axis(ent.east, dt, q), e, re_)
            ent.north = _pos_update(_predict_axis(ent.north, dt, q), n, rn_)
            if vel:
                r = f["vel_sigma_ms"] ** 2
                ent.east = _vel_update(ent.east, vel[0], r)
                ent.north = _vel_update(ent.north, vel[1], r)
        if self.pack.stale_rate is not None and not fresh_entity:
            ring = self.intervals.setdefault(source, [])
            ring.append(t - ent.last_time_ms)
            if len(ring) > self.pack.stale_rate["samples"]:
                del ring[0]
        ent.report = dict(report)
        ent.r_meas = (re_, rn_)
        ent.t_var = (ae, an)
        ent.time_err = te
        ent.last_time_ms = t
        return ent

    def _fused_event(self, g, members, now_ms):
        """Output `fused`: per axis the inverse-variance combination of the
        members' predictions to now_ms, members in key order."""
        acc = [[0.0, 0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 0.0]]
        hae, hae_t = None, None
        for m in members:
            e = self.entities[m]
            pr = self._predict(e, now_ms)
            for x in (0, 1):
                a, o = pr[x], acc[x]
                o[0] += 1.0 / a[2]
                o[1] += a[0] / a[2]
                o[2] += 1.0 / a[4]
                o[3] += a[1] / a[4]
            if e.report.get("hae") is not None and (hae_t is None or e.last_time_ms > hae_t):
                hae, hae_t = float(e.report["hae"]), e.last_time_ms
        pe = acc[0][1] / acc[0][0]
        pn = acc[1][1] / acc[1][0]
        ve = acc[0][3] / acc[0][2]
        vn = acc[1][3] / acc[1][2]
        lat, lon = self._to_deg(pe, pn)
        course = math.degrees(math.atan2(ve, vn))
        if course < 0:
            course += 360.0
        if course >= 360.0:
            course -= 360.0
        ev = {"ev": "fused", "group": g, "primary": None, "members": list(members),
              "lat": lat, "lon": lon, "course": course, "speed_ms": math.hypot(ve, vn)}
        if hae is not None:
            ev["hae"] = hae
        return ev

    def _stale_limit(self, source):
        """The stale time of a source: stale_ms, or with stale_rate factor
        times the median of its last intervals, within the floor and ceiling."""
        sr = self.pack.stale_rate
        if sr is None:
            return self.pack.stale_ms
        ring = self.intervals.get(source)
        if not ring:
            return sr["ceiling_ms"]
        srt = sorted(ring)
        lim = sr["factor"] * srt[(len(srt) - 1) // 2]
        return min(max(lim, sr["floor_ms"]), sr["ceiling_ms"])

    def _time_error_ms(self, report, source):
        """correlate.md, Reports, Time quality: the report's value, else the
        pack's time_default for its source, else 0."""
        v = report.get("time_error_ms")
        if v is not None:
            return float(v)
        return float(self.pack.time_default.get(source, {}).get("error_ms", 0.0))

    def ingest(self, report):
        events, trace = [], []
        self._memo = {}
        ent = self._accept(report, events, trace)
        if ent is None:
            return events, trace
        key, source = ent.key, ent.source

        if ent.group is not None and self.pack.sprt is not None:
            keep = False
            others = [k for k in sorted(self.groups[ent.group]) if k != key]
            # The link: the other member whose pair ratio is highest (no
            # state reads 0; ties to key order). Only that pair is updated.
            best = None
            for k in others:
                v = self.llr.get(self._pair(key, k), 0.0)
                if best is None or v > best[0]:
                    best = (v, k)
            others = [best[1]]
            for k in others:
                b = self.entities[k]
                ok = self._run_same(ent, b, trace)
                new, up, lo = self._sprt_update(ent, b, ok, trace)
                if new > lo:
                    keep = True
            if not keep:
                g = ent.group
                self._leave(ent, "release", events)
                for k in list(self.llr):
                    if key in k.split("|"):
                        o = k.split("|")[0] if k.split("|")[1] == key else k.split("|")[1]
                        if self.llr[k] <= math.log(self.pack.sprt["missed"] / (1.0 - self.pack.sprt["false"])):
                            del self.llr[k]
            return events, trace

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
            if self.pack.sprt is not None:
                if not ok and pk not in self.llr:
                    continue
                if not ok:
                    ok = self._run_same(ent, b, [])
                new, up, lo = self._sprt_update(ent, b, ok, trace)
                if new <= lo:
                    del self.llr[pk]
                if new >= up:
                    ready.append(b)
                continue
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
            if self.pack.sprt is None:
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
            stale = now_ms - ent.last_time_ms > self._stale_limit(ent.source)
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
            for pk in [pk for pk in self.llr if k in pk.split("|")]:
                del self.llr[pk]
            events.append({"ev": "drop", "entity": k})
        for g in self.group_order:
            members = self.groups[g]
            if self.pack.output == "fused":
                events.append(self._fused_event(g, members, now_ms))
                continue
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
            **({"llr": dict(sorted(self.llr.items()))} if self.pack.sprt is not None else {}),
            **({"intervals": {k: list(v) for k, v in sorted(self.intervals.items())}}
               if self.pack.stale_rate is not None else {}),
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
        pr = self._with_time(self._predict(b, t), b)
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
        if now_ms - ent.last_time_ms > self._stale_limit(ent.source):
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
        out = {
            "ref": list(self.ref) if self.ref else None,
            "entities": {k: dict({"last_time_ms": e.last_time_ms, "system": e.system}, **_filter_snap(e))
                         for k, e in sorted(self.entities.items())},
            "systems": self.committed.snap(),
            "next_system": self.committed.next,
            "reported": sorted(self.reported),
        }
        if self.pack.stale_rate is not None:
            out["intervals"] = {k: list(v) for k, v in sorted(self.intervals.items())}
        if self.pack.restart is not None:
            out["restarted"] = sorted(self.restarted)
        if self.pack.bias is not None:
            out["bias"] = {k: dict({"east": v[0][0], "weight_east": v[0][2], "north": v[1][0],
                                    "weight_north": v[1][2], "var": v[0][1], "pairs": v[2]},
                                   **({"time_offset_ms": v[3] * 1000.0, "sums": list(v[4])}
                                      if self.pack.time_offset is not None else {}))
                           for k, v in sorted(self.bias.items())}
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
