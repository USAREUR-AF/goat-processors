#!/usr/bin/env python3
"""Write the filter conformance vectors for packs/filter-* and spec/filter-load-vectors/.

Each scenario below states its inputs and, in `decide`, the decision of every
step: for a report `keep:<rule>`, `drop:<rule>` or `reject`; for a tick the
list of entities it forgets. The script runs the Python engine, refuses to
write a vector whose events differ from `decide`, and records the full
events, trace and final snapshot as the vector. Each load vector states
whether its pack text must fail to load; the script refuses to write one the
engine's parser disagrees with. The decisions are stated by hand here; the
numbers come from the engine and are checked by the other six engines.

Run: python3 -I tools/make-filter-vectors.py
"""

import glob
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "engines", "python", "src"))
from goat_filter import PackError, load_pack, make_engine, parse_pack  # noqa: E402

R = 6371008.8
LAT0, LON0 = 1.0, 0.9  # notional: open ocean near 1 N 0.9 E, inside the filter-area box


def at(east_m, north_m, lat0=LAT0, lon0=LON0):
    lat = lat0 + math.degrees(north_m / R)
    lon = lon0 + math.degrees(east_m / (R * math.cos(math.radians(lat0))))
    return round(lat, 9), round(lon, 9)


def rep(src, uid, t, e=0.0, n=0.0, **kw):
    lat, lon = at(e, n, kw.pop("lat0", LAT0), kw.pop("lon0", LON0))
    r = {"track.source_id": src, "uid": uid, "time_ms": t, "lat": lat, "lon": lon}
    r.update(kw)
    return r


def raw(src, uid, t, lat, lon, **kw):
    r = {"track.source_id": src, "uid": uid, "time_ms": t, "lat": lat, "lon": lon}
    r.update(kw)
    return r


AIR = {"type": "a-f-A-M-F"}
SEA = {"type": "a-n-S-X"}

SCENARIOS = []


def scenario(name, pack, steps, decide):
    SCENARIOS.append((name, pack, steps, decide))


# --- filter-area ----------------------------------------------------------

# 1. Own ship is kept by the first rule, inside the box or outside it.
scenario("01-area-own-ship-first-rule", "filter-area", [
    ("ingest", rep("own", "OS1", 0)),
    ("ingest", raw("own", "OS1", 1000, 3.0, 0.7)),
], ["keep:own-ship", "keep:own-ship"])

# 2. Outside the box: a negated polygon passes and drops the report, even
#    next to own ship.
scenario("02-area-outside-box-negated", "filter-area", [
    ("ingest", rep("own", "OS1", 0)),
    ("ingest", raw("radar-1", "T1", 1000, 2.0, 1.0, **SEA)),
    ("ingest", raw("radar-1", "T2", 1000, 1.0, 0.45, **SEA)),
], ["keep:own-ship", "drop:outside-box", "drop:outside-box"])

# 3. Inside the box: 10 km from own ship is kept, 60 km is not.
scenario("03-area-near-own-ship", "filter-area", [
    ("ingest", rep("own", "OS1", 0)),
    ("ingest", rep("radar-1", "T1", 1000, 10000, 0, **SEA)),
    ("ingest", rep("radar-1", "T2", 1000, 60000, 0, **SEA)),
], ["keep:own-ship", "keep:near-own-ship", "drop:default"])

# 4. Own ship is predicted to the report's time: at 15 m/s east for 55 s it
#    has moved 825 m, which brings a contact 40.5 km east inside 40 km and
#    takes one 39.5 km west outside.
scenario("04-area-own-ship-predicted", "filter-area", [
    ("ingest", rep("own", "OS1", 0, course=90, speed_ms=15)),
    ("ingest", rep("radar-1", "T1", 55000, 40500, 0, **SEA)),
    ("ingest", rep("radar-1", "T2", 55000, -39500, 0, **SEA)),
], ["keep:own-ship", "keep:near-own-ship", "drop:default"])

# 5. Own ship age: exactly max_age_ms is not stale; one ms more is, and near
#    is unknown.
scenario("05-area-own-ship-age-limit", "filter-area", [
    ("ingest", rep("own", "OS1", 0)),
    ("ingest", rep("radar-1", "T1", 60000, 1000, 0, **SEA)),
    ("ingest", rep("radar-1", "T2", 60001, 1000, 0, **SEA)),
    ("ingest", rep("radar-1", "T3", -60001, 1000, 0, **SEA)),
], ["keep:own-ship", "keep:near-own-ship", "drop:default", "drop:default"])

# 6. Own ship's own stale_ms makes it stale from that time on.
scenario("06-area-own-ship-report-stale-ms", "filter-area", [
    ("ingest", rep("own", "OS1", 0, stale_ms=10000)),
    ("ingest", rep("radar-1", "T1", 9999, 1000, 0, **SEA)),
    ("ingest", rep("radar-1", "T2", 10000, 1000, 0, **SEA)),
], ["keep:own-ship", "keep:near-own-ship", "drop:default"])

# 7. Own ship has not reported: near is unknown and does not pass, with or
#    without not; high air is still kept.
scenario("07-area-no-own-ship", "filter-area", [
    ("ingest", rep("radar-1", "T1", 0, 1000, 0, **SEA)),
    ("ingest", rep("radar-1", "T2", 0, 2000, 0, hae=9000, **AIR)),
], ["drop:default", "keep:high-air"])

# 8. Polygon boundary: a report exactly on an edge, or on a vertex, is inside;
#    a report just outside the edge is not.
scenario("08-area-polygon-boundary", "filter-area", [
    ("ingest", raw("radar-1", "T1", 0, 0.5, 1.0, hae=8000, **AIR)),
    ("ingest", raw("radar-1", "T2", 0, 1.5, 1.5, hae=8000, **AIR)),
    ("ingest", raw("radar-1", "T3", 0, 0.4999, 1.0, hae=8000, **AIR)),
], ["keep:high-air", "keep:high-air", "drop:outside-box"])

# 9. The harbor circle drops before high air keeps; 6 km from its center the
#    circle does not hold.
scenario("09-area-harbor-before-high-air", "filter-area", [
    ("ingest", rep("radar-1", "T1", 0, 2000, 0, lat0=1.3, lon0=1.3, hae=8000, **AIR)),
    ("ingest", rep("radar-1", "T2", 0, 6000, 0, lat0=1.3, lon0=1.3, hae=8000, **AIR)),
], ["drop:harbor", "keep:high-air"])

# 10. Altitude: below the minimum is false, an absent hae is unknown, and a
#     surface report never reaches the altitude condition.
scenario("10-area-altitude-absent-unknown", "filter-area", [
    ("ingest", rep("radar-1", "T1", 0, 0, 0, hae=5000, **AIR)),
    ("ingest", rep("radar-1", "T2", 0, 0, 0, **AIR)),
    ("ingest", rep("radar-1", "T3", 0, 0, 0, hae=9000, **SEA)),
    ("ingest", rep("radar-1", "T4", 0, 0, 0, hae=6000, **AIR)),
], ["drop:default", "drop:default", "drop:default", "keep:high-air"])

# 11. Rejected reports give no trace and no state; an older report is not
#     rejected, and does not replace the stored position.
scenario("11-area-rejects-and-older-report", "filter-area", [
    ("ingest", {"track.source_id": "own", "uid": "OS1", "time_ms": 0, "lat": 1.0}),
    ("ingest", {"track.source_id": "own", "uid": 7, "time_ms": 0, "lat": 1.0, "lon": 1.0}),
    ("ingest", {"track.source_id": "own", "uid": "OS1", "time_ms": 1.5, "lat": 1.0, "lon": 1.0}),
    ("ingest", rep("own", "OS1", 5000, 0, 0)),
    ("ingest", rep("own", "OS1", 4000, 3000, 0)),
], ["reject", "reject", "reject", "keep:own-ship", "keep:own-ship"])

# 12. Tick forgets own ship one ms past forget_ms; after that near is unknown.
scenario("12-area-forget-own-ship", "filter-area", [
    ("ingest", rep("own", "OS1", 0)),
    ("tick", 600000),
    ("tick", 600001),
    ("ingest", rep("radar-1", "T1", 600002, 1000, 0, **SEA)),
], ["keep:own-ship", [], ["own/OS1"], "drop:default"])

# 13. A dropped report still gives its entity state, with no kept time.
scenario("13-area-dropped-report-has-state", "filter-area", [
    ("ingest", raw("radar-1", "T1", 0, 2.0, 1.0, **SEA)),
    ("ingest", raw("radar-1", "T1", 1000, 2.0, 1.01, **SEA)),
], ["drop:outside-box", "drop:outside-box"])


# --- filter-thin ----------------------------------------------------------

# 14. Air is thinned to one report every 2 s: exactly 2000 ms after the last
#     kept report is kept.
scenario("14-thin-air-interval", "filter-thin", [
    ("ingest", rep("radar-1", "T1", 0, **AIR)),
    ("ingest", rep("radar-1", "T1", 1000, **AIR)),
    ("ingest", rep("radar-1", "T1", 2000, **AIR)),
    ("ingest", rep("radar-1", "T1", 3999, **AIR)),
    ("ingest", rep("radar-1", "T1", 4000, **AIR)),
], ["keep:default", "drop:air-thin", "keep:default", "drop:air-thin", "keep:default"])

# 15. Hostile and suspect air is matched before the thinning rule.
scenario("15-thin-hostile-air-first-match", "filter-thin", [
    ("ingest", rep("radar-1", "H1", 0, type="a-h-A-M-F")),
    ("ingest", rep("radar-1", "H1", 500, type="a-h-A-M-F")),
    ("ingest", rep("radar-1", "H1", 1000, type="a-s-A")),
], ["keep:hostile-air", "keep:hostile-air", "keep:hostile-air"])

# 16. Interval state is per entity.
scenario("16-thin-surface-per-entity", "filter-thin", [
    ("ingest", rep("ais", "M1", 0, **SEA)),
    ("ingest", rep("ais", "M2", 0, **SEA)),
    ("ingest", rep("ais", "M1", 5000, **SEA)),
    ("ingest", rep("ais", "M2", 10000, **SEA)),
    ("ingest", rep("ais", "M1", 10000, **SEA)),
], ["keep:default", "keep:default", "drop:surface-thin", "keep:default", "keep:default"])

# 17. A dropped report does not move the interval: it counts from the last
#     kept report.
scenario("17-thin-dropped-does-not-advance", "filter-thin", [
    ("ingest", rep("radar-1", "T1", 0, **AIR)),
    ("ingest", rep("radar-1", "T1", 1500, **AIR)),
    ("ingest", rep("radar-1", "T1", 2500, **AIR)),
], ["keep:default", "drop:air-thin", "keep:default"])

# 18. order: older than the last kept report drops; the same time is not
#     older (then thinned); the snapshot keeps the newest time.
scenario("18-thin-order", "filter-thin", [
    ("ingest", rep("radar-1", "T1", 10000, **AIR)),
    ("ingest", rep("radar-1", "T1", 5000, 100, 0, **AIR)),
    ("ingest", rep("radar-1", "T1", 10000, 200, 0, **AIR)),
], ["keep:default", "drop:older", "drop:air-thin"])

# 19. key eq: the number 1, the float 1.0 and the string "1" equal eq=1;
#     true and 0 do not; an absent key is unknown.
scenario("19-thin-key-eq-types", "filter-thin", [
    ("ingest", rep("net", "1", 0, type="a-f-G", **{"track.simulated": 1})),
    ("ingest", rep("net", "2", 0, type="a-f-G", **{"track.simulated": 1.0})),
    ("ingest", rep("net", "3", 0, type="a-f-G", **{"track.simulated": "1"})),
    ("ingest", rep("net", "4", 0, type="a-f-G", **{"track.simulated": True})),
    ("ingest", rep("net", "5", 0, type="a-f-G", **{"track.simulated": 0})),
    ("ingest", rep("net", "6", 0, type="a-f-G")),
], ["drop:exercise", "drop:exercise", "drop:exercise", "keep:default", "keep:default", "keep:default"])

# 20. key range on ce: 2500 is coarse, 1500 is not; absent, a string, and 0
#     (absent by the report rules) are unknown.
scenario("20-thin-key-range-absent", "filter-thin", [
    ("ingest", rep("net", "1", 0, type="a-f-G", ce=2500)),
    ("ingest", rep("net", "2", 0, type="a-f-G", ce=1500)),
    ("ingest", rep("net", "3", 0, type="a-f-G")),
    ("ingest", rep("net", "4", 0, type="a-f-G", ce="3000")),
    ("ingest", rep("net", "5", 0, type="a-f-G", ce=0)),
], ["drop:coarse", "keep:default", "keep:default", "keep:default", "keep:default"])

# 21. Types: no type drops by the negated has; a short type has no
#     environment; a non-atom type has no affiliation.
scenario("21-thin-type-environment-affiliation", "filter-thin", [
    ("ingest", rep("net", "1", 0)),
    ("ingest", rep("net", "2", 0, type="a-f")),
    ("ingest", rep("net", "3", 0, type="b-h-A")),
    ("ingest", rep("net", "3", 500, type="b-h-A")),
    ("ingest", rep("net", "4", 0, type=5)),
], ["drop:no-type", "keep:default", "keep:default", "drop:air-thin", "drop:no-type"])

# 22. speed: a surface track at 45 m/s is dropped; at 20 m/s it is not; with
#     no speed the condition is unknown and thinning decides.
scenario("22-thin-surface-speed", "filter-thin", [
    ("ingest", rep("ais", "M1", 0, speed_ms=45, course=10, **SEA)),
    ("ingest", rep("ais", "M2", 0, speed_ms=20, course=10, **SEA)),
    ("ingest", rep("ais", "M2", 1000, **SEA)),
], ["drop:fast-surface", "keep:default", "drop:surface-thin"])

# 23. Forgetting removes the kept time: a report older than the forgotten one
#     is then not older. A tick with no state gives nothing.
scenario("23-thin-forget-resets", "filter-thin", [
    ("tick", 0),
    ("ingest", rep("radar-1", "T1", 1000, **AIR)),
    ("ingest", rep("ais", "M1", 200000, **SEA)),
    ("tick", 301000),
    ("tick", 301001),
    ("ingest", rep("radar-1", "T1", 500, **AIR)),
], [[], "keep:default", "keep:default", [], ["radar-1/T1"], "keep:default"])


# --- filter-dateline ------------------------------------------------------

# 24. A polygon across the antimeridian holds reports on both sides of it.
scenario("24-dateline-polygon", "filter-dateline", [
    ("ingest", raw("sat", "1", 0, 0.0, 179.5)),
    ("ingest", raw("sat", "2", 0, 0.0, -179.5)),
    ("ingest", raw("sat", "3", 0, 0.0, 180.0)),
    ("ingest", raw("sat", "4", 0, 0.0, 174.0)),
    ("ingest", raw("sat", "5", 0, 0.0, -174.0)),
    ("ingest", raw("sat", "6", 0, 10.0, -177.0)),
], ["keep:zone", "keep:zone", "keep:zone", "drop:default", "drop:default", "keep:zone"])

# 25. A circle centered on the antimeridian: 5 km across it is inside, 15.7 km
#     on the other side is not.
scenario("25-dateline-circle", "filter-dateline", [
    ("ingest", raw("sat", "1", 0, 20.0, -179.95)),
    ("ingest", raw("sat", "2", 0, 20.0, 179.85)),
], ["keep:anchorage", "drop:default"])

# 26. key in and key range: both must hold; an absent key is unknown; a range
#     on a string is unknown; bounds are inclusive; a number never equals a
#     word.
scenario("26-dateline-key-in-and-range", "filter-dateline", [
    ("ingest", raw("net", "1", 0, 40.0, 10.0, mission="alpha", priority=2)),
    ("ingest", raw("net", "2", 0, 40.0, 10.0, mission="bravo", priority=5)),
    ("ingest", raw("net", "3", 0, 40.0, 10.0, mission="charlie", priority=1)),
    ("ingest", raw("net", "4", 0, 40.0, 10.0, priority=1)),
    ("ingest", raw("net", "5", 0, 40.0, 10.0, mission="alpha", priority="2")),
    ("ingest", raw("net", "6", 0, 40.0, 10.0, mission="bravo", priority=3.0)),
    ("ingest", raw("net", "7", 0, 40.0, 10.0, mission=7, priority=1)),
], ["keep:tasked", "drop:default", "drop:default", "drop:default", "drop:default", "keep:tasked", "drop:default"])

# 27. source and uid lists.
scenario("27-dateline-source-uid", "filter-dateline", [
    ("ingest", raw("range", "TGT1", 0, 40.0, 10.0)),
    ("ingest", raw("range", "TGT3", 0, 40.0, 10.0)),
    ("ingest", raw("other", "TGT1", 0, 40.0, 10.0)),
], ["keep:range-test", "drop:default", "drop:default"])


# --- load vectors (spec/filter.md, Pack) ----------------------------------

BASE = "pack x\nversion 0.1.0\ndefault keep\nforget_ms 1000\n"
RULE = "rule r drop\n"

LOADS = [
    ("01-valid-minimal-no-rules", BASE, False),
    ("02-valid-every-condition", BASE + RULE
     + "when circle lat=-90 lon=180 radius_m=0\n"
     + "when not polygon vertices=0,0;0,1;1,1\n"
     + "when near reference=own/OS1 radius_m=1.5 max_age_ms=0\n"
     + "when env in=A,S\nwhen affiliation in=h\nwhen source in=a\nwhen uid in=b\n"
     + "when key name=k eq=x\nwhen key name=k in=x,y\nwhen key name=k min=-1\n"
     + "when key name=k max=1\nwhen key name=k min=1 max=1\nwhen has name=k\n"
     + "when speed min=0\nwhen altitude min=-10.5 max=100\nwhen interval min_ms=1\n"
     + "when order\n", False),
    ("03-valid-directives-after-rules", "rule r keep\nwhen order\npack x\nversion 1\nwhen has name=k\ndefault drop\nforget_ms 5\n", False),
    ("04-unknown-directive", BASE + "stale_ms 5\n", True),
    ("05-repeated-directive", BASE + "default drop\n", True),
    ("06-missing-pack", "version 0.1.0\ndefault keep\nforget_ms 1000\n", True),
    ("07-missing-version", "pack x\ndefault keep\nforget_ms 1000\n", True),
    ("08-missing-default", "pack x\nversion 0.1.0\nforget_ms 1000\n", True),
    ("09-missing-forget-ms", "pack x\nversion 0.1.0\ndefault keep\n", True),
    ("10-bad-default", "pack x\nversion 0.1.0\ndefault pass\nforget_ms 1000\n", True),
    ("11-pack-two-tokens", "pack x y\nversion 0.1.0\ndefault keep\nforget_ms 1000\n", True),
    ("12-forget-ms-zero", "pack x\nversion 0.1.0\ndefault keep\nforget_ms 0\n", True),
    ("13-forget-ms-not-integer", "pack x\nversion 0.1.0\ndefault keep\nforget_ms 1000.0\n", True),
    ("14-forget-ms-above-int64", "pack x\nversion 0.1.0\ndefault keep\nforget_ms 9223372036854775808\n", True),
    ("15-rule-bad-action", BASE + "rule r pass\nwhen order\n", True),
    ("16-rule-one-argument", BASE + "rule r\nwhen order\n", True),
    ("17-rule-repeated-name", BASE + RULE + "when order\n" + RULE + "when order\n", True),
    ("18-rule-named-default", BASE + "rule default drop\nwhen order\n", True),
    ("19-rule-without-when", BASE + RULE, True),
    ("20-when-before-rule", BASE + "when order\n" + RULE + "when order\n", True),
    ("21-unknown-condition", BASE + RULE + "when inside lat=1 lon=1 radius_m=1\n", True),
    ("22-not-alone", BASE + RULE + "when not\n", True),
    ("23-double-not", BASE + RULE + "when not not order\n", True),
    ("24-missing-param", BASE + RULE + "when circle lat=1 lon=1\n", True),
    ("25-extra-param", BASE + RULE + "when circle lat=1 lon=1 radius_m=1 unit=m\n", True),
    ("26-param-without-equals", BASE + RULE + "when circle lat=1 lon=1 radius_m\n", True),
    ("27-repeated-param", BASE + RULE + "when speed min=1 min=2\n", True),
    ("28-number-with-exponent", BASE + RULE + "when circle lat=1 lon=1 radius_m=1e3\n", True),
    ("29-number-with-plus", BASE + RULE + "when speed min=+1\n", True),
    ("30-number-leading-point", BASE + RULE + "when speed min=.5\n", True),
    ("31-negative-radius", BASE + RULE + "when circle lat=1 lon=1 radius_m=-1\n", True),
    ("32-latitude-out-of-range", BASE + RULE + "when circle lat=90.5 lon=1 radius_m=1\n", True),
    ("33-longitude-out-of-range", BASE + RULE + "when circle lat=1 lon=-180.1 radius_m=1\n", True),
    ("34-polygon-two-vertices", BASE + RULE + "when polygon vertices=0,0;1,1\n", True),
    ("35-polygon-bad-vertex", BASE + RULE + "when polygon vertices=0,0;1,1;2\n", True),
    ("36-polygon-vertex-out-of-range", BASE + RULE + "when polygon vertices=0,0;1,1;91,0\n", True),
    ("37-near-negative-age", BASE + RULE + "when near reference=a/b radius_m=1 max_age_ms=-1\n", True),
    ("38-near-empty-reference", BASE + RULE + "when near reference= radius_m=1 max_age_ms=1\n", True),
    ("39-empty-list-item", BASE + RULE + "when env in=A,,S\n", True),
    ("40-empty-list", BASE + RULE + "when uid in=\n", True),
    ("41-key-eq-and-in", BASE + RULE + "when key name=k eq=1 in=1,2\n", True),
    ("42-key-eq-and-min", BASE + RULE + "when key name=k eq=1 min=0\n", True),
    ("43-key-without-test", BASE + RULE + "when key name=k\n", True),
    ("44-key-empty-eq", BASE + RULE + "when key name=k eq=\n", True),
    ("45-range-min-above-max", BASE + RULE + "when altitude min=10 max=5\n", True),
    ("46-speed-without-bounds", BASE + RULE + "when speed\n", True),
    ("47-interval-zero", BASE + RULE + "when interval min_ms=0\n", True),
    ("48-interval-not-integer", BASE + RULE + "when interval min_ms=1.5\n", True),
    ("49-order-with-param", BASE + RULE + "when order strict=1\n", True),
    ("50-has-empty-name", BASE + RULE + "when has name=\n", True),
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


def summary(kind, events):
    if kind == "tick":
        return [e["entity"] for e in events]
    if len(events) != 1:
        return "events:%d" % len(events)
    e = events[0]
    return "reject" if e["ev"] == "reject" else "%s:%s" % (e["ev"], e["rule"])


def write(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1)
        f.write("\n")


def main():
    ok = True
    written = set()
    for name, pack_name, steps, decide in SCENARIOS:
        pack = load_pack(os.path.join(ROOT, "packs", pack_name))
        eng = make_engine(pack)
        out_steps = []
        if len(decide) != len(steps):
            print("%s: decide has %d entries for %d steps" % (name, len(decide), len(steps)))
            ok = False
        for (kind, arg), want in zip(steps, decide):
            events, trace = eng.ingest(arg) if kind == "ingest" else eng.tick(arg)
            got = summary(kind, events)
            if got != want:
                print("%s step %d: got %s, decided %s" % (name, len(out_steps), got, want))
                ok = False
            out_steps.append({kind: arg, "expect": clean(events), "trace": clean(trace)})
        vec = {"name": name, "pack": pack_name, "steps": out_steps, "snapshot": clean(eng.snapshot())}
        path = os.path.join(ROOT, "packs", pack_name, "vectors", name + ".json")
        write(path, vec)
        written.add(path)
    load_dir = os.path.join(ROOT, "spec", "filter-load-vectors")
    for name, text, expect_error in LOADS:
        try:
            parse_pack(text)
            failed = False
        except PackError:
            failed = True
        if failed != expect_error:
            print("load %s: load error %s, decided %s" % (name, failed, expect_error))
            ok = False
        path = os.path.join(load_dir, name + ".json")
        write(path, {"name": name, "pack_def": text, "expect_error": expect_error})
        written.add(path)
    for d in glob.glob(os.path.join(ROOT, "packs", "filter-*", "pack.def")):
        try:
            load_pack(os.path.dirname(d))
        except PackError as e:
            print("pack %s does not load: %s" % (d, e))
            ok = False
    stray = [p for p in glob.glob(os.path.join(ROOT, "packs", "filter-*", "vectors", "*.json"))
             + glob.glob(os.path.join(load_dir, "*.json")) if p not in written]
    for p in stray:
        print("stray vector, not written by a scenario: %s" % os.path.relpath(p, ROOT))
        ok = False
    if not ok:
        sys.exit(1)
    print("wrote %d scenario vectors and %d load vectors" % (len(SCENARIOS), len(LOADS)))


if __name__ == "__main__":
    main()
