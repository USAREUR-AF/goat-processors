#!/usr/bin/env python3
"""Write the correlate conformance vectors for packs/correlate-*.

Each scenario below states its inputs and, in `decide`, the association
events it must produce. The script computes each vector with the Rust engine
(tools/consensus.py), refuses one whose events differ from `decide`, records
the full events, trace and final snapshot, and writes the vector only when
all seven engines agree with it. It also refuses a vector that places a
decision within the comparison tolerance (check_margins): a test value that
close to its limit (gate, confirm, hold, the bias residual, the filter
restart, a history total against the margin cut, a sequential-test ratio
near either bound without being on it), or two ranked assignment
or history totals that close without being equal. The specification and the decisions stated
by hand here are the reference; the numbers are computed by the Rust engine
and accepted only when all seven engines agree.

Run: python3 -I tools/make-vectors.py [--rust-only | --spec-stage]
(--rust-only skips the seven-engine run; CI uses it, as its seven engine jobs
check every engine on every vector. --spec-stage is for the first stage of a
spec round, when only the Python engine implements the new text: it computes
with the Python engine and skips the seven-engine run. Before such a round
merges, the vectors are written again without it, by the Rust engine, and
accepted only when all seven engines agree.)
"""

import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import consensus  # noqa: E402

R = 6371008.8
LAT0, LON0 = 1.0, 1.0  # notional: open ocean near 0 N 0 E


def at(east_m, north_m, lat0=LAT0, lon0=LON0):
    lat = lat0 + math.degrees(north_m / R)
    lon = lon0 + math.degrees(east_m / (R * math.cos(math.radians(lat0))))
    return round(lat, 9), round(lon, 9)


def rep(src, uid, t, e, n, **kw):
    lat, lon = at(e, n, kw.pop("lat0", LAT0), kw.pop("lon0", LON0))
    r = {"track.source_id": src, "uid": kw.pop("uid_value", uid), "time_ms": t, "lat": lat, "lon": lon}
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
scenario("01-two-sources-one-object", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, hae=3000, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 20, -10, ce=30, hae=3050, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 5, 0, ce=30, hae=3000, **AIR)),
    ("tick", 1500),
], [["new"], ["new"], ["correlate"], ["fused"]])

# 2. Two objects 10 km apart never correlate.
scenario("02-far-apart-stay-separate", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10000, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 1000, 10000, 0, ce=30, **AIR)),
    ("tick", 1500),
], [["new"], ["new"], [], [], []])

# 3. Two tracks from one source are never grouped, however close.
scenario("03-same-source-never-grouped", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T2", 0, 5, 5, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T2", 1000, 5, 5, ce=30, **AIR)),
], [["new"], ["new"], [], []])

# 4. A moving pair correlates, then one track turns away and the group dissolves
#    after two consecutive hold failures.
mv = dict(course=90, speed_ms=100, ce=30, **AIR)
scenario("04-separation-dissolves", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, **mv)),
    ("ingest", rep("adsb", "A7", 0, 10, 10, **mv)),
    ("ingest", rep("radar-1", "T1", 1000, 100, 0, **mv)),
    ("ingest", rep("adsb", "A7", 2000, 210, 10, **mv)),
    ("ingest", rep("adsb", "A7", 3000, 300, 2000, ce=30, course=0, speed_ms=100, **AIR)),
    ("ingest", rep("adsb", "A7", 4000, 300, 4000, ce=30, course=0, speed_ms=100, **AIR)),
    ("tick", 4500),
], [["new"], ["new"], ["correlate"], [], [], ["leave", "dissolve"], []])

# 5. A grouped track goes silent; at the tick past stale_ms it leaves and drops.
scenario("05-stale-member-drops", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 120000, 10, 0, ce=30, **AIR)),
    ("tick", 121001),
    ("tick", 125000),
], [["new"], ["new"], ["correlate"], [], ["leave", "dissolve", "drop"], []])

# 6. A third source joins an existing group.
scenario("06-third-source-joins", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("eo-2", "E3", 1000, -15, 5, ce=40, **AIR)),
    ("ingest", rep("eo-2", "E3", 2000, -15, 5, ce=40, **AIR)),
    ("tick", 2500),
], [["new"], ["new"], ["correlate"], ["new"], ["join"], ["fused"]])

# 7. Two candidates confirm on the same report; the nearer one is chosen.
scenario("07-nearest-candidate-wins", "correlate-gnn", [
    ("ingest", rep("adsb", "A7", 0, 60, 0, ce=40, **AIR)),
    ("ingest", rep("eo-2", "E3", 0, 5, 0, ce=40, **AIR)),
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=40, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=40, **AIR)),
    ("tick", 1000),
], [["new"], ["new"], ["new"], ["correlate"], ["fused"]])

# 8. Rejections change no state.
scenario("08-rejections", "correlate-gnn", [
    ("ingest", {"track.source_id": "radar-1", "uid": "T1", "time_ms": 0, "lat": 1.0}),
    ("ingest", {"uid": "T1", "time_ms": 0, "lat": 1.0, "lon": 1.0}),
    ("ingest", rep("radar-1", "T1", 5000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 4000, 0, 0, ce=30, **AIR)),
], [["reject"], ["reject"], ["new"], ["reject"]])

# 9. Close in position but on opposite courses: the confirm stage refuses.
scenario("09-opposite-courses-refused", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, course=90, speed_ms=50, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 5, 0, ce=30, course=270, speed_ms=50, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 50, 0, ce=30, course=90, speed_ms=50, **AIR)),
    ("ingest", rep("adsb", "A7", 1000, -45, 0, ce=30, course=270, speed_ms=50, **AIR)),
], [["new"], ["new"], [], []])

# 10. An air track and a surface track at one spot are not grouped.
scenario("10-environment-differs", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("ais", "M1", 0, 5, 0, ce=30, **SEA)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
], [["new"], ["new"], []])

# 14. A report's own stale_ms drops it before the pack's stale_ms.
scenario("14-report-stale-ms", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, stale_ms=5000, **AIR)),
    ("tick", 4999),
    ("tick", 5000),
], [["new"], [], ["drop"]])

# 15. Reference near the antimeridian: tracks either side of 180 correlate.
scenario("15-antimeridian", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, -20, 0, ce=30, lat0=60.0, lon0=180.0, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 20, 0, ce=30, lat0=60.0, lon0=180.0, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, -20, 0, ce=30, lat0=60.0, lon0=180.0, **AIR)),
    ("tick", 1000),
], [["new"], ["new"], ["correlate"], ["fused"]])


# 16. A member with one hold failure is left alone when its group dissolves:
#     its count goes back to 0 (snapshot).
scenario("16-dissolve-resets-remaining-member", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 2000, 3000, 0, ce=30, **AIR)),
    ("tick", 121001),
], [["new"], ["new"], ["correlate"], [], ["leave", "dissolve", "drop"]])

# 17. In a three-member group the hold stops at the first member that passes.
scenario("17-hold-stops-at-first-passing-member", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("eo-2", "E3", 1000, -15, 5, ce=40, **AIR)),
    ("ingest", rep("eo-2", "E3", 2000, -15, 5, ce=40, **AIR)),
    ("ingest", rep("eo-2", "E3", 3000, -15, 5, ce=40, **AIR)),
], [["new"], ["new"], ["correlate"], ["new"], ["join"], []])

# 19. Course without speed: course and speed tests are skipped; a later report
#     without course makes it absent again.
scenario("19-course-without-speed-is-skipped", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, course=10, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, course=200, speed_ms=80, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
], [["new"], ["new"], ["correlate"]])

# 20. Distance pack: same source allowed, zero speeds, latest-report output.
scenario("20-distance-same-source-zero-speed-latest", "correlate-distance", [
    ("ingest", rep("net-a", "1", 0, 0, 0, course=0, speed_ms=0)),
    ("ingest", rep("net-a", "2", 500, 50, 0, course=0, speed_ms=0)),
    ("ingest", rep("net-a", "1", 1000, 0, 0, course=0, speed_ms=0)),
    ("tick", 1500),
    ("ingest", rep("net-a", "2", 2000, 1000, 0, course=0, speed_ms=0)),
    ("tick", 2500),
], [["new"], ["new", "correlate"], [], ["fused"], ["leave", "dissolve"], []])

# 21. Wrong types: a required key of the wrong type rejects; an optional one is
#     treated as absent.
scenario("21-wrong-types", "correlate-gnn", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, uid_value=7)),
    ("ingest", {"track.source_id": "radar-1", "uid": "T1", "time_ms": 0, "lat": "1.0", "lon": 1.0}),
    ("ingest", {"track.source_id": "radar-1", "uid": "T1", "time_ms": 1.5, "lat": 1.0, "lon": 1.0}),
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce="30", hae=None, course="north", type=5)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30)),
], [["reject"], ["reject"], ["reject"], ["new"], ["new"]])


# 22. Edge values: an integral float is not an integer; same compares numbers by
#     value; a short type has no environment; a ce of 0 falls back to the default.
scenario("22-edge-values", "correlate-gnn", [
    ("ingest", {"track.source_id": "radar-1", "uid": "T1", "time_ms": 1000.0, "lat": 1.0, "lon": 1.0}),
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=0, type="a-f", **{"track.simulated": 1})),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, type="a-h", **{"track.simulated": 1.0})),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=-5, type="a-f", stale_ms=9000.0, **{"track.simulated": 1})),
    ("tick", 9500),
], [["reject"], ["new"], ["new"], ["correlate"], ["fused"]])


# --- correlate-assign (spec/correlate-assign.md) ---

# 23. Two sources, one object: one system track.
scenario("23-assign-two-sources-one-object", "correlate-assign", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, hae=3000, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, hae=3050, **AIR)),
    ("tick", 500),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, hae=3000, **AIR)),
    ("tick", 1500),
], [["new"], ["new"], ["start", "join", "system"], [], ["system"]])

# 24. Two objects 10 km apart, and two tracks of one source side by side:
#     three system tracks.
scenario("24-assign-separate-objects-and-same-source", "correlate-assign", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T2", 0, 10, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10000, 0, ce=30, **AIR)),
    ("tick", 500),
], [["new"], ["new"], ["new"], ["start", "start", "start", "system", "system", "system"]])

# 25. The least total cost, not nearest first: radar-2 R1 is nearest to s1, but
#     giving s1 to R2 and s2 to R1 costs less in total (3.50 against 3.69).
scenario("25-assign-least-total-not-nearest-first", "correlate-assign", [
    ("ingest", rep("adsb", "A1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A2", 0, -17.6, 0, ce=30, **AIR)),
    ("ingest", rep("radar-2", "R1", 0, 42.4, 0, ce=30, **AIR)),
    ("ingest", rep("radar-2", "R2", 0, 52.0, 0, ce=30, **AIR)),
    ("tick", 0),
], [["new"], ["new"], ["new"], ["new"], ["start", "start", "join", "join", "system", "system"]])

# 26. A moving pair is one system track until one turns away; it then leaves
#     and starts its own.
mva = dict(course=90, speed_ms=100, ce=30, **AIR)
scenario("26-assign-separation-starts-new", "correlate-assign", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, **mva)),
    ("ingest", rep("adsb", "A7", 0, 10, 10, **mva)),
    ("tick", 500),
    ("ingest", rep("radar-1", "T1", 1000, 100, 0, **mva)),
    ("ingest", rep("adsb", "A7", 1000, 110, 10, **mva)),
    ("tick", 1500),
    ("ingest", rep("adsb", "A7", 3000, 300, 2000, ce=30, course=0, speed_ms=100, **AIR)),
    ("tick", 3500),
], [["new"], ["new"], ["start", "join", "system"], [], [], ["system"], [], ["leave", "start", "system", "system"]])

# 27. Members go stale one by one; the system track ends with the last.
scenario("27-assign-stale-members", "correlate-assign", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, **AIR)),
    ("tick", 500),
    ("ingest", rep("radar-1", "T1", 60000, 0, 0, ce=30, **AIR)),
    ("tick", 120001),
    ("tick", 180001),
], [["new"], ["new"], ["start", "join", "system"], [], ["leave", "drop", "system"], ["leave", "end", "drop"]])

# 28. An air and a surface track at one spot fail the gate: two system tracks.
scenario("28-assign-environment-gate", "correlate-assign", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("ais", "M1", 0, 5, 0, ce=30, **SEA)),
    ("tick", 500),
], [["new"], ["new"], ["start", "start", "system", "system"]])

# 29. keep_bonus: a track a little closer to another system track than to its
#     own stays where it is.
scenario("29-assign-keep-bonus-holds", "correlate-assign", [
    ("ingest", rep("adsb", "A1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("eo-2", "E1", 0, 200, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 0, 60, 0, ce=30, **AIR)),
    ("tick", 0),
    ("ingest", rep("radar-1", "T1", 0, 146, 0, ce=30, **AIR)),
    ("tick", 0),
], [["new"], ["new"], ["new"], ["start", "start", "join", "system", "system"], [], ["system", "system"]])

# 30. A track that reported no new report since the last tick is not re-decided.
scenario("30-assign-only-reported-tracks-decide", "correlate-assign", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("tick", 500),
    ("ingest", rep("adsb", "A7", 1000, 10, 0, ce=30, **AIR)),
    ("tick", 1500),
    ("tick", 2500),
], [["new"], ["start", "system"], ["new"], ["join", "system"], ["system"]])


# 31. A failed gate test against one of a system track's others ends that
#     entry: no test runs against its later others (trace).
scenario("31-assign-gate-failure-ends-entry", "correlate-assign", [
    ("ingest", rep("adsb", "A1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("eo-2", "E1", 0, 10, 0, ce=30, **AIR)),
    ("tick", 0),
    ("ingest", rep("radar-1", "T1", 0, 5, 0, ce=30, **SEA)),
    ("tick", 0),
], [["new"], ["new"], ["start", "join", "system"], ["new"], ["start", "system", "system"]])

# 32. The snapshot lists the entities that reported since the previous tick.
scenario("32-assign-snapshot-holds-reported", "correlate-assign", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("tick", 500),
    ("ingest", rep("adsb", "A7", 1000, 10, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
], [["new"], ["start", "system"], ["new"], []])


# --- two-model filter (spec/correlate.md, Two-model filter) ---

def turn_truth(t_s):
    """East at 200 m/s for 6 s, then a level left turn at 6 deg/s for 30 s."""
    v, rate, t0 = 200.0, math.radians(6.0), 6.0
    if t_s <= t0:
        return v * t_s, 0.0
    a = rate * (t_s - t0)
    rr = v / rate
    return v * t0 + rr * math.sin(a), rr * (1 - math.cos(a))


def turn_reports(rounds):
    """radar-1 every 4 s from 0, adsb every 4 s from 2 s, 10 m east of radar."""
    out = []
    for i in range(rounds):
        for src, uid, t, off in (("radar-1", "T1", 4000 * i, 0.0), ("adsb", "A7", 4000 * i + 2000, 10.0)):
            e, n = turn_truth(t / 1000.0)
            out.append(("ingest", rep(src, uid, t, round(e + off, 1), round(n, 1), ce=30, **AIR)))
    return out


TURN = turn_reports(6) + [turn_reports(7)[12], ("tick", 25000)]
TURN_DECIDED = [["new"], ["new"], ["correlate"]] + [[]] * 8

# 33. One constant-velocity model: the turning target leaves the hold region of
#     its partner on two reports in a row and the group dissolves.
scenario("33-turn-one-model-dissolves", "correlate-gnn", TURN,
         TURN_DECIDED + [["leave", "dissolve"], [], []])

# 34. The same reports with the two-model filter: the maneuver model takes
#     the mode probability, the prediction keeps up, the group holds.
scenario("34-turn-two-models-hold", "correlate-gnn-imm", TURN,
         TURN_DECIDED + [[], [], ["fused"]])


def turn_assign(rounds):
    out = []
    rep_steps = turn_reports(rounds)
    for i in range(rounds):
        out += rep_steps[2 * i:2 * i + 2] + [("tick", 4000 * i + 2500)]
    return out


# 35. Method assign, one model: the turn splits the system track.
scenario("35-assign-turn-one-model-splits", "correlate-assign", turn_assign(5),
         [["new"], ["new"], ["start", "join", "system"]]
         + [[], [], ["system"]] * 2
         + [[], [], ["leave", "start", "system", "system"]]
         + [[], [], ["system", "system"]])

# 36. Method assign, two models: one system track through the turn.
scenario("36-assign-turn-two-models-one-system", "correlate-assign-imm", turn_assign(5),
         [["new"], ["new"], ["start", "join", "system"]] + [[], [], ["system"]] * 4)

# 37. A straight track with reported velocity: the velocity innovations enter
#     the likelihood and the maneuver probability falls (trace, snapshot).
st = dict(course=90, speed_ms=100, ce=30, **AIR)
scenario("37-two-models-straight-goes-quiet", "correlate-gnn-imm", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, **st)),
    ("ingest", rep("radar-1", "T1", 1000, 100, 0, **st)),
    ("ingest", rep("radar-1", "T1", 2000, 200, 0, **st)),
    ("ingest", rep("radar-1", "T1", 3000, 300, 0, **st)),
], [["new"], [], [], []])

# 38. A 100 km jump: the quiet model's weight underflows to exactly 0; a second
#     report at the same time (dt = 0) finds its predicted mode probability 0
#     and keeps its own state; the next report (dt above 0) mixes it again,
#     from the maneuver model alone (snapshot).
scenario("38-two-models-underflow-and-zero-dt", "correlate-gnn-imm", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 100000, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 100000, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 2000, 100100, 0, ce=30, **AIR)),
    ("tick", 2000),
], [["new"], [], [], [], []])


# --- multi-frame window (spec/correlate-assign.md, Window) ---

def crossing(rounds=8, swap_round=5, sep=100.0, swap_ce=15):
    """Two aircraft cross 100 m apart: O1 east at 100 m/s, O2 west at 90 m/s.
    radar-1 reports both every 2 s; adsb every 4 s. At swap_round the radar's
    two plots are each other's, with ce 15. Radar plots sit a fixed few meters
    off the aircraft (R1 +12 east -8 north, R2 -9 east +14 north)."""
    out = []
    for i in range(rounds):
        t = 2000 * i
        ts = t / 1000.0
        p1 = (-1000 + 100 * ts, 0.0)
        p2 = (900 - 90 * ts, sep)
        if i % 2 == 0:
            for uid, p in (("A1", p1), ("A2", p2)):
                out.append(("ingest", rep("adsb", uid, t, round(p[0], 1), round(p[1], 1), ce=30, **AIR)))
        for uid, p, q in (("R1", p1, p2), ("R2", p2, p1)):
            ce = 30
            if i == swap_round:
                p, ce = q, swap_ce
            p = (p[0] + 12, p[1] - 8) if uid == "R1" else (p[0] - 9, p[1] + 14)
            out.append(("ingest", rep("radar-1", uid, t, round(p[0], 1), round(p[1], 1), ce=ce, **AIR)))
        out.append(("tick", t + 500))
    return out


def per_round(steps, decided_ticks):
    """A track's first report decides `new`, later reports nothing; each tick
    decides the given events."""
    out, seen = [], set()
    ticks = iter(decided_ticks)
    for kind, arg in steps:
        if kind == "tick":
            out.append(next(ticks))
        else:
            key = (arg["track.source_id"], arg["uid"])
            out.append([] if key in seen else ["new"])
            seen.add(key)
    return out


S2 = ["system", "system"]
# 39. One frame: the swapped radar plots move R1 to s2 and R2 to s1; at the
#     next adsb reports the adsb tracks follow them, and s1 now holds the other
#     aircraft.
scenario("39-assign-crossing-one-frame-swaps", "correlate-assign", crossing(), per_round(crossing(), [
    ["start", "start", "join", "join"] + S2, S2, S2, S2, S2,
    ["leave", "join", "leave", "join"] + S2,
    ["leave", "join", "leave", "join"] + S2,
    S2]))
P2 = ["provisional", "provisional"]
# 40. Window 2: the swap is the best history at the crossing tick, but the next
#     reports make the history without it cheaper; the swap is never committed.
scenario("40-assign-crossing-window-resolves", "correlate-assign-window", crossing(), per_round(crossing(), [
    P2, ["start", "start", "join", "join"] + S2 + P2] + [S2 + P2] * 6))

# 41. Window 2: a tick is committed one tick later; provisional events give
#     the best history's memberships meanwhile (snapshot holds the histories).
scenario("41-assign-window-commits-one-tick-late", "correlate-assign-window", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("tick", 500),
    ("ingest", rep("adsb", "A7", 1000, 10, 0, ce=30, **AIR)),
    ("tick", 1500),
    ("tick", 2500),
    ("ingest", rep("adsb", "A7", 3000, 10, 0, ce=30, **AIR)),
], [["new"], ["provisional"], ["new"], ["start", "system", "provisional"],
    ["join", "system", "provisional"], []])

TIE = [
    ("ingest", rep("adsb", "A1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A2", 0, 40, 0, ce=30, **AIR)),
    ("tick", 0),
    ("ingest", rep("radar-1", "R1", 0, 15, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "R2", 0, 15, 0, ce=30, **AIR)),
    ("tick", 0),
]
# 42. Two radar tracks with identical reports: both ways of joining them to s1
#     and s2 have the same total; the smaller choice vector wins (R1 to s1).
scenario("42-assign-equal-totals-smaller-choice-wins", "correlate-assign", TIE,
         [["new"], ["new"], ["start", "start", "system", "system"], ["new"], ["new"],
          ["join", "join", "system", "system"]])

# 43. Window 2: the equal-total assignments are ranked 0 and 1 and kept in that
#     order; the next reports separate them and the rank-0 history commits.
scenario("43-assign-window-equal-totals-keep-rank-order", "correlate-assign-window", TIE + [
    ("ingest", rep("radar-1", "R1", 1000, 3, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "R2", 1000, 45, 0, ce=30, **AIR)),
    ("tick", 1000),
], [["new"], ["new"], ["provisional", "provisional"], ["new"], ["new"],
    ["start", "start", "system", "system", "provisional", "provisional"],
    [], [], ["join", "join", "system", "system", "provisional", "provisional"]])

# 44. Window 2: a stale entity is dropped from every history at once and
#     retires; its drop is committed one tick later; a report for it meanwhile
#     is rejected; the retiring member, 60 m off, still pulls the committed
#     estimate; after the drop the key is new again.
scenario("44-assign-window-stale-retires", "correlate-assign-window", [
    ("ingest", rep("radar-1", "T1", 0, 70, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, **AIR)),
    ("tick", 500),
    ("tick", 1000),
    ("ingest", rep("adsb", "A7", 100000, 10, 0, ce=30, **AIR)),
    ("tick", 121000),
    ("ingest", rep("radar-1", "T1", 121500, 70, 0, ce=30, **AIR)),
    ("tick", 122000),
    ("ingest", rep("radar-1", "T1", 122500, 70, 0, ce=30, **AIR)),
], [["new"], ["new"], ["provisional"], ["start", "join", "system", "provisional"], [],
    ["system", "provisional"], ["reject"], ["leave", "drop", "system", "provisional"], ["new"]])


# --- sensor bias (spec/correlate-assign.md, Sensor bias) ---

def offset_pair(rounds, dt=1000, radar_east=400.0, **kw):
    """adsb A7 at the origin and radar-1 T1 at radar_east, both stationary,
    each round at t = dt * i, then a tick 500 ms later."""
    out = []
    for i in range(rounds):
        t = dt * i
        out.append(("ingest", rep("adsb", "A7", t, 0, 0, ce=30, **AIR)))
        out.append(("ingest", rep("radar-1", "T1", t, radar_east, 0, ce=30, **AIR)))
        out.append(("tick", t + 500))
    return out


OFFSET = offset_pair(3) + [("tick", 3500)]
# 45. A radar 400 m east of the adsb: with no estimate yet the prior (300 m per
#     axis) lets T1 join A7's system track; each tick the pair refines the
#     adsb|radar-1 offset toward +400 m east (trace, snapshot). The last tick
#     has no report, so no pair updates.
scenario("45-assign-bias-offset-pair-joins", "correlate-assign-bias", OFFSET,
         per_round(OFFSET, [["start", "join", "system"], ["system"], ["system"], ["system"]]))

# 46. The same reports without bias estimation: T1 is 400 m from A7 with no
#     added uncertainty and starts its own system track.
scenario("46-assign-offset-pair-splits-without-bias", "correlate-assign-imm", OFFSET,
         per_round(OFFSET, [["start", "start", "system", "system"]] + [["system", "system"]] * 3))

# 47. The residual is measured at the tick: two tracks at one spot join, but
#     their reported velocities (300 m/s east and north) carry them 4.2 km apart
#     by the tick 10 s later; the pair is refused and no estimate is stored.
scenario("47-assign-bias-residual-refused", "correlate-assign-bias", [
    ("ingest", rep("adsb", "A7", 0, 0, 0, ce=30, course=90, speed_ms=300, **AIR)),
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, course=0, speed_ms=300, **AIR)),
    ("tick", 10000),
], [["new"], ["new"], ["start", "join", "system"]])

THREE = []
for i in range(2):
    t = 1000 * i
    THREE += [("ingest", rep("adsb", "A7", t, 0, 0, ce=30, **AIR)),
              ("ingest", rep("eo-2", "E3", t, -20, 10, ce=40, **AIR)),
              ("ingest", rep("radar-1", "T1", t, 400, 0, ce=30, **AIR)),
              ("tick", t + 500)]
# 48. Three sources: each pair of sources has its own offset, keyed by the two
#     source names in order; eo-2|radar-1 is the radar's offset seen from eo-2.
scenario("48-assign-bias-three-sources", "correlate-assign-bias", THREE,
         per_round(THREE, [["start", "join", "join", "system"], ["system"]]))


# --- filter restart, margin (correlate.md, Track estimate; correlate-assign.md, Window) ---

JUMP = []
for i in range(4):
    t = 1000 * i
    JUMP += [("ingest", rep("adsb", "A1", t, 0, 0, ce=30, **AIR)),
             ("ingest", rep("adsb", "A2", t, 3000, 0, ce=30, **AIR)),
             ("ingest", rep("radar-1", "R1", t, 3000 if i == 2 else 15, 0, ce=30, **AIR)),
             ("tick", t + 500)]
JUMP_P = ["system", "system", "provisional", "provisional"]
# 49. R1 follows A1, then at 2 s reports at A2's place, 3 km off (a sensor's
#     track number now on another object): the innovation is far above the
#     restart gate and R1's filter starts again from that report. At the tick
#     R1 first leaves its system track (reason restart), then the adsb tracks
#     keep theirs and R1 joins A2's, in the best history at once (reported by
#     `system`); both are committed one tick later. At 3 s R1 is back at A1
#     and restarts again.
scenario("49-full-restart-and-move", "correlate-assign-full", JUMP, per_round(JUMP, [
    JUMP_P, ["start", "start", "join"] + JUMP_P, JUMP_P, ["leave", "join"] + JUMP_P]))

# 50. Window 2 with a margin: the alone candidate is more than 0.5 behind the
#     best and is not kept (trace `limit` is the cut); `system` reports the
#     best history's latest membership, so A7 shows in T1's system track at
#     the tick it reported, one tick before its join is committed.
scenario("50-full-margin-reports-best", "correlate-assign-full", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("tick", 500),
    ("ingest", rep("adsb", "A7", 1000, 10, 0, ce=30, **AIR)),
    ("tick", 1500),
    ("tick", 2500),
], [["new"], ["system", "provisional"], ["new"], ["start", "system", "provisional"],
    ["join", "system", "provisional"]])

# 51. Equal totals are within the margin, so both histories are kept in rank
#     order; the next reports separate them and the rank-0 history commits.
scenario("51-full-equal-totals-within-margin", "correlate-assign-full", TIE + [
    ("ingest", rep("radar-1", "R1", 1000, 3, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "R2", 1000, 45, 0, ce=30, **AIR)),
    ("tick", 1000),
], [["new"], ["new"], JUMP_P, ["new"], ["new"],
    ["start", "start"] + JUMP_P, [], [], ["join", "join"] + JUMP_P])


# 52. Method confirm, one model, with restart: the pair correlates; then the
#     radar's report lands 3 km off, far above the restart gate. Its filter
#     starts again from that report (no `new`); it keeps its group, which then
#     fails the hold test on two reports in a row and dissolves.
scenario("52-confirm-restart-keeps-group", "correlate-gnn-restart", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 2000, 3000, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 3000, 3000, 0, ce=30, **AIR)),
    ("tick", 3500),
], [["new"], ["new"], ["correlate"], [], ["leave", "dissolve"], []])

# 53. Restart and staleness at one tick: T1 restarts at 2 s, then neither it
#     nor A7 reports for 20 s; A7 reports again at 22 s. At the tick T1 is
#     stale, so it leaves for staleness (not restart) and retires; the bias
#     update skips the retiring T1, so the adsb|radar-1 pair gets no record.
scenario("53-full-restart-then-stale", "correlate-assign-full", [
    ("ingest", rep("adsb", "A7", 0, 0, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 0, 15, 0, ce=30, **AIR)),
    ("tick", 500),
    ("ingest", rep("adsb", "A7", 1000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, 15, 0, ce=30, **AIR)),
    ("tick", 1500),
    ("ingest", rep("adsb", "A7", 2000, 0, 0, ce=30, **AIR)),
    ("ingest", rep("radar-1", "T1", 2000, 3000, 0, ce=30, **AIR)),
    ("ingest", rep("adsb", "A7", 22000, 0, 0, ce=30, **AIR)),
    ("tick", 22500),
    ("tick", 23500),
], [["new"], ["new"], ["system", "provisional"], [], [], ["start", "join", "system", "provisional"],
    [], [], [], ["system", "provisional"], ["leave", "drop", "system", "provisional"]])


# --- time quality (correlate.md, Reports, Time quality; correlate-assign.md, Time offset) ---

E200 = dict(course=90, speed_ms=200, ce=30, **AIR)
TIMED = [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, **E200)),
    ("ingest", rep("adsb", "A7", 0, 200, 0, **E200)),
    ("ingest", rep("radar-1", "T1", 1000, 200, 0, **E200)),
    ("ingest", rep("adsb", "A7", 1000, 400, 0, **E200)),
    ("tick", 1500),
    ("ingest", rep("radar-1", "T1", 2000, 400, 0, time_error_ms=0, time_state="unsynced", **E200)),
    ("tick", 2500),
    ("ingest", rep("radar-1", "T1", 3000, 600, 0, time_error_ms=-5, **E200)),
    ("ingest", rep("radar-1", "T1", 4000, 800, 0, time_error_ms=True, **E200)),
]
# 54. radar-1 trails the adsb by 200 m along a 200 m/s track. The pack gives
#     radar-1 a time error of 500 ms, so each radar-1 report adds
#     (200 m/s x 0.5 s)² to its east variance (trace `time`): the gate passes
#     on two reports in a row and the pair correlates. The report at 2 s says
#     time_error_ms 0, which overrides the pack (no `time` record), and an
#     unknown time_state, which is ignored: the hold test fails once, which
#     does not yet dissolve the group. At 3 s and 4 s, time_error_ms -5 and
#     true are not numbers 0 or above, so they count as absent and the pack's
#     500 ms applies again (trace `time`).
scenario("54-confirm-time-error-widens-gate", "correlate-gnn-time", TIMED,
         [["new"], ["new"], ["correlate"], [], ["fused"], [], ["fused"], [], []])

# 55. The same reports with no time quality: 200 m against 30 m errors fails
#     the gate every time and the pair never correlates.
scenario("55-confirm-exact-time-stays-apart", "correlate-gnn", TIMED,
         [["new"], ["new"], [], [], [], [], [], [], []])

CLOCK = []
for i in range(4):
    t = 1000 * i
    ts = t / 1000.0
    CLOCK += [("ingest", rep("adsb", "A1", t, 200 * ts, 0, course=90, speed_ms=200, ce=30,
                             time_error_ms=20, **AIR)),
              ("ingest", rep("adsb", "A2", t, 0, 5000 + 150 * ts, course=0, speed_ms=150, ce=30, **AIR)),
              ("ingest", rep("radar-1", "R1", t, 200 * (ts - 1), 0, course=90, speed_ms=200, ce=30, **AIR)),
              ("ingest", rep("radar-1", "R2", t, 0, 5000 + 150 * (ts - 1), course=0, speed_ms=150, ce=30,
                             **AIR)),
              ("tick", t + 500)]
CP = ["system", "system", "provisional", "provisional"]
# 56. radar-1's clock is 1 s ahead: each of its reports gives where the object
#     was 1 s before its time. Two objects on different headings: the offsets
#     (200 m east on A1's track, 150 m north on A2's) fit one clock offset, not
#     one position offset. Each radar track joins its adsb track under the
#     prior; each tick the adsb|radar-1 fit moves the time offset toward
#     +1000 ms and the position offset stays near 0 (trace, snapshot). A1's
#     reports carry time_error_ms 20 (trace `time`).
scenario("56-assign-time-offset-fit", "correlate-assign-time", CLOCK, per_round(CLOCK, [
    CP, ["start", "start", "join", "join"] + CP, CP, CP]))


# --- retained rules on correlate-gnn-priority (vectors 57-58) ---

# 57. Priority picks the fused output's member: radar-1 (priority 1) over ais
#     (priority 50), although ais reported later.
scenario("57-priority-output", "correlate-gnn-priority", [
    ("ingest", rep("ais", "M1", 0, 0, 0, ce=100, **SEA)),
    ("ingest", rep("radar-1", "S4", 0, 60, 30, ce=100, **SEA)),
    ("ingest", rep("ais", "M1", 10000, 20, 0, ce=100, **SEA)),
    ("tick", 12000),
], [["new"], ["new"], ["correlate"], ["fused"]])

# 58. A hold that fails its first test runs no second test (trace); two hold
#     failures in a row are needed before the member leaves.
scenario("58-hold-stops-at-first-failure", "correlate-gnn-priority", [
    ("ingest", rep("ais", "M1", 0, 0, 0, ce=100, **SEA)),
    ("ingest", rep("radar-1", "S4", 0, 100, 0, ce=100, **SEA)),
    ("ingest", rep("ais", "M1", 10000, 0, 0, ce=100, **SEA)),
    ("ingest", rep("radar-1", "S4", 20000, 5000, 0, ce=100, **SEA)),
    ("ingest", rep("radar-1", "S4", 30000, 9000, 0, ce=100, **SEA)),
], [["new"], ["new"], ["correlate"], [], ["leave", "dissolve"]])


# --- correlate 1.0 options: sequential test, stale_rate, state test, fused output ---

def sprt_pair(offsets):
    """radar-1 T1 and adsb A7 10 m apart at 0 and 1 s; then adsb reports at
    2 s, 3 s, ... moved east by each offset."""
    out = [("ingest", rep("radar-1", "T1", 0, 0, 0, ce=30, **AIR)),
           ("ingest", rep("adsb", "A7", 0, 10, 0, ce=30, **AIR)),
           ("ingest", rep("radar-1", "T1", 1000, 0, 0, ce=30, **AIR)),
           ("ingest", rep("adsb", "A7", 1000, 10, 0, ce=30, **AIR))]
    for i, off in enumerate(offsets):
        out.append(("ingest", rep("adsb", "A7", 2000 + 1000 * i, 10 + off, 0, ce=30, **AIR)))
    return out + [("tick", 2000 + 1000 * len(offsets))]

# 59. Sequential test: A7's first report against T1 already carries more
#     evidence than ln((1 - 0.01) / 0.01) = 4.6 needs, so the pair is
#     confirmed and correlates at once (the ratio is clamped at 4.6); the
#     fused output weighs both members (primary null).
scenario("59-sprt-confirms-on-evidence", "correlate-sprt", sprt_pair([0]),
         [["new"], ["new", "correlate"], [], [], [], ["fused"]])

# 60. One report 500 m off: the ratio falls from 4.6 to about 1.3 but stays
#     above ln(0.01 / 0.99) = -4.6, so the pair holds; the next report fits
#     again and the ratio climbs back to 4.6.
scenario("60-sprt-one-noisy-report-holds", "correlate-sprt", sprt_pair([500, 0]),
         [["new"], ["new", "correlate"], [], [], [], [], ["fused"]])

# 61. One report 700 m off carries evidence for "different objects" worth more
#     than the whole interval: the link pair falls to -4.6, A7 leaves (reason
#     release), the group dissolves and the pair is removed.
scenario("61-sprt-release", "correlate-sprt", sprt_pair([700]),
         [["new"], ["new", "correlate"], [], [], ["leave", "dissolve"], []])

RATE = [("ingest", rep("radar-1", "T1", t, 0, 0, ce=30, **AIR)) for t in (0, 1000, 3000, 6000, 10000)] + [
    ("ingest", rep("adsb", "A7", t, 5000, 0, ce=30, **AIR)) for t in (0, 200, 400)] + [
    ("tick", 5400), ("tick", 5401), ("tick", 20000), ("tick", 20001)]
# 62. stale_rate: radar-1's intervals are 1, 2, 3 and 4 s; their lower median
#     is 2 s (the upper would be 3 s), so T1 is stale 5 * 2 = 10 s after its
#     last report: not at 20 s, at 20.001 s. adsb's intervals are 0.2 s, so
#     5 * 0.2 = 1 s, raised to the 5 s floor: A7 (last at 0.4 s) is not stale
#     at 5.4 s and is at 5.401 s (snapshot: intervals).
scenario("62-stale-rate-per-source", "correlate-sprt", RATE,
         [["new"], [], [], [], [], ["new"], [], [], [], ["drop"], [], ["drop"]])

ST = dict(ce=30, **AIR)
# 63. The `state` test: T1 and A7 at one spot, but flying east and west at
#     100 m/s, fail the 4-dof gate on velocity; E3 at the same spot with no
#     velocity (so a large velocity variance) passes against both: against
#     T1 on 5 dof (both report hae, 50 m apart), against A7 on 4. On its
#     second report both counts reach 2; the rank takes the smaller position
#     d², equal here, so key order picks A7.
scenario("63-state-test-velocity-and-height", "correlate-gnn-state", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, course=90, speed_ms=100, hae=3000, **ST)),
    ("ingest", rep("adsb", "A7", 0, 0, 0, course=270, speed_ms=100, **ST)),
    ("ingest", rep("eo-2", "E3", 0, 0, 0, hae=3050, **ST)),
    ("ingest", rep("eo-2", "E3", 0, 0, 0, hae=3050, **ST)),
    ("tick", 0),
], [["new"], ["new"], ["new"], ["correlate"], ["fused"]])


NEAR = 1e-6


def near(a, b):
    return a != b and abs(a - b) <= NEAR * max(1.0, abs(b))


def check_margins(name, step_no, trace):
    """Refuse a vector that places a decision within the comparison tolerance:
    a test value near its limit, or two ranked totals near but not equal."""
    bad = []
    for r in trace:
        tested = r["stage"] in ("gate", "confirm", "hold", "bias", "history") \
            or (r["stage"] == "filter" and r["test"] == "restart")
        if tested and r["test"] not in ("count", "commit") \
                and isinstance(r["value"], float) and isinstance(r["limit"], float):
            if abs(r["value"] - r["limit"]) <= NEAR * max(1.0, abs(r["limit"])):
                bad.append("test %s value %r at limit %r" % (r["test"], r["value"], r["limit"]))
    for r in trace:
        if r["stage"] == "sprt":
            for bound in (r["limit"], r["lower"]):
                if near(r["value"], bound):
                    bad.append("sprt ratio %r near its bound %r" % (r["value"], bound))
    totals = [r["value"] for r in trace if r["stage"] == "history" and r["test"] == "total"]
    for a, b in zip(totals, totals[1:]):
        if near(a, b):
            bad.append("history totals %r and %r" % (a, b))
    blocks, order = {}, []
    for r in trace:
        if r["stage"] != "assign":
            continue
        h = r.get("h", 0)
        if r["test"] == "cost":
            if h not in blocks:
                blocks[h] = []
                order.append(h)
            blocks[h].append(r)
        elif r["test"] == "choice" and blocks.get(h):
            bad += _rank_margin(blocks.pop(h))
    for b in bad:
        print("%s step %d: decision within tolerance: %s" % (name, step_no, b))
    return not bad


def _rank_margin(recs):
    """The four best assignments of one cost block, by enumeration: each row
    takes a distinct column or its own `alone` column; an assignment using a
    missing or null entry is not possible. Report two consecutive totals
    near but not equal."""
    rows, cols = [], []
    for r in recs:
        if r["a"] not in rows:
            rows.append(r["a"])
        if r["b"] != "alone" and r["b"] not in cols:
            cols.append(r["b"])
    cost = {(r["a"], r["b"]): (math.inf if r["value"] is None else r["value"]) for r in recs}
    totals = []

    def walk(i, used, total):
        if i == len(rows):
            if total < math.inf:
                totals.append(total)
            return
        for b in cols + ["alone"]:
            if b == "alone" or b not in used:
                walk(i + 1, used | {b}, total + cost.get((rows[i], b), math.inf))
    walk(0, frozenset(), 0.0)
    best = sorted(totals)[:4]
    return ["assignment totals %r and %r" % (a, b) for a, b in zip(best, best[1:]) if near(a, b)]


def main():
    ok = True
    candidates = {}
    spec_stage = "--spec-stage" in sys.argv[1:]
    for name, pack_name, steps, decide in SCENARIOS:
        results, snapshot = consensus.compute(pack_name, steps, "python" if spec_stage else "rust")
        good = len(decide) == len(steps)
        if not good:
            print("%s: decide has %d entries for %d steps" % (name, len(decide), len(steps)))
        for i, ((events, trace), want) in enumerate(zip(results, decide)):
            got = [e["ev"] for e in events]
            good = check_margins(name, i, trace) and good
            if got != want:
                print("%s step %d: events %s, decided %s" % (name, i, got, want))
                good = False
        ok = ok and good
        if good:
            candidates[name] = {"name": name, "pack": pack_name,
                                "steps": consensus.vector_steps(steps, results), "snapshot": snapshot}
    agreed = consensus.accept(candidates, not ({"--rust-only", "--spec-stage"} & set(sys.argv[1:])))
    ok = ok and len(agreed) == len(candidates)
    for name, vec in candidates.items():
        if name not in agreed:
            continue
        consensus.write_vector(os.path.join(ROOT, "packs", vec["pack"], "vectors", name + ".json"), vec)
    if not ok:
        sys.exit(1)
    print("wrote %d vectors" % len(agreed))


if __name__ == "__main__":
    main()
