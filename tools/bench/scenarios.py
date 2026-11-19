"""Benchmark scenarios with ground truth.

A scenario is a set of truth objects (where each object really is at every
time) and a set of sensors that report tracks of those objects with stated
errors. Writing a scenario gives two files:

- `<name>.json`, the report stream in the vector format (`steps` only: each
  step an `ingest` or a `tick`, in arrival order);
- `<name>.truth.json`, for each ingest step the truth object it reports
  (`null` for a false track) and every object's position at every tick.

Everything random comes from `Rng`, a generator written here, so the files are
the same on every Python version and platform.
"""

import math

R = 6371008.8
LAT0, LON0 = 50.0, 10.0          # reference point of every scenario
TICK_MS = 1000                   # one tick per second of input time
STEP_S = 0.1                     # integration step of the truth motion

# ---------------------------------------------------------------------------
# Random numbers


MASK64 = (1 << 64) - 1


class Rng:
    """splitmix64: a 64-bit counter passed through a fixed mixing function."""

    def __init__(self, seed):
        self.state = seed & MASK64

    def u64(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK64
        return z ^ (z >> 31)

    def uniform(self, lo=0.0, hi=1.0):
        """Uniform in [lo, hi): the top 53 bits as a fraction."""
        return lo + (hi - lo) * ((self.u64() >> 11) / 9007199254740992.0)

    def integer(self, lo, hi):
        """Uniform integer in [lo, hi]."""
        return lo + self.u64() % (hi - lo + 1)

    def normal(self, sigma=1.0):
        """Approximately normal: the sum of 12 uniforms minus 6 (arithmetic only)."""
        return sigma * (sum(self.uniform() for _ in range(12)) - 6.0)

    def chance(self, p):
        return self.uniform() < p

    def choice(self, items):
        return items[self.integer(0, len(items) - 1)]

    def fork(self, tag):
        """An independent generator for one named part of a scenario."""
        h = 0xCBF29CE484222325          # FNV-1a over the tag, mixed with this state
        for b in tag.encode("utf-8"):
            h = ((h ^ b) * 0x100000001B3) & MASK64
        return Rng(h ^ self.u64())


# ---------------------------------------------------------------------------
# Frame


def to_deg(east, north):
    lat = LAT0 + math.degrees(north / R)
    lon = LON0 + math.degrees(east / (R * math.cos(math.radians(LAT0))))
    return lat, lon


def to_plane(lat, lon):
    return (R * math.radians(lon - LON0) * math.cos(math.radians(LAT0)),
            R * math.radians(lat - LAT0))


# ---------------------------------------------------------------------------
# Truth objects


class Obj:
    """One truth object.

    Motion starts at (east, north) with `speed` m/s on `heading` degrees
    (clockwise from north). `moves` is a list of (start_s, end_s, turn_dps,
    accel_mps2): between start and end the heading changes at turn_dps and the
    speed at accel_mps2. With `parent`, the object appears at `born_s` at the
    parent's position and velocity (a split).
    """

    def __init__(self, oid, east=0.0, north=0.0, speed=0.0, heading=0.0, alt=3000.0,
                 env="A", moves=(), born_s=0.0, parent=None):
        self.oid, self.env, self.alt = oid, env, alt
        self.e0, self.n0, self.v0, self.h0 = east, north, speed, heading
        self.moves, self.born_s, self.parent = list(moves), born_s, parent
        self.track = None   # list of (east, north, speed, heading) every STEP_S from born_s

    def integrate(self, duration_s, objects):
        if self.parent is not None:
            p = objects[self.parent]
            e, n, v, h = p.state(self.born_s)
            v = self.v0 if self.v0 else v
            h = h + self.h0           # heading offset from the parent at the split
        else:
            e, n, v, h = self.e0, self.n0, self.v0, self.h0
        steps = int(round((duration_s - self.born_s) / STEP_S))
        out = [(e, n, v, h)]
        for i in range(steps):
            t = self.born_s + i * STEP_S
            turn = accel = 0.0
            for (t0, t1, dps, acc) in self.moves:
                if t0 <= t < t1:
                    turn, accel = dps, acc
            h_mid = h + turn * STEP_S / 2
            v_mid = max(0.0, v + accel * STEP_S / 2)
            e += v_mid * math.sin(math.radians(h_mid)) * STEP_S
            n += v_mid * math.cos(math.radians(h_mid)) * STEP_S
            h = (h + turn * STEP_S) % 360.0
            v = max(0.0, v + accel * STEP_S)
            out.append((e, n, v, h))
        self.track = out

    def exists(self, t_s):
        return self.born_s <= t_s <= self.born_s + (len(self.track) - 1) * STEP_S + 1e-9

    def state(self, t_s):
        """(east, north, speed, heading) at t_s, linear between integration steps."""
        x = (t_s - self.born_s) / STEP_S
        i = min(max(int(math.floor(x)), 0), len(self.track) - 2)
        f = x - i
        a, b = self.track[i], self.track[i + 1]
        dh = ((b[3] - a[3] + 180.0) % 360.0) - 180.0
        return (a[0] + f * (b[0] - a[0]), a[1] + f * (b[1] - a[1]),
                a[2] + f * (b[2] - a[2]), (a[3] + f * dh) % 360.0)

    def velocity(self, t_s):
        _, _, v, h = self.state(t_s)
        return v * math.sin(math.radians(h)), v * math.cos(math.radians(h))


# ---------------------------------------------------------------------------
# Sensors


class Sensor:
    """One source of tracks.

    | Field | Meaning |
    |---|---|
    | `period_ms`, `jitter_ms` | report interval; each time moves by up to +-jitter |
    | `sigma_m` | true position noise, one sigma per axis |
    | `ce` | `honest` (reports sigma_m), `understated` (sigma_m / ce_factor), `absent` |
    | `pd` | probability each report is made |
    | `latency_ms` | arrival delay after the report's valid time |
    | `bias_m` | fixed (east, north) offset added to every position |
    | `vel_sigma` | velocity noise per axis, m/s; None: no course or speed |
    | `hae_sigma` | height noise, m; None: no height |
    | `swaps` | (t_s, oid_a, oid_b): from t_s the two objects' track numbers trade places |
    | `drops` | (t_s, oid, gap_s): the track ends at t_s; after gap_s a new number starts |
    | `false_tracks` | number of false tracks over the scenario |
    | `sees` | object ids reported (None: all) |
    | `clock_offset_ms`, `clock_drift_ms_min` | the sensor's clock error: a report made at true time t is stamped t + offset + drift * t / 60 s. The position is measured at t (truth stays exact); a report stamped before 0 is not sent |
    | `delivery_spread_ms` | extra delay after `latency_ms`, uniform in 0 to this, drawn per report; reports then arrive out of order |
    | `time_state` | None: reports carry no time quality. Otherwise `time_state` (`coherent`, `drifting` or `free-running`) and `time_error_ms` on every report: the clock's error at that report, rounded up, at least 1 ms; twice that when free-running (such a clock knows only a loose bound). Keys as in spec/correlate.md, "Time quality" |
    """

    def __init__(self, source, period_ms=1000, jitter_ms=0, sigma_m=20.0, ce="honest",
                 ce_factor=1.0, pd=1.0, latency_ms=0, bias_m=(0.0, 0.0), vel_sigma=2.0,
                 hae_sigma=30.0, swaps=(), drops=(), false_tracks=0, sees=None,
                 clock_offset_ms=0, clock_drift_ms_min=0.0, delivery_spread_ms=0, time_state=None):
        self.source = source
        self.period_ms, self.jitter_ms = period_ms, jitter_ms
        self.sigma_m, self.ce, self.ce_factor = sigma_m, ce, ce_factor
        self.pd, self.latency_ms, self.bias_m = pd, latency_ms, bias_m
        self.vel_sigma, self.hae_sigma = vel_sigma, hae_sigma
        self.swaps, self.drops = list(swaps), list(drops)
        self.false_tracks, self.sees = false_tracks, sees
        self.clock_offset_ms, self.clock_drift_ms_min = clock_offset_ms, clock_drift_ms_min
        self.delivery_spread_ms, self.time_state = delivery_spread_ms, time_state

    def clock_error_ms(self, t):
        """Stamped minus true time for a report made at true time t (ms)."""
        return self.clock_offset_ms + self.clock_drift_ms_min * t / 60000.0

    def max_clock_error_ms(self, duration_s):
        return max(abs(self.clock_error_ms(0)), abs(self.clock_error_ms(duration_s * 1000)))

    def summary(self):
        parts = ["%s %gs" % (self.source, self.period_ms / 1000.0), "sigma %g m" % self.sigma_m]
        if self.ce == "understated":
            parts.append("error reported /%g" % self.ce_factor)
        elif self.ce == "absent":
            parts.append("no error reported")
        if self.jitter_ms:
            parts.append("jitter %g s" % (self.jitter_ms / 1000.0))
        if self.pd < 1:
            parts.append("Pd %g" % self.pd)
        if self.latency_ms:
            parts.append("latency %g s" % (self.latency_ms / 1000.0))
        if self.bias_m != (0.0, 0.0):
            parts.append("bias %g m" % math.hypot(*self.bias_m))
        if self.swaps:
            parts.append("%d number swap" % len(self.swaps))
        if self.drops:
            parts.append("%d drop" % len(self.drops))
        if self.false_tracks:
            parts.append("%d false" % self.false_tracks)
        if self.clock_offset_ms:
            parts.append("clock %+g ms" % self.clock_offset_ms)
        if self.clock_drift_ms_min:
            parts.append("clock drift %+g ms/min" % self.clock_drift_ms_min)
        if self.delivery_spread_ms:
            parts.append("delivery +0 to %g s" % (self.delivery_spread_ms / 1000.0))
        if self.time_state:
            parts.append("time %s" % self.time_state)
        return ", ".join(parts)


def radar(**kw):
    base = dict(period_ms=4000, jitter_ms=200, sigma_m=60.0, pd=0.9, latency_ms=500,
                vel_sigma=5.0, hae_sigma=100.0)
    base.update(kw)
    return Sensor(kw.pop("source", "radar"), **{k: v for k, v in base.items() if k != "source"})


def beacon(**kw):
    base = dict(period_ms=1000, jitter_ms=100, sigma_m=15.0, pd=0.98, latency_ms=300,
                vel_sigma=1.0, hae_sigma=15.0)
    base.update(kw)
    return Sensor(kw.pop("source", "beacon"), **{k: v for k, v in base.items() if k != "source"})


def passive(**kw):
    base = dict(period_ms=2000, jitter_ms=300, sigma_m=250.0, pd=0.8, latency_ms=1000,
                vel_sigma=None, hae_sigma=None)
    base.update(kw)
    return Sensor(kw.pop("source", "passive"), **{k: v for k, v in base.items() if k != "source"})


# ---------------------------------------------------------------------------
# Scenario


class Scenario:
    def __init__(self, name, family, tests, objects, sensors, duration_s=120, seed=1):
        self.name, self.family, self.tests = name, family, tests
        self.objects = {o.oid: o for o in objects}
        self.order = [o.oid for o in objects]
        self.sensors, self.duration_s, self.seed = sensors, duration_s, seed

    def build(self):
        """The steps (vector format), the truth label of each step, and the truth positions."""
        for oid in self.order:
            self.objects[oid].integrate(self.duration_s, self.objects)
        rng = Rng(self.seed)
        reports = []          # (arrival_ms, source, uid, report, truth oid or None)
        for s in self.sensors:
            reports.extend(self._sensor_reports(s, rng.fork(s.source)))
        end_ms = self.duration_s * 1000
        items = [((r[0], 0, r[1], r[2]), {"ingest": r[3]}, r[4]) for r in reports if r[0] <= end_ms]
        for t in range(TICK_MS, end_ms + 1, TICK_MS):
            items.append(((t, 1, "", ""), {"tick": t}, None))
        items.sort(key=lambda x: x[0])
        steps = [x[1] for x in items]
        labels = [x[2] for x in items]
        ticks = [t for t in range(TICK_MS, end_ms + 1, TICK_MS)]
        objs = {}
        for oid in self.order:
            o = self.objects[oid]
            pos = []
            for t in ticks:
                if o.exists(t / 1000.0):
                    e, n, _, _ = o.state(t / 1000.0)
                    lat, lon = to_deg(e, n)
                    pos.append([round(lat, 9), round(lon, 9)])
                else:
                    pos.append(None)
            objs[oid] = {"env": o.env, "pos": pos}
        live_ms = max(2 * s.period_ms + s.jitter_ms + s.latency_ms + s.delivery_spread_ms
                      + int(math.ceil(s.max_clock_error_ms(self.duration_s))) for s in self.sensors)
        vector = {"name": self.name, "pack": None, "steps": steps}
        truth = {"name": self.name, "family": self.family, "tests": self.tests,
                 "ref": [LAT0, LON0], "live_ms": live_ms, "ticks": ticks,
                 "sensors": [s.summary() for s in self.sensors],
                 "objects": objs, "labels": labels}
        return vector, truth

    def _sensor_reports(self, s, rng):
        out = []
        seen = [oid for oid in self.order if s.sees is None or oid in s.sees]
        # Track numbers: one per object in order; swaps and drops change them.
        counter = [0]

        def new_uid():
            counter[0] += 1
            return "T%d" % counter[0]

        uid_of = {oid: new_uid() for oid in seen}
        events = sorted([(t, 0, ("swap", a, b)) for (t, a, b) in s.swaps]
                        + [(t, 1, ("drop", o, g)) for (t, o, g) in s.drops])
        gaps = {}              # oid -> time the new number starts
        phase = rng.integer(0, s.period_ms - 1)
        noise = rng.fork("noise")
        k = 0
        ei = 0
        while True:
            t_nom = phase + k * s.period_ms
            if t_nom > self.duration_s * 1000:
                break
            k += 1
            while ei < len(events) and events[ei][0] * 1000 <= t_nom:
                kind = events[ei][2]
                if kind[0] == "swap":
                    _, a, b = kind
                    uid_of[a], uid_of[b] = uid_of[b], uid_of[a]
                else:
                    _, o, g = kind
                    uid_of[o] = None
                    gaps[o] = events[ei][0] + g
                ei += 1
            for oid in seen:
                if uid_of[oid] is None and t_nom >= gaps[oid] * 1000:
                    uid_of[oid] = new_uid()
            for oid in seen:
                j = noise.integer(-s.jitter_ms, s.jitter_ms) if s.jitter_ms else 0
                detected = noise.chance(s.pd)
                t = max(0, t_nom + j)
                o = self.objects[oid]
                if uid_of[oid] is None or not detected or not o.exists(t / 1000.0):
                    continue
                e, n, _, _ = o.state(t / 1000.0)
                ve, vn = o.velocity(t / 1000.0)
                r = self._report(s, noise, uid_of[oid], t, e, n, ve, vn, o.alt, o.env, oid)
                if r is not None:
                    out.append(r)
        # False tracks: each lives 20-60 s, near the objects, on a straight line.
        fr = rng.fork("false")
        for i in range(s.false_tracks):
            life = fr.uniform(20.0, 60.0)
            start = fr.uniform(0.0, max(1.0, self.duration_s - life))
            anchor = self.objects[fr.choice(self.order)]
            ae, an, _, _ = anchor.state(min(max(start, anchor.born_s), self.duration_s))
            e0, n0 = ae + fr.uniform(-3000, 3000), an + fr.uniform(-3000, 3000)
            sp, hd = fr.uniform(0.0, 250.0), fr.uniform(0.0, 360.0)
            ve, vn = sp * math.sin(math.radians(hd)), sp * math.cos(math.radians(hd))
            uid = "F%d" % (i + 1)
            t = int(start * 1000) + fr.integer(0, s.period_ms - 1)
            while t <= (start + life) * 1000 and t <= self.duration_s * 1000:
                dt = t / 1000.0 - start
                if fr.chance(s.pd):
                    r = self._report(s, fr, uid, t, e0 + ve * dt, n0 + vn * dt, ve, vn,
                                     anchor.alt, anchor.env, None)
                    if r is not None:
                        out.append(r)
                t += s.period_ms
        return out

    @staticmethod
    def _report(s, rng, uid, t, e, n, ve, vn, alt, env, oid):
        me = e + s.bias_m[0] + rng.normal(s.sigma_m)
        mn = n + s.bias_m[1] + rng.normal(s.sigma_m)
        lat, lon = to_deg(me, mn)
        err = s.clock_error_ms(t)
        stamped = int(round(t + err))
        rep = {"track.source_id": s.source, "uid": uid, "time_ms": stamped,
               "lat": round(lat, 7), "lon": round(lon, 7)}
        if s.hae_sigma is not None and env == "A":
            rep["hae"] = round(alt + rng.normal(s.hae_sigma), 0)
        if s.ce == "honest":
            rep["ce"] = round(s.sigma_m, 1)
        elif s.ce == "understated":
            rep["ce"] = round(s.sigma_m / s.ce_factor, 1)
        if s.vel_sigma is not None:
            mve = ve + rng.normal(s.vel_sigma)
            mvn = vn + rng.normal(s.vel_sigma)
            rep["course"] = round(math.degrees(math.atan2(mve, mvn)) % 360.0, 1)
            rep["speed_ms"] = round(math.hypot(mve, mvn), 1)
        rep["type"] = "a-u-" + env
        if s.time_state:
            rep["time_state"] = s.time_state
            bound = abs(err) * (2 if s.time_state == "free-running" else 1)
            rep["time_error_ms"] = max(1, int(math.ceil(bound)))
        delay = rng.integer(0, s.delivery_spread_ms) if s.delivery_spread_ms else 0
        if stamped < 0:
            return None
        return (t + s.latency_ms + delay, s.source, uid, rep, oid)


# ---------------------------------------------------------------------------
# The named scenarios


def named():
    """Every named scenario, each testing one thing."""
    S = []

    def add(name, family, tests, objects, sensors, **kw):
        kw.setdefault("seed", len(S) + 101)
        S.append(Scenario(name, family, tests, objects, sensors, **kw))

    two = lambda **kw: [radar(**kw.get("r", {})), beacon(**kw.get("b", {}))]  # noqa: E731

    add("stationary", "motion", "one object that does not move, two sensors",
        [Obj("o1", speed=0.0)], two())
    add("straight-level", "motion", "one object on a straight line at 200 m/s",
        [Obj("o1", speed=200.0, heading=60.0)], two())
    add("turn-3dps", "motion", "coordinated turn of 3 deg/s for 60 s at 150 m/s",
        [Obj("o1", speed=150.0, heading=0.0, moves=[(30, 90, 3.0, 0.0)])], two())
    add("turn-6dps", "motion", "coordinated turn of 6 deg/s for 45 s at 200 m/s",
        [Obj("o1", speed=200.0, heading=90.0, moves=[(30, 75, 6.0, 0.0)])], two())
    add("accelerate", "motion", "speed 100 to 300 m/s at 10 m/s^2, then back down",
        [Obj("o1", speed=100.0, heading=30.0, moves=[(20, 40, 0.0, 10.0), (70, 90, 0.0, -10.0)])],
        two())
    add("crossing-90deg", "geometry", "two objects cross at right angles, 1 km apart in height",
        [Obj("o1", east=-12000.0, speed=200.0, heading=90.0),
         Obj("o2", north=-12000.0, speed=200.0, heading=0.0, alt=4000.0)], two())
    add("crossing-20deg", "geometry", "two objects cross at 20 degrees at the same height",
        [Obj("o1", east=-6000.0 * math.sin(math.radians(10)), north=-6000.0 * math.cos(math.radians(10)),
             speed=100.0, heading=10.0),
         Obj("o2", east=6000.0 * math.sin(math.radians(10)), north=-6000.0 * math.cos(math.radians(10)),
             speed=100.0, heading=350.0)], two())
    add("parallel-500m", "geometry", "two objects abreast 500 m apart, same velocity",
        [Obj("o1", speed=150.0, heading=0.0), Obj("o2", east=500.0, speed=150.0, heading=0.0)], two())
    add("parallel-150m", "geometry", "close formation: two objects abreast 150 m apart",
        [Obj("o1", speed=150.0, heading=0.0), Obj("o2", east=150.0, speed=150.0, heading=0.0)], two())
    add("split", "geometry", "one object splits into two at 50 s; the new one turns away at 4 deg/s",
        [Obj("o1", speed=150.0, heading=45.0),
         Obj("o2", parent="o1", born_s=50.0, heading=0.0, moves=[(50, 80, 4.0, 0.0)])], two())
    add("error-understated", "sensor error", "the radar reports a third of its true error",
        [Obj("o1", speed=150.0, heading=120.0)], two(r=dict(ce="understated", ce_factor=3.0)))
    add("error-absent", "sensor error", "neither sensor reports its error",
        [Obj("o1", speed=150.0, heading=120.0)], two(r=dict(ce="absent"), b=dict(ce="absent")))
    add("latency-3s", "sensor error", "the radar's reports arrive 3 s after their time, object at 250 m/s",
        [Obj("o1", speed=250.0, heading=200.0)], two(r=dict(latency_ms=3000)))
    add("bias-400m", "sensor error", "the radar's positions are all 400 m off to the north-east",
        [Obj("o1", speed=150.0, heading=300.0)], two(r=dict(bias_m=(283.0, 283.0))))
    add("slow-jittered", "sensor error", "radar every 12 s with 3 s jitter",
        [Obj("o1", speed=150.0, heading=0.0, moves=[(40, 70, 3.0, 0.0)])],
        two(r=dict(period_ms=12000, jitter_ms=3000)))
    add("low-detection", "sensor error", "both sensors detect half of the time",
        [Obj("o1", speed=150.0, heading=0.0), Obj("o2", east=3000.0, speed=150.0, heading=0.0)],
        two(r=dict(pd=0.5), b=dict(pd=0.5)))
    add("number-swap", "track management", "the radar trades the track numbers of two objects at 60 s",
        [Obj("o1", speed=150.0, heading=0.0), Obj("o2", east=1500.0, speed=150.0, heading=0.0)],
        two(r=dict(swaps=[(60, "o1", "o2")])))
    add("number-drop", "track management", "each sensor drops its track and starts a new number",
        [Obj("o1", speed=150.0, heading=90.0)],
        two(r=dict(drops=[(40, "o1", 8)]), b=dict(drops=[(70, "o1", 5)])))
    add("false-tracks", "clutter", "the radar reports 8 false tracks near the objects",
        [Obj("o1", speed=150.0, heading=0.0), Obj("o2", east=4000.0, speed=120.0, heading=180.0, north=8000.0)],
        two(r=dict(false_tracks=8)))
    add("three-sensors", "mixed", "radar, beacon and a coarse passive sensor, three objects",
        [Obj("o1", speed=150.0, heading=0.0),
         Obj("o2", east=5000.0, speed=200.0, heading=270.0, moves=[(40, 70, -3.0, 0.0)]),
         Obj("o3", east=-3000.0, north=4000.0, speed=0.0, env="S", alt=0.0)],
        [radar(), beacon(), passive()])
    dense = []
    r0 = Rng(7)
    for i in range(8):
        dense.append(Obj("o%d" % (i + 1), east=r0.uniform(-10000, 10000), north=r0.uniform(-10000, 10000),
                         speed=r0.uniform(80, 250), heading=r0.uniform(0, 360),
                         alt=r0.choice([2000.0, 3000.0, 3000.0, 5000.0]),
                         moves=[(r0.uniform(10, 60), r0.uniform(70, 110), r0.choice([0.0, 3.0, -3.0]), 0.0)]))
    add("dense-8", "mixed", "eight objects in a 20 km box, some turning", dense, two())

    # Time quality. One object at 300 m/s seen by a radar and two beacons; the
    # second beacon's clock is wrong (200 ms is 60 m along track). The object
    # turns 90 degrees every 100 s (3 deg/s for 30 s, from 40 s on), so the
    # along-track error of a clock changes direction: a fixed position bias
    # cannot stand in for it. In a "described" scenario every sensor reports
    # its time quality honestly (the good clocks: coherent, 1 ms); an
    # "undescribed" twin carries none.
    def fast(duration_s):
        turns = [(t0, t0 + 30, 3.0, 0.0) for t0 in range(40, duration_s - 30, 100)]
        return [Obj("o1", speed=300.0, heading=70.0, moves=turns)]

    def timed(described, **b2):
        good = dict(time_state="coherent") if described else {}
        bad = dict(b2)
        if not described:
            bad.pop("time_state", None)
        return [radar(**good), beacon(**good), beacon(source="beacon2", **dict(good, **bad))]

    # A twin shares its described scenario's seed: same reports, only the time keys differ.
    base = len(S) + 101
    for described in (True, False):
        tail = "" if described else "-undescribed"
        how = ("every sensor reports its time quality" if described
               else "no time quality on any report")
        add("clock-offset-200ms" + tail, "time",
            "beacon2's clock is 200 ms ahead, object at 300 m/s turning 90 deg every 100 s; " + how,
            fast(120), timed(described, clock_offset_ms=200, time_state="coherent"), seed=base)
        add("clock-drift-10ms-min" + tail, "time",
            "beacon2's clock drifts 10 ms per minute from 0 to 200 ms over 20 min; " + how,
            fast(1200), timed(described, clock_drift_ms_min=10.0, time_state="drifting"), duration_s=1200,
            seed=base + 1)
        add("clock-free-running" + tail, "time",
            "beacon2's clock runs free: 1.5 s behind, drifting 30 ms per minute further; " + how,
            fast(300), timed(described, clock_offset_ms=-1500, clock_drift_ms_min=-30.0,
                          time_state="free-running"), duration_s=300, seed=base + 2)
    add("out-of-order", "time",
        "beacon2's reports arrive 0.3 to 2.8 s after their time, so out of order; clocks coherent",
        fast(120), timed(True, delivery_spread_ms=2500), seed=base + 3)
    return S


def randomized(count=50, seed=20261119):
    """A seeded random set for averages: 2-4 objects, 2-3 sensors, random errors."""
    out = []
    root = Rng(seed)
    for i in range(count):
        r = root.fork("random-%02d" % (i + 1))
        objs = []
        for j in range(r.integer(2, 4)):
            kind = r.choice(["still", "straight", "straight", "turn", "turn", "accel"])
            speed = 0.0 if kind == "still" else r.uniform(80, 250)
            moves = []
            if kind == "turn":
                t0 = r.uniform(10, 60)
                moves = [(t0, t0 + r.uniform(20, 50), r.choice([3.0, -3.0, 6.0, -6.0]), 0.0)]
            elif kind == "accel":
                t0 = r.uniform(10, 60)
                moves = [(t0, t0 + 15, 0.0, r.choice([5.0, 10.0, -5.0]))]
            objs.append(Obj("o%d" % (j + 1), east=r.uniform(-6000, 6000), north=r.uniform(-6000, 6000),
                            speed=speed, heading=r.uniform(0, 360),
                            alt=r.choice([1000.0, 3000.0, 3000.0, 6000.0]), moves=moves))
        sensors = []
        for k, make in enumerate([radar, beacon, passive][:r.integer(2, 3)]):
            kw = {}
            if r.chance(0.25):
                kw["ce"] = r.choice(["understated", "absent"])
                kw["ce_factor"] = r.choice([2.0, 3.0])
            if r.chance(0.2):
                kw["bias_m"] = (r.uniform(-300, 300), r.uniform(-300, 300))
            if r.chance(0.2):
                kw["latency_ms"] = r.integer(1000, 3000)
            if r.chance(0.2):
                kw["pd"] = r.uniform(0.5, 0.9)
            if r.chance(0.2) and len(objs) >= 2:
                kw["swaps"] = [(r.uniform(30, 90), "o1", "o2")]
            if r.chance(0.2):
                kw["drops"] = [(r.uniform(20, 90), "o1", r.uniform(3, 10))]
            if r.chance(0.2):
                kw["false_tracks"] = r.integer(1, 5)
            sensors.append(make(**kw))
        out.append(Scenario("random-%02d" % (i + 1), "random", "seeded random mix", objs, sensors,
                            seed=r.u64()))
    return out
