#!/usr/bin/env python3
"""Write the fuse conformance vectors for packs/fuse-* and spec/fuse-load-vectors/.

Each scenario below states its inputs and, in `decide`, the events each step
must produce. An event is decided by its name, or by a map whose every key
must match the event (maps match recursively, on the keys they name). A
scenario may also state numbers in `claims`: (step, path, value) triples that
must hold within 1e-6 * max(1, abs(value)). The script runs the Python engine, refuses to write a
vector that disagrees with the decisions or the claims, and records the full
events, trace and final snapshot as the vector. The decisions and the claimed
numbers are stated by hand here; the other numbers come from the engine and
are checked by the other six engines.

Run: python3 -I tools/make-fuse-vectors.py
"""

import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "engines", "python", "src"))
from goat_fuse import Engine, PackError, load_pack, parse_pack  # noqa: E402

R = 6371008.8
LAT0, LON0 = 1.0, 1.0  # notional: open ocean near 0 N 0 E


def at(east_m, north_m):
    lat = LAT0 + math.degrees(north_m / R)
    lon = LON0 + math.degrees(east_m / (R * math.cos(math.radians(LAT0))))
    return round(lat, 9), round(lon, 9)


def rep(src, uid, t, e, n, group=None, **kw):
    lat, lon = at(e, n)
    r = {"track.source_id": src, "uid": uid, "time_ms": t, "lat": lat, "lon": lon}
    if group is not None:
        r["fuse.group"] = group
    r.update({k.replace("__", "."): v for k, v in kw.items()})
    return r


SCENARIOS = []


def scenario(name, pack, steps, decide, claims=()):
    SCENARIOS.append((name, pack, steps, decide, claims))


def F(group, frm=None, **kw):
    d = {"ev": "fused", "group": group, "from": frm}
    d.update(kw)
    return d


def A(**attrs):
    """attributes={key: from member}; a key mapped to None must be absent."""
    return {k.replace("__", "."): ({"from": v} if v is not None else None) for k, v in attrs.items()}


# --- fuse-independent: inverse variance, attributes by source priority ---

# 1. Two sources, one group: inverse variance gives one estimate with a smaller
#    error than either member; attributes come from adsb, the first source.
scenario("01-two-members-one-group", "fuse-independent", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, "s1", ce=30, type="a-f-A-M-F", callsign="R-17", hae=3000)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, "s1", ce=30, type="a-n-A-C-F", callsign="DLH4", hae=3050)),
    ("tick", 0),
], [["new"], ["new"],
    [F("s1", None, members=["adsb/A7", "radar-1/T1"], hae_from="adsb/A7",
       attributes=A(type="adsb/A7", callsign="adsb/A7"))]],
    claims=[(2, "0.ce", math.sqrt(450.0)), (2, "0.hae", 3050)])

# 2. An entity without a usable fuse.group (absent, empty, not a string) is its
#    own unnamed group. Output order: named groups by name, then unnamed by key.
scenario("02-no-group-is-own-group", "fuse-independent", [
    ("ingest", rep("radar-1", "T9", 0, 0, 0, ce=30)),
    ("ingest", rep("radar-1", "T2", 0, 5000, 0, "", ce=30)),
    ("ingest", rep("adsb", "A1", 0, 9000, 0, None, ce=30, fuse__group=5)),
    ("ingest", rep("radar-1", "T5", 0, 20000, 0, "z9", ce=30)),
    ("ingest", rep("adsb", "A4", 0, 20010, 0, "b2", ce=30)),
    ("tick", 0),
], [["new"], ["new"], ["new"], ["new"], ["new"],
    [F("b2", members=["adsb/A4"]), F("z9", members=["radar-1/T5"]),
     F(None, members=["adsb/A1"]), F(None, members=["radar-1/T2"]), F(None, members=["radar-1/T9"])]])

# 3. A move is applied when the report is accepted; the latest fuse.group wins,
#    and a report without one makes the entity its own group again.
scenario("03-move-between-groups", "fuse-independent", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, "s1", ce=30)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, "s1", ce=30)),
    ("tick", 0),
    ("ingest", rep("radar-1", "T1", 1000, 0, 0, "s2", ce=30)),
    ("tick", 1000),
    ("ingest", rep("radar-1", "T1", 2000, 0, 0, ce=30)),
    ("ingest", rep("adsb", "A7", 2000, 10, 0, "s1", ce=30)),
    ("tick", 2000),
], [["new"], ["new"], [F("s1", members=["adsb/A7", "radar-1/T1"])],
    [{"ev": "move", "entity": "radar-1/T1", "from": "s1", "to": "s2"}],
    [F("s1", members=["adsb/A7"]), F("s2", members=["radar-1/T1"])],
    [{"ev": "move", "entity": "radar-1/T1", "from": "s2", "to": None}], [],
    [F("s1", members=["adsb/A7"]), F(None, members=["radar-1/T1"])]])

# 4. A report older than the entity's last is ignored (stale-report) and changes
#    nothing, not even the group it names; a report at the same time is accepted.
scenario("04-stale-report-ignored", "fuse-independent", [
    ("ingest", rep("radar-1", "T1", 5000, 0, 0, "s1", ce=30)),
    ("ingest", rep("radar-1", "T1", 4000, 100, 0, "s7", ce=30)),
    ("ingest", rep("radar-1", "T1", 5000, 10, 0, "s1", ce=30)),
    ("tick", 5000),
], [["new"],
    [{"ev": "stale-report", "entity": "radar-1/T1", "time_ms": 4000, "last_time_ms": 5000}],
    [], [F("s1", members=["radar-1/T1"])]])

# 5. Staleness as in correlate: a report's own stale_ms, then the pack's
#    stale_ms. A group whose members are all gone gives no event.
scenario("05-stale-members-drop", "fuse-independent", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, "s1", ce=30)),
    ("ingest", rep("adsb", "A7", 0, 10, 0, "s1", ce=30, stale_ms=3000)),
    ("tick", 2999),
    ("tick", 3000),
    ("tick", 120000),
    ("tick", 120001),
], [["new"], ["new"], [F("s1", members=["adsb/A7", "radar-1/T1"])],
    [{"ev": "drop", "entity": "adsb/A7", "group": "s1"}, F("s1", members=["radar-1/T1"])],
    [F("s1", members=["radar-1/T1"])],
    [{"ev": "drop", "entity": "radar-1/T1", "group": "s1"}]])

# 6. Rejections change no state; optional keys of the wrong type are absent.
scenario("06-rejections", "fuse-independent", [
    ("ingest", {"track.source_id": "radar-1", "time_ms": 0, "lat": 1.0, "lon": 1.0}),
    ("ingest", {"track.source_id": "radar-1", "uid": "T1", "time_ms": 0, "lat": "1.0", "lon": 1.0}),
    ("ingest", {"track.source_id": "radar-1", "uid": "T1", "time_ms": 0.5, "lat": 1.0, "lon": 1.0}),
    ("ingest", rep("radar-1", "T1", 0, 0, 0, "s1", ce="30", hae=None, type=7, callsign=["R", "17"])),
    ("tick", 0),
], [[{"ev": "reject", "reason": "missing:uid"}], [{"ev": "reject", "reason": "missing:lat"}],
    [{"ev": "reject", "reason": "missing:time_ms"}], ["new"],
    [F("s1", members=["radar-1/T1"], attributes={})]],
    claims=[(4, "0.ce", 50.0)])

# 7. Why covariance intersection exists, part 1. Truth is at (0, 0). Two
#    trackers both follow radar-1, whose bias puts every plot 40 m east, so
#    their errors are the same error: trk-a reports ce 30, trk-b ce 40, both
#    40 m east. Inverse variance treats them as independent:
#    ce = sqrt(1 / (1/900 + 1/1600)) = 24.0 m. With fully correlated errors the
#    weighted mean's true one-sigma is 0.64*30 + 0.36*40 = 33.6 m, and the
#    actual miss is 40 m: inverse variance claims an error smaller than the
#    truth allows. (Vector 08 runs the same input on covariance intersection.)
SHARED = [
    ("ingest", rep("trk-a", "S1", 0, 40, 0, "obj-1", ce=30, callsign="ALPHA", type="a-f-A")),
    ("ingest", rep("trk-b", "S9", 0, 40, 0, "obj-1", ce=40, callsign="BRAVO", type="a-h-A")),
    ("tick", 0),
]
scenario("07-shared-sensor-inverse-variance-overclaims", "fuse-independent", SHARED,
         [["new"], ["new"], [F("obj-1", None, members=["trk-a/S1", "trk-b/S9"])]],
         claims=[(2, "0.ce", 24.0)])


# --- fuse-shared: covariance intersection, attributes by latest and majority ---

# 8. Why covariance intersection exists, part 2: the same input. The weight on
#    trk-a is 1 (its variance is smaller on both axes), so ce = 30 m: no claim
#    of more certainty than the better member holds. Attributes: callsign by
#    latest (equal times, so key order: trk-a), type by majority (one each, so
#    the first holder in key order: trk-a).
scenario("08-shared-sensor-covariance-intersection", "fuse-shared", SHARED,
         [["new"], ["new"],
          [F("obj-1", None, members=["trk-a/S1", "trk-b/S9"],
             attributes=A(callsign="trk-a/S1", type="trk-a/S1", track__class=None))]],
         claims=[(2, "0.ce", 30.0), (2, "trace.0.value", 1.0)])

# 9. Members are folded in key order. a and b have equal variances (w = 0.5:
#    the mean position, the same variance); c has a larger one (w = 1).
#    Majority: two members say a-h-A; the winner is its first holder, b.
scenario("09-three-members-fold-in-key-order", "fuse-shared", [
    ("ingest", rep("eo-2", "E1", 0, 0, 0, "s1", ce=30, type="a-f-A", track__class="uas")),
    ("ingest", rep("radar-1", "T1", 0, 20, 0, "s1", ce=30, type="a-h-A", track__class="uas")),
    ("ingest", rep("radar-2", "T4", 0, 90, 0, "s1", ce=40, type="a-h-A", track__class="bird")),
    ("tick", 0),
], [["new"], ["new"], ["new"],
    [F("s1", members=["eo-2/E1", "radar-1/T1", "radar-2/T4"],
       attributes=A(type="radar-1/T1", track__class="eo-2/E1"))]],
    claims=[(3, "0.ce", 30.0), (3, "trace.0.value", 0.5), (3, "trace.1.value", 1.0),
            (3, "trace.0.member", "radar-1/T1"), (3, "trace.1.member", "radar-2/T4")])

# 10. Majority: 1 and 1.0 are one value, "1" and true are others; a tie between
#     two values goes to the one whose first holder comes first in key order;
#     an array is not a candidate. Latest: equal times go to key order.
scenario("10-majority-equality-and-ties", "fuse-shared", [
    ("ingest", rep("m", "1", 1000, 0, 0, "s1", ce=30, track__class=1, type="A", callsign="ONE")),
    ("ingest", rep("m", "2", 2000, 5, 0, "s1", ce=30, track__class="1", type="B", callsign="TWO")),
    ("ingest", rep("m", "3", 2000, 10, 0, "s1", ce=30, track__class=1.0, type="B", callsign="THREE")),
    ("ingest", rep("m", "4", 1000, 15, 0, "s1", ce=30, track__class=True, type="A", callsign=["X"])),
    ("ingest", rep("m", "5", 1000, 20, 0, "s1", ce=30, track__class=[1], type="C")),
    ("tick", 2000),
], [["new"], ["new"], ["new"], ["new"], ["new"],
    [F("s1", members=["m/1", "m/2", "m/3", "m/4", "m/5"],
       attributes=A(track__class="m/1", type="m/1", callsign="m/2"))]],
    claims=[(5, "0.attributes.track.class.value", 1), (5, "0.attributes.type.value", "A")])

# 11. A moving group is predicted to the tick: course and speed come from the
#     fused velocity.
mv = dict(course=90, speed_ms=100, ce=30)
scenario("11-moving-group-predicted", "fuse-shared", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, "s1", **mv)),
    ("ingest", rep("adsb", "A7", 0, 0, 20, "s1", ce=20, course=90, speed_ms=100)),
    ("ingest", rep("radar-1", "T1", 1000, 100, 0, "s1", **mv)),
    ("ingest", rep("adsb", "A7", 1000, 100, 20, "s1", ce=20, course=90, speed_ms=100)),
    ("tick", 3000),
], [["new"], ["new"], [], [], [F("s1", members=["adsb/A7", "radar-1/T1"])]],
    claims=[(4, "0.course", 90.0), (4, "0.speed_ms", 100.0), (4, "trace.0.value", 1.0)])


# --- fuse-best ---

# 12. best: the smallest position variance, ties to key order (a and c have
#     ce 20). Height comes only from the chosen member, which has none.
#     max/min skip non-numbers (true, "high"); ties go to key order.
scenario("12-best-and-max-min", "fuse-best", [
    ("ingest", rep("radar-1", "a", 0, 0, 0, "s1", ce=20, track__simulated=0, track__confirmed=1, track__confidence=0.7)),
    ("ingest", rep("radar-2", "b", 0, 30, 0, "s1", ce=50, hae=500, track__simulated=1, track__confirmed=1, track__confidence=0.9)),
    ("ingest", rep("radar-3", "c", 0, 60, 0, "s1", ce=20, track__simulated=True, track__confirmed=True, track__confidence="high")),
    ("tick", 0),
], [["new"], ["new"], ["new"],
    [F("s1", "radar-1/a", members=["radar-1/a", "radar-2/b", "radar-3/c"],
       attributes=A(track__simulated="radar-2/b", track__confirmed="radar-1/a", track__confidence="radar-2/b"))]],
    claims=[(3, "0.ce", 20.0)])

# 13. best after prediction: the member with the smaller ce but an older report
#     has grown past the other by the tick.
scenario("13-best-after-prediction", "fuse-best", [
    ("ingest", rep("radar-1", "a", 0, 0, 0, "s1", ce=20)),
    ("ingest", rep("radar-2", "b", 10000, 30, 0, "s1", ce=25, hae=800)),
    ("tick", 10000),
], [["new"], ["new"],
    [F("s1", "radar-2/b", members=["radar-1/a", "radar-2/b"], hae_from="radar-2/b", attributes={})]])


# --- fuse-priority: source order eo-2, radar-1; others after ---

# 14. priority: the smallest rank, ties to key order; an unlisted source ranks
#     last. A second group of unlisted sources falls back to key order.
scenario("14-priority-source-order", "fuse-priority", [
    ("ingest", rep("adsb", "X", 0, 0, 0, "s1", ce=10, callsign="ADSB", type="a-f-A")),
    ("ingest", rep("radar-1", "R1", 0, 10, 0, "s1", ce=30, callsign="R-ONE", type="a-u-A")),
    ("ingest", rep("radar-1", "R0", 500, 20, 0, "s1", ce=40, type="a-h-A")),
    ("ingest", rep("zz", "Z", 0, 5000, 0, "s2", ce=30, callsign="ZED")),
    ("ingest", rep("adsb", "Y", 0, 5010, 0, "s2", ce=30, callsign="WHY")),
    ("tick", 1000),
], [["new"], ["new"], ["new"], ["new"], ["new"],
    [F("s1", "radar-1/R0", members=["adsb/X", "radar-1/R0", "radar-1/R1"],
       attributes=A(callsign="radar-1/R1", type="radar-1/R0")),
     F("s2", "adsb/Y", members=["adsb/Y", "zz/Z"], attributes=A(callsign="adsb/Y"))]])

# 15. A member of the first source wins whatever its age or error.
scenario("15-priority-first-source-wins", "fuse-priority", [
    ("ingest", rep("eo-2", "E1", 0, 0, 0, "s1", ce=80, callsign="EYE")),
    ("ingest", rep("radar-1", "R1", 9000, 10, 0, "s1", ce=10, callsign="R-ONE", hae=100)),
    ("tick", 9000),
], [["new"], ["new"],
    [F("s1", "eo-2/E1", members=["eo-2/E1", "radar-1/R1"], attributes=A(callsign="eo-2/E1"))]])


# --- fuse-latest ---

# 16. latest: the greatest last report time, ties to key order; the height is
#     the chosen member's. A tick earlier than a member's report predicts it
#     backward (dt < 0). A tick with no entities gives nothing.
scenario("16-latest-and-empty-tick", "fuse-latest", [
    ("tick", 0),
    ("ingest", rep("radar-1", "a", 1000, 0, 0, "s1", ce=30, hae=100, callsign="OLD")),
    ("ingest", rep("radar-2", "b", 2000, 10, 0, "s1", ce=30, hae=200, callsign="NEW")),
    ("ingest", rep("radar-3", "c", 2000, 20, 0, "s1", ce=30)),
    ("tick", 1500),
    ("tick", 122001),
    ("tick", 122002),
], [[], ["new"], ["new"], ["new"],
    [F("s1", "radar-2/b", members=["radar-1/a", "radar-2/b", "radar-3/c"],
       hae=200, hae_from="radar-2/b", attributes=A(callsign="radar-2/b"))],
    ["drop", "drop", "drop"], []])


# --- load vectors ---

GOOD = """pack fuse-x
version 0.1.0
filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100
kinematics inverse_variance
stale_ms 1000
"""


def without(line):
    return "".join(l + "\n" for l in GOOD.splitlines() if not l.startswith(line))


def swap(line, new):
    return "".join((new if l.startswith(line) else l) + "\n" for l in GOOD.splitlines())


LOAD = [
    ("01-valid", GOOD, False),
    ("02-valid-every-directive", GOOD + "# a comment\n\nattribute type rule=majority  # trailing\n"
     "attribute\tcallsign\trule=latest\r\nsource adsb\nsource radar-1\n", False),
    ("03-unknown-directive", GOOD + "output priority\n", True),
    ("04-missing-pack", without("pack"), True),
    ("05-missing-version", without("version"), True),
    ("06-missing-filter", without("filter"), True),
    ("07-missing-kinematics", without("kinematics"), True),
    ("08-missing-stale-ms", without("stale_ms"), True),
    ("09-repeated-kinematics", GOOD + "kinematics best\n", True),
    ("10-unknown-method", swap("kinematics", "kinematics weighted"), True),
    ("11-kinematics-two-values", swap("kinematics", "kinematics best latest"), True),
    ("12-filter-missing-param", swap("filter", "filter accel_var=1 default_ce_m=50 vel_sigma_ms=5"), True),
    ("13-filter-unknown-param", swap("filter", "filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100 gain=2"), True),
    ("14-filter-not-a-number", swap("filter", "filter accel_var=1 default_ce_m=5x vel_sigma_ms=5 unknown_vel_ms=100"), True),
    ("15-filter-zero-variance", swap("filter", "filter accel_var=1 default_ce_m=0 vel_sigma_ms=5 unknown_vel_ms=100"), True),
    ("16-filter-negative-accel", swap("filter", "filter accel_var=-1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100"), True),
    ("17-filter-param-without-equals", swap("filter", "filter accel_var=1 default_ce_m 50 vel_sigma_ms=5 unknown_vel_ms=100"), True),
    ("18-filter-zero-accel-loads", swap("filter", "filter accel_var=0 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100"), False),
    ("19-stale-ms-negative", swap("stale_ms", "stale_ms -1"), True),
    ("20-stale-ms-not-integer", swap("stale_ms", "stale_ms 1000.0"), True),
    ("21-stale-ms-zero-loads", swap("stale_ms", "stale_ms 0"), False),
    ("22-attribute-unknown-rule", GOOD + "attribute type rule=mean\n", True),
    ("23-attribute-without-rule", GOOD + "attribute type\n", True),
    ("24-attribute-wrong-parameter", GOOD + "attribute type order=latest\n", True),
    ("25-attribute-extra-parameter", GOOD + "attribute type rule=latest weight=2\n", True),
    ("26-attribute-repeated-key", GOOD + "attribute type rule=latest\nattribute type rule=majority\n", True),
    ("27-source-repeated", GOOD + "source adsb\nsource adsb\n", True),
    ("28-source-two-values", GOOD + "source adsb radar-1\n", True),
    ("29-pack-two-values", swap("pack", "pack fuse-x fuse-y"), True),
    ("30-number-with-plus", swap("filter", "filter accel_var=+1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100"), True),
    ("31-number-exponent-loads", swap("filter", "filter accel_var=1e0 default_ce_m=5.0E1 vel_sigma_ms=5 unknown_vel_ms=100"), False),
    ("32-attribute-without-equals", GOOD + "attribute type latest\n", True),
    ("33-attribute-key-with-equals", GOOD + "attribute a=b rule=latest\n", True),
]


def clean(x):
    """Write negative zero as zero."""
    if isinstance(x, float):
        return 0.0 if x == 0 else x
    if isinstance(x, list):
        return [clean(v) for v in x]
    if isinstance(x, dict):
        return {k: clean(v) for k, v in x.items()}
    return x


def match(got, want):
    if isinstance(want, str) and isinstance(got, dict):
        return got.get("ev") == want
    if isinstance(want, dict):
        if not isinstance(got, dict) or (want == {} and got != {}):
            return False
        for k, w in want.items():
            if w is None and k in ("hae", "hae_from"):
                if k in got:
                    return False
                continue
            if w is None and k not in ("from", "group", "to"):
                if k in got:
                    return False
                continue
            if k not in got or not match(got[k], w):
                return False
        return True
    if isinstance(want, list):
        return isinstance(got, list) and len(got) == len(want) and all(match(g, w) for g, w in zip(got, want))
    if isinstance(want, bool) or isinstance(got, bool) or want is None:
        return got is want
    return got == want


def lookup(events, trace, path):
    if path.startswith("trace."):
        node, path = trace, path[len("trace."):]
    else:
        node = events
    parts = path.split(".")
    i = 0
    while i < len(parts):
        if isinstance(node, list):
            node = node[int(parts[i])]
            i += 1
            continue
        # keys may hold dots (track.class): take the longest key present
        for j in range(len(parts), i, -1):
            k = ".".join(parts[i:j])
            if k in node:
                node = node[k]
                i = j
                break
        else:
            raise KeyError(path)
    return node


def close(got, want):
    if isinstance(want, (int, float)) and not isinstance(want, bool):
        return isinstance(got, (int, float)) and not isinstance(got, bool) and abs(got - want) <= 1e-6 * max(1.0, abs(want))
    return got == want


def main():
    ok = True
    names = set()
    for name, pack_name, steps, decide, claims in SCENARIOS:
        if name in names:
            print("%s: repeated name" % name)
            ok = False
        names.add(name)
        eng = Engine(load_pack(os.path.join(ROOT, "packs", pack_name)))
        out_steps, results = [], []
        if len(decide) != len(steps):
            print("%s: decide has %d entries for %d steps" % (name, len(decide), len(steps)))
            ok = False
        for i, ((kind, arg), want) in enumerate(zip(steps, decide)):
            events, trace = eng.ingest(arg) if kind == "ingest" else eng.tick(arg)
            if not match(events, want):
                print("%s step %d: events %s\n  decided %s" % (name, i, json.dumps(events), want))
                ok = False
            results.append((events, trace))
            out_steps.append({kind: arg, "expect": clean(events), "trace": clean(trace)})
        for step, path, want in claims:
            try:
                got = lookup(*results[step], path)
            except (KeyError, IndexError):
                got = "<absent>"
            if not close(got, want):
                print("%s step %d: %s is %r, claimed %r" % (name, step, path, got, want))
                ok = False
        vec = {"name": name, "pack": pack_name, "steps": out_steps, "snapshot": clean(eng.snapshot())}
        path = os.path.join(ROOT, "packs", pack_name, "vectors", name + ".json")
        if ok:
            with open(path, "w", encoding="utf-8") as f:
                json.dump(vec, f, indent=1)
                f.write("\n")
    load_dir = os.path.join(ROOT, "spec", "fuse-load-vectors")
    os.makedirs(load_dir, exist_ok=True)
    for name, text, want_error in LOAD:
        try:
            parse_pack(text)
            got_error = False
        except PackError:
            got_error = True
        if got_error != want_error:
            print("load %s: error %s, decided %s" % (name, got_error, want_error))
            ok = False
            continue
        with open(os.path.join(load_dir, name + ".json"), "w", encoding="utf-8") as f:
            json.dump({"name": name, "pack_def": text, "expect_error": want_error}, f, indent=1)
            f.write("\n")
    if not ok:
        sys.exit(1)
    print("wrote %d scenario vectors and %d load vectors" % (len(SCENARIOS), len(LOAD)))


if __name__ == "__main__":
    main()
