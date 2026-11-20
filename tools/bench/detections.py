#!/usr/bin/env python3
"""Detection-level scenarios: synthetic moving-target radar dwells with ground truth.

For the `track` function (detections in, local tracks out) and then track
plus correlate end to end. A dwell is one scan of an area by an airborne
radar: a list of detections with position, range and cross-range errors and
radial velocity, and no track identity. Keys follow the shared model's
`detection` module (`detection.dwell_id`, `detection.items`, ...); an empty
dwell is an empty list, and a key that is not stated is absent.

    python3 -I tools/bench/detections.py generate [--set tuning|evaluation] [--out DIR]
    python3 -I tools/bench/detections.py score --scenarios DIR --tracks DIR

| Part | Model |
|---|---|
| Truth | 4 to 30 ground movers (vehicles, environment G; some surface vessels, S) on straight legs with turns and stops, 0 to 30 m/s |
| Platform | an airborne radar flying a racetrack 40 to 90 km from the area at 8 to 10 km height |
| Dwell | every `revisit` (8 to 20 s) the radar scans a circle of 15 to 25 km radius; the dwell is stated with its coverage (WKT) and revisit |
| Detection | a mover inside the circle is detected with probability Pd (0.7 to 0.95) when its radial speed is above the minimum detectable velocity (1 to 3 m/s); a stopped or tangential mover is not |
| Errors | range error 10 to 30 m along the line of sight, cross-range error = range times 1 to 3 mrad; radial velocity error 0.3 to 1 m/s; each stated per detection |
| Clutter | false detections in the circle, Poisson with mean 0 to 8 per dwell, random radial velocity |
| Order | the detections of a dwell are shuffled; `item_id` is their index |

Steps are in the vector format with `dwell` steps (the dwell object) in place
of `ingest`, and a `tick` every 1000 ms. The truth file holds, per dwell
step, the truth object of each detection (null for clutter), and the truth
positions per tick, as for the other families.

Scoring a track output (one events file per scenario, `ticks` with `tracks`
of `{"track": id, "lat", "lon"}`): per tick, GOSPA (c = 500 m, p = 2) between
the tracks and the movers inside the coverage; tracks are matched to movers
by minimum total distance under 500 m; an **identity swap** is a mover whose
matched track changes while the old track still exists; a **track break** is
a mover that loses its match for one tick or more and is matched again; a
**false track tick** is an unmatched track; a **missed tick** an unmatched
mover.
"""

import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import adapters  # noqa: E402
import dataset  # noqa: E402
import score as scoring  # noqa: E402
from scenarios import Obj, Rng, to_deg, to_plane, TICK_MS, LAT0, LON0  # noqa: E402

COUNT = 20             # scenarios per set
DURATION_S = 300


def _movers(r, n):
    objs = []
    for k in range(n):
        env = "S" if r.chance(0.2) else "G"
        sp = r.uniform(4, 30) if env == "G" else r.uniform(3, 10)
        moves = []
        t = r.uniform(10, 60)
        while t < DURATION_S - 30:
            kind = r.choice(["turn", "turn", "stop", "none"])
            if kind == "turn":
                moves.append((t, t + r.uniform(5, 15), r.choice([6.0, -6.0, 9.0, -9.0]), 0.0))
            elif kind == "stop" and env == "G":
                moves += [(t, t + 5, 0.0, -sp / 5.0), (t + 5 + r.uniform(10, 40), t + 10 + r.uniform(10, 40), 0.0, sp / 5.0)]
            t += r.uniform(40, 90)
        objs.append(Obj("m%d" % (k + 1), east=r.uniform(-12000, 12000), north=r.uniform(-12000, 12000), speed=sp,
                        heading=r.uniform(0, 360), alt=0.0, env=env, moves=moves))
    return objs


def build(name, seed):
    """(vector, truth) of one detection-level scenario."""
    r = Rng(seed)
    objs = _movers(r, r.integer(4, 30))
    om = {o.oid: o for o in objs}
    for o in objs:
        o.integrate(DURATION_S, om)
    standoff = r.uniform(40000, 90000)
    bearing = math.radians(r.uniform(0, 360))
    plat_alt = r.uniform(8000, 10000)
    plat_speed = r.uniform(120, 200)
    leg = r.uniform(20000, 40000)
    revisit = r.integer(8, 20) * 1000
    radius = r.uniform(15000, 25000)
    pd = r.uniform(0.7, 0.95)
    mdv = r.uniform(1.0, 3.0)
    sig_r, ang = r.uniform(10, 30), r.uniform(0.001, 0.003)
    sig_v = r.uniform(0.3, 1.0)
    clutter = r.uniform(0, 8)
    noise = r.fork("noise")
    phase = r.integer(0, revisit - 1)

    def platform(t_s):
        # Racetrack: back and forth on a leg perpendicular to the line to the area.
        cx, cy = standoff * math.sin(bearing), standoff * math.cos(bearing)
        ux, uy = math.cos(bearing), -math.sin(bearing)
        period = 2 * leg / plat_speed
        x = (t_s % period) / period
        s = leg * (2 * x if x < 0.5 else 2 - 2 * x) - leg / 2
        return cx + s * ux, cy + s * uy

    circle = []
    for k in range(16):
        a = 2 * math.pi * k / 16
        lat, lon = to_deg(radius * math.sin(a), radius * math.cos(a))
        circle.append("%.6f %.6f" % (lon, lat))
    wkt = "POLYGON((%s, %s))" % (", ".join(circle), circle[0])

    items_steps = []           # (time_ms, dwell, labels)
    k = 0
    while True:
        t_ms = phase + k * revisit
        if t_ms > DURATION_S * 1000:
            break
        t = t_ms / 1000.0
        pe, pn = platform(t)
        dets = []
        for o in objs:
            e, n, _, _ = o.state(t)
            if math.hypot(e, n) > radius:
                continue
            ve, vn = o.velocity(t)
            dx, dy = e - pe, n - pn
            rng_m = math.hypot(dx, dy)
            ux, uy = dx / rng_m, dy / rng_m
            vr = ve * ux + vn * uy                # positive away from the sensor
            det = noise.chance(pd)
            er, ec = noise.normal(sig_r), noise.normal(rng_m * ang)
            ev = noise.normal(sig_v)
            if not det or abs(vr) < mdv:
                continue
            me, mn = e + er * ux - ec * uy, n + er * uy + ec * ux
            dets.append((me, mn, vr + ev, rng_m, o.oid))
        nfalse = 0
        lam = math.exp(-clutter)
        p = noise.uniform(0, 1)
        while p > lam:                            # Poisson(clutter) by multiplication
            nfalse += 1
            p *= noise.uniform(0, 1)
        for _ in range(nfalse):
            a, rr = noise.uniform(0, 2 * math.pi), radius * math.sqrt(noise.uniform(0, 1))
            e, n = rr * math.sin(a), rr * math.cos(a)
            dets.append((e, n, noise.uniform(-20, 20), math.hypot(e - pe, n - pn), None))
        order = list(range(len(dets)))
        for i in range(len(order) - 1, 0, -1):    # Fisher-Yates with the scenario's own stream
            j = noise.integer(0, i)
            order[i], order[j] = order[j], order[i]
        items, labels = [], []
        for idx, i in enumerate(order):
            me, mn, vr, rng_m, oid = dets[i]
            lat, lon = to_deg(me, mn)
            items.append({"item_id": str(idx), "lat": round(lat, 7), "lon": round(lon, 7), "hae": 0.0,
                          "range_error_m": round(sig_r, 1), "cross_range_error_m": round(rng_m * ang, 1),
                          "radial_velocity_ms": round(vr, 2), "radial_velocity_error_ms": round(sig_v, 2),
                          "snr_db": round(noise.uniform(10, 25), 1)})
            labels.append(oid)
        plat_lat, plat_lon = to_deg(pe, pn)
        dwell = {"detection.dwell_id": "%s/%d" % (name, k + 1), "detection.time_ms": t_ms,
                 "detection.sensor_id": "gmti-1", "detection.sensor_lat": round(plat_lat, 7),
                 "detection.sensor_lon": round(plat_lon, 7), "detection.sensor_hae": round(plat_alt, 1),
                 "detection.revisit_ms": revisit, "detection.coverage_wkt": wkt, "detection.items": items}
        items_steps.append((t_ms + 500, dwell, labels))   # arrives 0.5 s after the dwell time
        k += 1
    steps, labels = [], []
    entries = [((t, 0), {"dwell": d}, lab) for t, d, lab in items_steps]
    entries += [((t, 1), {"tick": t}, None) for t in range(TICK_MS, DURATION_S * 1000 + 1, TICK_MS)]
    entries.sort(key=lambda x: x[0])
    for _, st, lab in entries:
        steps.append(st)
        labels.append(lab)
    ticks = list(range(TICK_MS, DURATION_S * 1000 + 1, TICK_MS))
    pos = {}
    for o in objs:
        pl = []
        for t in ticks:
            e, n, _, _ = o.state(t / 1000.0)
            pl.append([round(x, 9) for x in to_deg(e, n)] if math.hypot(e, n) <= radius else None)
        pos[o.oid] = {"env": o.env, "pos": pl}
    truth = {"name": name, "family": "detections", "ref": [LAT0, LON0], "ticks": ticks, "labels": labels,
             "objects": pos,
             "tests": "%d movers; dwell every %d s over a %.0f km circle from %.0f km; Pd %.2f, MDV %.1f m/s, "
                      "clutter %.1f per dwell" % (len(objs), revisit // 1000, radius / 1000, standoff / 1000, pd,
                                                 mdv, clutter)}
    return {"name": name, "pack": None, "steps": steps}, truth


def scenarios_of(which):
    if which == "tuning":
        root, prefix = dataset.TUNING_ROOT, ""
    else:
        root, prefix = dataset.eval_root(), "eval-"
        if root is None:
            raise SystemExit("no evaluation seeds (%s)" % dataset.EVAL_SEEDS)
    out = []
    for i in range(COUNT):
        name = "%sdetections-%02d" % (prefix, i + 1)
        out.append((name, dataset._seed(root, "detections-%02d" % (i + 1))))
    return out


def score_tracks(truth, ticks):
    """Scores of one track output against truth (module docstring, "Scoring")."""
    swaps = breaks = false_t = missed_t = 0
    gospa_sum = 0.0
    sq, nerr = 0.0, 0
    last = {}           # mover -> track it was matched to
    gone = set()        # movers that lost their match
    for i, now in enumerate(truth["ticks"]):
        tracks = [t for t in ticks.get(now, []) if t.get("lat") is not None]
        X = [to_plane(t["lat"], t["lon"]) for t in tracks]
        movers = sorted(m for m, o in truth["objects"].items() if o["pos"][i] is not None)
        Y = [to_plane(*truth["objects"][m]["pos"][i]) for m in movers]
        g, _, _, _ = scoring.gospa(X, Y)
        gospa_sum += g
        n = max(len(X), len(Y))
        match = {}
        if X and Y:
            big = 1e12
            cost = [[(math.dist(X[a], Y[b]) if a < len(X) and b < len(Y) else big) for b in range(n)]
                    for a in range(n)]
            col = scoring.hungarian(cost)
            for a, b in enumerate(col):
                if a < len(X) and b < len(Y) and cost[a][b] < scoring.GOSPA_C:
                    match[movers[b]] = (tracks[a]["track"], cost[a][b])
        ids_now = {t["track"] for t in tracks}
        for m in movers:
            if m in match:
                tid, d = match[m]
                sq += d * d
                nerr += 1
                if m in last and last[m] != tid and last[m] in ids_now:
                    swaps += 1
                if m in gone:
                    breaks += 1
                    gone.discard(m)
                last[m] = tid
            else:
                missed_t += 1
                if m in last:
                    gone.add(m)
        false_t += len(tracks) - len(match)
    nt = len(truth["ticks"])
    return {"gospa_m": gospa_sum / nt if nt else None, "rms_m": math.sqrt(sq / nerr) if nerr else None,
            "swaps": swaps, "breaks": breaks, "false_track_ticks": false_t, "missed_ticks": missed_t,
            "ticks": nt}


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--set", default="tuning", choices=["tuning", "evaluation"])
    g.add_argument("--out", default=os.path.join(adapters.ROOT, "build", "bench", "detections"))
    s = sub.add_parser("score")
    s.add_argument("--scenarios", required=True)
    s.add_argument("--tracks", required=True)
    a = ap.parse_args()
    if a.cmd == "generate":
        n = 0
        for name, seed in scenarios_of(a.set):
            v, t = build(name, seed)
            adapters.write_json(os.path.join(a.out, name + ".json"), v)
            adapters.write_json(os.path.join(a.out, name + ".truth.json"), t)
            n += 1
        print("wrote %d detection-level scenarios to %s" % (n, a.out))
    else:
        rows = {}
        for f in sorted(os.listdir(a.scenarios)):
            if not f.endswith(".truth.json"):
                continue
            name = f[:-len(".truth.json")]
            p = os.path.join(a.tracks, name + ".events.json")
            if not os.path.exists(p):
                continue
            with open(os.path.join(a.scenarios, f), encoding="utf-8") as fh:
                truth = json.load(fh)
            with open(p, encoding="utf-8") as fh:
                doc = json.load(fh)
            ticks = {t["now_ms"]: t["tracks"] for t in doc["ticks"]}
            rows[name] = score_tracks(truth, ticks)
        print(json.dumps(rows, indent=1))


if __name__ == "__main__":
    main()
