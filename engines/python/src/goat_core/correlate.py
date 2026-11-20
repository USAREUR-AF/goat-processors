"""Correlate: what both methods share (spec/correlate.md, Reports, Frame,
Track estimate, Two-model filter, Restart), and the choice of method.

`Correlator` holds the entities and their filters; `ConfirmEngine`
(confirm.py) and `AssignEngine` (assign.py) add the method."""

from . import estimate
from .correlate_pack import Pack, PackError, load_pack, parse_pack  # noqa: F401  (re-exported)
from .estimate import MODELS
from .gate import mahalanobis, plane_distance, run_stage
from .model import missing_key, normalize, to_deg, to_plane, velocity


class Track:
    """One entity: its last accepted report and its track estimate."""

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


class Correlator:
    """The entities, their filters and the frame, for either method."""

    def __init__(self, pack):
        self.pack = pack
        self.ref = None
        self.entities = {}
        self.retiring = set()
        self.restarted = set()

    # frame -------------------------------------------------------------
    def _to_plane(self, lat, lon):
        return to_plane(self.ref, lat, lon)

    def _to_deg(self, east, north):
        return to_deg(self.ref, east, north)

    # predictions and distances -----------------------------------------
    def _predict(self, ent, t):
        dt = (t - ent.last_time_ms) / 1000.0
        if ent.models is not None:
            q = (self.pack.filter["accel_var"], self.pack.maneuver["accel_var"])
            return estimate.predict_models(ent.models, ent.mode, dt, q)
        q = self.pack.filter["accel_var"]
        return estimate.predict_axis(ent.east, dt, q), estimate.predict_axis(ent.north, dt, q)

    def _predict_in(self, b, t, a):
        """B's prediction to t for a comparison with A: B's timing variance
        added to pp (no shift without a bias estimate)."""
        return estimate.with_variance(self._predict(b, t), b.t_var)

    def _d2(self, a, b):
        return mahalanobis(a.east[0], a.north[0], self._predict_in(b, a.last_time_ms, a), a.r_meas)

    def _dist(self, a, b):
        return plane_distance(a.east[0], a.north[0], self._predict_in(b, a.last_time_ms, a))

    def _run_stage(self, stage, a, b, trace):
        return run_stage(self, stage, getattr(self.pack, stage), a, b, trace)

    @staticmethod
    def _pair(a, b):
        return a + "|" + b if a < b else b + "|" + a

    # reports -----------------------------------------------------------
    def _time_error_ms(self, report, source):
        """Reports, Time quality: the report's value, else the pack's
        time_default for its source, else 0."""
        v = report.get("time_error_ms")
        if v is not None:
            return float(v)
        return float(self.pack.time_default.get(source, {}).get("error_ms", 0.0))

    def _accept(self, report, events, trace):
        """Reports and Track estimate: validate, then update the filter.
        Returns the entity, or None when the report is rejected."""
        k = missing_key(report)
        if k is not None:
            events.append({"ev": "reject", "reason": "missing:" + k})
            return None
        report = normalize(report)
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
            vel = velocity(float(report["course"]), float(report["speed_ms"]))
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
        if ent is not None and self.pack.restart is not None:
            d2 = mahalanobis(e, n, pred, (re_, rn_))
            ok = d2 < self.pack.restart
            trace.append({"stage": "filter", "a": key, "b": None, "test": "restart",
                          "value": d2, "limit": self.pack.restart, "pass": ok})
            fresh = not ok
            if fresh and self.pack.method == "assign":
                self.restarted.add(key)
        if fresh:
            if ent is None:
                ent = Track(key, source)
                self.entities[key] = ent
                events.append({"ev": "new", "entity": key})
            ent.east, ent.north = estimate.first_axes(e, n, re_, rn_, vel, f)
            if self.pack.maneuver is not None:
                ent.models = [[list(ent.east), list(ent.north)], [list(ent.east), list(ent.north)]]
                ent.mode = estimate.first_mode(self.pack.maneuver)
        elif ent.models is not None:
            dt = (t - ent.last_time_ms) / 1000.0
            q = (f["accel_var"], self.pack.maneuver["accel_var"])
            ent.models, ent.mode, ent.east, ent.north, lam = estimate.two_model_update(
                ent.models, ent.mode, self.pack.maneuver, q, dt, e, n, (re_, rn_), vel,
                f["vel_sigma_ms"] ** 2)
            for j in (0, 1):
                trace.append({"stage": "filter", "a": ent.key, "b": MODELS[j], "test": "likelihood",
                              "value": lam[j], "limit": None, "pass": True})
            for j in (0, 1):
                trace.append({"stage": "filter", "a": ent.key, "b": MODELS[j], "test": "mode",
                              "value": ent.mode[j], "limit": None, "pass": True})
        else:
            dt = (t - ent.last_time_ms) / 1000.0
            ent.east, ent.north = estimate.update_axes(
                ent.east, ent.north, dt, f["accel_var"], e, n, re_, rn_, vel, f["vel_sigma_ms"] ** 2)
        ent.report = dict(report)
        ent.r_meas = (re_, rn_)
        ent.t_var = (ae, an)
        ent.time_err = te
        ent.last_time_ms = t
        return ent


def make_engine(pack):
    """The engine of a pack's method."""
    from .assign import AssignEngine
    from .confirm import ConfirmEngine
    return AssignEngine(pack) if pack.method == "assign" else ConfirmEngine(pack)
