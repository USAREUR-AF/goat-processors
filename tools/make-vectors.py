#!/usr/bin/env python3
"""Write the conformance vectors for packs/gnn and packs/window.

Each scenario below states its inputs and, in `decide`, the association
events it must produce. The script runs the Python engine, refuses to write a
vector whose events differ from `decide`, and records the full events, trace
and final snapshot as the vector. The decisions are stated by hand here; the
numbers come from the engine and are checked by the other six engines.

Run: python3 -I tools/make-vectors.py
"""

import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "engines", "python", "src"))
from goat_correlator import Engine, load_pack  # noqa: E402

R = 6371008.8
LAT0, LON0 = 1.0, 1.0  # notional: open ocean near 0 N 0 E


def at(east_m, north_m, lat0=LAT0, lon0=LON0):
    lat = lat0 + math.degrees(north_m / R)
    lon = lon0 + math.degrees(east_m / (R * math.cos(math.radians(lat0))))
    return round(lat, 9), round(lon, 9)


def rep(src, uid, t, e, n, **kw):
    lat, lon = at(e, n, kw.pop("lat0", LAT0), kw.pop("lon0", LON0))
    r = {"track.source_id": src, "uid": uid, "time_ms": t, "lat": lat, "lon": lon}
    r.update(kw)
    return r


AIR = {"type": "a-f-A-M-F", "track.simulated": 0}
SEA = {"type": "a-u-S-X", "track.simulated": 0}


def air(**kw):
    d = dict(AIR)
    d.update(kw)
    return d


SCENARIOS = []


def scenario(name, pack, steps, decide):
    SCENARIOS.append((name, pack, steps, decide))


# 1. Two sources see one stationary object; second consecutive pass correlates.
scenario("01-two-sources-one-object", "gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, hae=3000, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 20, -10, ce=30, hae=3050, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 5, 0, ce=30, hae=3000, **AIR)),
    ("tick", 1500),
], [["new"], ["new"], ["correlate"], ["fused"]])

# 2. Two objects 10 km apart never correlate.
scenario("02-far-apart-stay-separate", "gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10000, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 1000, 10000, 0, ce=30, **AIR)),
    ("tick", 1500),
], [["new"], ["new"], [], [], []])

# 3. Two tracks from one source are never grouped, however close.
scenario("03-same-source-never-grouped", "gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T2", 0, 5, 5, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T2", 1000, 5, 5, ce=30, **AIR)),
], [["new"], ["new"], [], []])

# 4. A moving pair correlates, then one track turns away and the group dissolves
#    after two consecutive hold failures.
mv = dict(course=90, speed_ms=100, ce=30, **AIR)
scenario("04-separation-dissolves", "gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, **mv)),
    ("ingest", rep("adsb", "A7", 0, 10, 10, **mv)),
    ("ingest", rep("radar-1", "T1", 1000, 100, 0, **mv)),
    ("ingest", rep("adsb", "A7", 2000, 210, 10, **mv)),
    ("ingest", rep("adsb", "A7", 3000, 300, 2000, ce=30, course=0, speed_ms=100, **AIR)),
    ("ingest", rep("adsb", "A7", 4000, 300, 4000, ce=30, course=0, speed_ms=100, **AIR)),
    ("tick", 4500),
], [["new"], ["new"], ["correlate"], [], [], ["leave", "dissolve"], []])

# 5. A grouped track goes silent; at the tick past stale_ms it leaves and drops.
scenario("05-stale-member-drops", "gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 120000, 10, 0, ce=30, **AIR)),
    ("tick", 121001),
    ("tick", 125000),
], [["new"], ["new"], ["correlate"], [], ["leave", "dissolve", "drop"], []])

# 6. A third source joins an existing group.
scenario("06-third-source-joins", "gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("eo-2", "E3", 1000, -15, 5, ce=40, **AIR)),
    ("ingest", rep("eo-2", "E3", 2000, -15, 5, ce=40, **AIR)),
    ("tick", 2500),
], [["new"], ["new"], ["correlate"], ["new"], ["join"], ["fused"]])

# 7. Two candidates confirm on the same report; the nearer one is chosen.
scenario("07-nearest-candidate-wins", "gnn", [
    ("ingest", rep("adsb", "A7", 0, 60, 0, ce=40, **AIR)),
    ("ingest", rep("eo-2", "E3", 0, 5, 0, ce=40, **AIR)),
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=40, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=40, **AIR)),
    ("tick", 1000),
], [["new"], ["new"], ["new"], ["correlate"], ["fused"]])

# 8. Rejections change no state.
scenario("08-rejections", "gnn", [
    ("ingest", {"track.source_id": "radar-1", "uid": "T1", "time_ms": 0, "lat": 1.0}),
    ("ingest", {"uid": "T1", "time_ms": 0, "lat": 1.0, "lon": 1.0}),
    ("ingest", rep("radar-1", "T1", 5000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 4000, 0, 0, ce=30, **AIR)),
], [["reject"], ["reject"], ["new"], ["reject"]])

# 9. Close in position but on opposite courses: the confirm stage refuses.
scenario("09-opposite-courses-refused", "gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, course=90, speed_ms=50, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 5, 0, ce=30, course=270, speed_ms=50, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 50, 0, ce=30, course=90, speed_ms=50, **AIR)),
    ("ingest", rep("adsb", "A7", 1000, -45, 0, ce=30, course=270, speed_ms=50, **AIR)),
], [["new"], ["new"], [], []])

# 10. An air track and a surface track at one spot are not grouped.
scenario("10-environment-differs", "gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("ais", "M1", 0, 5, 0, ce=30, **SEA)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
], [["new"], ["new"], []])

# 11. Window pack: priority picks the fused output's source.
scenario("11-window-priority-output", "window", [
    ("ingest", rep("ais", "M1", 0, 0, 0, ce=300, **SEA)),
    ("ingest", rep("radar-1", "S4", 0, 600, 300, ce=200, **SEA)),
    ("ingest", rep("ais", "M1", 10000, 50, 0, ce=300, **SEA)),
    ("tick", 12000),
], [["new"], ["new"], ["correlate"], ["fused"]])

# 12. Window pack: outside the window, not grouped.
scenario("12-window-outside", "window", [
    ("ingest", rep("ais", "M1", 0, 0, 0, ce=100, **SEA)),
    ("ingest", rep("radar-1", "S4", 0, 1500, 0, ce=100, **SEA)),
    ("ingest", rep("ais", "M1", 10000, 0, 0, ce=100, **SEA)),
], [["new"], ["new"], []])

# 13. Moving pair on the window pack with reported velocity; fused output carries
#     the filtered course and speed predicted forward.
mvs = dict(course=45, speed_ms=10, ce=150, **SEA)
scenario("13-window-moving-fused", "window", [
    ("ingest", rep("ais", "M1", 0, 0, 0, **mvs)),
    ("ingest", rep("radar-1", "S4", 0, 100, 0, **mvs)),
    ("ingest", rep("ais", "M1", 10000, 70.71, 70.71, **mvs)),
    ("tick", 20000),
], [["new"], ["new"], ["correlate"], ["fused"]])

# 14. A report's own stale_ms drops it before the pack's stale_ms.
scenario("14-report-stale-ms", "gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, stale_ms=5000, **AIR)),
    ("tick", 4999),
    ("tick", 5000),
], [["new"], [], ["drop"]])

# 15. Reference near the antimeridian: tracks either side of 180 correlate.
scenario("15-antimeridian", "gnn", [
    ("ingest", rep("radar-1", "T1", 0, -20, 0, ce=30, lat0=60.0, lon0=180.0, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 20, 0, ce=30, lat0=60.0, lon0=180.0, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, -20, 0, ce=30, lat0=60.0, lon0=180.0, **AIR)),
    ("tick", 1000),
], [["new"], ["new"], ["correlate"], ["fused"]])


def clean(x):
    """Write negative zero as zero."""
    if isinstance(x, float):
        return 0.0 if x == 0 else x
    if isinstance(x, list):
        return [clean(v) for v in x]
    if isinstance(x, dict):
        return {k: clean(v) for k, v in x.items()}
    return x


def main():
    ok = True
    for name, pack_name, steps, decide in SCENARIOS:
        pack = load_pack(os.path.join(ROOT, "packs", pack_name))
        eng = Engine(pack)
        out_steps = []
        for (kind, arg), want in zip(steps, decide):
            events, trace = eng.ingest(arg) if kind == "ingest" else eng.tick(arg)
            got = [e["ev"] for e in events]
            if got != want:
                print("%s step %d: events %s, decided %s" % (name, len(out_steps), got, want))
                ok = False
            out_steps.append({kind: arg, "expect": clean(events), "trace": clean(trace)})
        if len(decide) != len(steps):
            print("%s: decide has %d entries for %d steps" % (name, len(decide), len(steps)))
            ok = False
        vec = {"name": name, "pack": pack_name, "steps": out_steps, "snapshot": clean(eng.snapshot())}
        path = os.path.join(ROOT, "packs", pack_name, "vectors", name + ".json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(vec, f, indent=1)
            f.write("\n")
    if not ok:
        sys.exit(1)
    print("wrote %d vectors" % len(SCENARIOS))


if __name__ == "__main__":
    main()
