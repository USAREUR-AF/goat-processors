#!/usr/bin/env python3
"""Write the quality conformance vectors for packs/quality-* and the load
vectors in spec/quality-load-vectors/.

Each scenario below states its inputs and, in `decide`, the events it must
produce, written as short tokens (see `token`). The script runs the Python
engine, refuses to write a vector whose events differ from `decide`, and
records the full events, trace and final snapshot as the vector. The
decisions are stated by hand here; the numbers come from the engine and are
checked by the other six engines.

Run: python3 -I tools/make-quality-vectors.py
"""

import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "engines", "python", "src"))
from goat_quality import Engine, PackError, load_pack, parse_pack  # noqa: E402

R = 6371008.8
LAT0, LON0 = 1.0, 1.0  # notional: open ocean near 0 N 0 E


def at(east_m, north_m):
    lat = LAT0 + math.degrees(north_m / R)
    lon = LON0 + math.degrees(east_m / (R * math.cos(math.radians(LAT0))))
    return round(lat, 9), round(lon, 9)


def rep(src, uid, t, e=0.0, n=0.0, lag=None, **kw):
    """A report at plane offset (e, n) m; `lag` sets received_ms = t + lag."""
    lat, lon = at(e, n)
    r = {"track.source_id": src, "uid": uid, "time_ms": t, "lat": lat, "lon": lon}
    if lag is not None:
        r["received_ms"] = t + lag
    r.update(kw)
    return r


def token(ev):
    """One event as a decision token."""
    k = ev["ev"]
    if k == "pass":
        return "pass" + (":withheld" if ev["withheld"] else "") + "".join(":" + r for r in ev["rules"])
    if k == "quality":
        return "q:" + ev["subject"]
    if k == "action-start":
        return "start:%s:%s" % (ev["rule"], ev["subject"])
    if k == "action-end":
        return "end:%s:%s:%s" % (ev["rule"], ev["subject"], ev["reason"])
    if k == "forget":
        return "forget:" + ev.get("entity", ev.get("source", ""))
    return k


SCENARIOS = []


def scenario(name, pack, steps, decide):
    SCENARIOS.append((name, pack, steps, decide))


NEW = ["new", "pass"]
PASS = ["pass"]
T1 = "radar-1/T1"
RAD = "radar-1"


def q(*subjects):
    return ["q:" + s for s in subjects]


# --- quality-feed ---------------------------------------------------------

# 1. Measures: a steady track, one report each 5 s, 400 ms late, with every
#    optional key. Every measure is present; no rule fires.
full = dict(ce=30, hae=100, course=0, speed_ms=0)
scenario("q01-feed-steady-measures", "quality-feed", [
    ("ingest", rep(RAD, "T1", 0, lag=400, **full)),
    ("ingest", rep(RAD, "T1", 5000, lag=400, **full)),
    ("ingest", rep(RAD, "T1", 10000, lag=400, **full)),
    ("ingest", rep(RAD, "T1", 15000, lag=400, **full)),
    ("ingest", rep(RAD, "T1", 20000, lag=400, **full)),
    ("tick", 20000),
    ("tick", 25000),
], [NEW, PASS, PASS, PASS, PASS, q(T1, RAD), q(T1, RAD)])

# 2. Minimum samples: with fewer than min_samples samples a statistic is
#    absent (null), never 0; counts and age are always present.
scenario("q02-feed-few-samples-absent", "quality-feed", [
    ("ingest", rep(RAD, "T1", 0, lag=100)),
    ("ingest", rep(RAD, "T1", 5000, lag=100)),
    ("tick", 5000),
    ("ingest", rep(RAD, "T1", 10000, lag=100)),
    ("tick", 10000),
], [NEW, PASS, q(T1, RAD), PASS, q(T1, RAD)])

# 3. Alert and hysteresis on age: age 30000 does not exceed the limit; 30001
#    does and the alert starts at once (for=1); a new report brings age to 0,
#    below clear, and the alert ends. An alert never changes a report.
scenario("q03-feed-silent-alert-and-clear", "quality-feed", [
    ("ingest", rep(RAD, "T1", 0)),
    ("ingest", rep(RAD, "T1", 5000)),
    ("ingest", rep(RAD, "T1", 10000)),
    ("tick", 40000),
    ("tick", 40001),
    ("ingest", rep(RAD, "T1", 45000)),
    ("tick", 45000),
], [NEW, PASS, PASS, q(T1, RAD), q(T1) + ["start:silent:" + T1] + q(RAD), PASS,
    q(T1) + ["end:silent:%s:clear" % T1] + q(RAD)])

# 4. for=2 and mark: the mean interval exceeds 10 s on two ticks in a row; the
#    mark starts on the second. Later reports carry quality.marks. At a mean
#    of 8667 ms (between clear and limit) the mark stays; at 7714 it ends.
scenario("q04-feed-slow-mark-two-ticks", "quality-feed", [
    ("ingest", rep(RAD, "T1", 0)),
    ("ingest", rep(RAD, "T1", 12000)),
    ("ingest", rep(RAD, "T1", 24000)),
    ("ingest", rep(RAD, "T1", 36000)),
    ("tick", 36000),
    ("ingest", rep(RAD, "T1", 48000)),
    ("tick", 48000),
    ("ingest", rep(RAD, "T1", 50000)),
    ("ingest", rep(RAD, "T1", 52000)),
    ("tick", 52000),
    ("ingest", rep(RAD, "T1", 54000)),
    ("tick", 54000),
    ("ingest", rep(RAD, "T1", 56000)),
], [NEW, PASS, PASS, PASS, q(T1, RAD), PASS, q(T1) + ["start:slow:" + T1] + q(RAD),
    ["pass:slow"], ["pass:slow"], q(T1, RAD), ["pass:slow"],
    q(T1) + ["end:slow:%s:clear" % T1] + q(RAD), PASS])

# 5. Drop: a report 12 s late starts the drop; the track's reports are
#    withheld while it lasts. The late report leaves the window when its
#    window time is window_ms or more before the tick; the worst latency is
#    then below clear and the reports are forwarded again. The same report
#    lifts the source's mean latency above 2000 ms on two ticks (source-latent
#    alert), which ends with it.
scenario("q05-feed-late-drop", "quality-feed", [
    ("ingest", rep(RAD, "T1", 0, lag=500)),
    ("ingest", rep(RAD, "T1", 5000, lag=500)),
    ("ingest", rep(RAD, "T1", 10000, lag=12000)),
    ("tick", 10000),
    ("ingest", rep(RAD, "T1", 15000, lag=500)),
    ("tick", 15000),
    ("ingest", rep(RAD, "T1", 20000, lag=500)),
    ("ingest", rep(RAD, "T1", 30000, lag=500)),
    ("ingest", rep(RAD, "T1", 40000, lag=500)),
    ("ingest", rep(RAD, "T1", 50000, lag=500)),
    ("ingest", rep(RAD, "T1", 60000, lag=500)),
    ("tick", 69999),
    ("ingest", rep(RAD, "T1", 70000, lag=500)),
    ("tick", 70000),
    ("ingest", rep(RAD, "T1", 75000, lag=500)),
], [NEW, PASS, PASS, q(T1) + ["start:late:" + T1] + q(RAD), ["pass:withheld:late"],
    q(T1, RAD) + ["start:source-latent:" + RAD],
    ["pass:withheld:late"], ["pass:withheld:late"], ["pass:withheld:late"], ["pass:withheld:late"],
    ["pass:withheld:late"], q(T1, RAD),
    ["pass:withheld:late"], q(T1) + ["end:late:%s:clear" % T1] + q(RAD) + ["end:source-latent:%s:clear" % RAD],
    PASS])

# 6. Source aggregation is the mean of the entity measures, not a mean over
#    reports: adsb/A1 has 3 reports 4 s late, adsb/A2 6 reports 0.5 s late.
#    Over reports the mean would be 1667 ms; over entities it is 2250 ms, above
#    the limit, and the alert starts on the second tick. radar-1 sends no
#    received_ms: its latency is absent and its rule count stays 0.
A1, A2 = "adsb/A1", "adsb/A2"
scenario("q06-feed-source-latency-mean-of-entities", "quality-feed", [
    ("ingest", rep("adsb", "A1", 0, lag=4000)),
    ("ingest", rep("adsb", "A2", 0, 100, lag=500)),
    ("ingest", rep(RAD, "T1", 0, 50)),
    ("ingest", rep("adsb", "A2", 2000, 100, lag=500)),
    ("ingest", rep("adsb", "A2", 4000, 100, lag=500)),
    ("ingest", rep("adsb", "A1", 5000, lag=4000)),
    ("ingest", rep(RAD, "T1", 5000, 50)),
    ("ingest", rep("adsb", "A2", 6000, 100, lag=500)),
    ("ingest", rep("adsb", "A2", 8000, 100, lag=500)),
    ("ingest", rep("adsb", "A1", 10000, lag=4000)),
    ("ingest", rep("adsb", "A2", 10000, 100, lag=500)),
    ("ingest", rep(RAD, "T1", 10000, 50)),
    ("tick", 10000),
    ("tick", 11000),
    ("tick", 12000),
], [NEW, NEW, NEW, PASS, PASS, PASS, PASS, PASS, PASS, PASS, PASS, PASS,
    q(A1, A2, T1, "adsb", RAD),
    q(A1, A2, T1, "adsb") + ["start:source-latent:adsb"] + q(RAD),
    q(A1, A2, T1, "adsb", RAD)])

# 7. Order and duplicates: a report earlier than the track's latest is counted
#    out of order, one at the same time as a duplicate; neither moves the
#    filter. Both take the latest time as their window time. disorder marks
#    later reports; marks are appended to an input list of strings and replace
#    any other value. The out-of-order record leaves the window at 70000.
scenario("q07-feed-out-of-order-and-duplicate", "quality-feed", [
    ("ingest", rep(RAD, "T1", 0)),
    ("ingest", rep(RAD, "T1", 5000)),
    ("ingest", rep(RAD, "T1", 10000)),
    ("ingest", rep(RAD, "T1", 7000, 30)),
    ("ingest", rep(RAD, "T1", 10000, 10)),
    ("tick", 10000),
    ("ingest", rep(RAD, "T1", 15000, **{"quality.marks": ["upstream"]})),
    ("ingest", rep(RAD, "T1", 20000, **{"quality.marks": "upstream"})),
    ("ingest", rep(RAD, "T1", 30000, **{"quality.marks": ["disorder"]})),
    ("ingest", rep(RAD, "T1", 40000)),
    ("ingest", rep(RAD, "T1", 50000)),
    ("ingest", rep(RAD, "T1", 60000)),
    ("ingest", rep(RAD, "T1", 70000)),
    ("tick", 69999),
    ("tick", 70000),
    ("ingest", rep(RAD, "T1", 75000)),
], [NEW, PASS, PASS, PASS, PASS, q(T1) + ["start:disorder:" + T1] + q(RAD),
    ["pass:disorder"], ["pass:disorder"], ["pass:disorder"], ["pass:disorder"],
    ["pass:disorder"], ["pass:disorder"], ["pass:disorder"],
    q(T1, RAD), q(T1) + ["end:disorder:%s:clear" % T1] + q(RAD), PASS])

# 8. Forget: a track silent for more than forget_ms is forgotten at the tick;
#    its active actions end with reason forget, then its source, now with no
#    tracks, is forgotten. Rule states for both are removed (snapshot).
scenario("q08-feed-forget-ends-actions", "quality-feed", [
    ("ingest", rep(RAD, "T1", 0)),
    ("ingest", rep(RAD, "T1", 5000)),
    ("ingest", rep(RAD, "T1", 10000)),
    ("ingest", rep("adsb", "A1", 41000)),
    ("tick", 41000),
    ("tick", 310000),
    ("tick", 310001),
], [NEW, PASS, PASS, NEW, q(A1, T1) + ["start:silent:" + T1] + q("adsb", RAD),
    q(A1) + ["start:silent:" + A1] + q(T1, "adsb", RAD),
    ["end:silent:%s:forget" % T1, "forget:" + T1, "forget:" + RAD] + q(A1, "adsb")])

# 9. Rejections: a missing or mistyped required key rejects the report and
#    nothing is forwarded; a tick earlier than the previous tick is rejected;
#    a tick equal to it is not.
scenario("q09-feed-rejects", "quality-feed", [
    ("ingest", {"track.source_id": RAD, "time_ms": 0, "lat": 1.0, "lon": 1.0}),
    ("ingest", {"track.source_id": RAD, "uid": "T1", "time_ms": 1000.0, "lat": 1.0, "lon": 1.0}),
    ("ingest", {"track.source_id": RAD, "uid": 1, "time_ms": 1000, "lat": 1.0, "lon": 1.0}),
    ("ingest", rep(RAD, "T1", 1000)),
    ("tick", 1000),
    ("tick", 999),
    ("tick", 1000),
], [["reject"], ["reject"], ["reject"], NEW, q(T1, RAD), ["reject"], q(T1, RAD)])

# 10. Optional keys of the wrong type, null, or a ce of 0 or below count as
#     missing; course without speed_ms is a missing velocity. The report is
#     forwarded exactly as received.
scenario("q10-feed-optional-keys-missing", "quality-feed", [
    ("ingest", rep(RAD, "T1", 0, ce="30", hae=None, course=90, received_ms="400")),
    ("ingest", rep(RAD, "T1", 5000, ce=0, hae=100, course=90, speed_ms=5, received_ms=5400.0)),
    ("ingest", rep(RAD, "T1", 10000, ce=-1, hae="high", speed_ms=5, received_ms=10400)),
    ("ingest", rep(RAD, "T1", 15000, ce=30, hae=100, course=90, speed_ms=True)),
    ("tick", 15000),
], [NEW, PASS, PASS, PASS, q(T1, RAD)])


# --- quality-consistency --------------------------------------------------

# Deterministic offsets (m) about a stationary object: about 30 m one-sigma per axis.
HONEST = [(0, 0), (30, -38), (-45, 15), (22, 52), (-38, -30), (45, 8), (-15, -45), (8, 38)]
STILL = dict(course=0, speed_ms=0)

# 11. An honest source: ce 30 and errors of about 30 m. nis_mean stays near 2,
#     below the limit; nothing is downgraded.
scenario("q11-consistency-honest-source", "quality-consistency",
         [("ingest", rep(RAD, "T1", i * 5000, e, n, ce=30, **STILL)) for i, (e, n) in enumerate(HONEST)]
         + [("tick", 35000), ("tick", 36000)],
         [NEW] + [PASS] * 7 + [q(T1, RAD), q(T1, RAD)])

# 12. Downgrade and restore: eo-2 reports ce 5 with errors of about 40 m.
#     nis_mean is above 6 on two ticks and the downgrade starts; forwarded ce
#     is doubled. Measures use the report as received, so the downgrade does not
#     lower them. eo-2 then reports ce 50: once the ce-5 samples leave the
#     window nis_mean falls below 3 and the downgrade ends.
E = "eo-2/E1"
SWING12 = [(30, -30), (-30, 30)]
seq12 = []
for i in range(5):
    e, n = SWING12[i % 2]
    seq12.append(("ingest", rep("eo-2", "E1", i * 5000, e, n, ce=5, **STILL)))
    if i >= 3:
        seq12.append(("tick", i * 5000))
seq12.append(("ingest", rep("eo-2", "E1", 25000, 30, -30, ce=5, **STILL)))
for i in range(6, 18):
    e, n = SWING12[i % 2]
    seq12.append(("ingest", rep("eo-2", "E1", i * 5000, e, n, ce=50, **STILL)))
    if i * 5000 == 50000:
        seq12.append(("tick", 50000))
seq12.append(("tick", 85000))
seq12.append(("ingest", rep("eo-2", "E1", 90000, 30, -30, ce=50, **STILL)))
scenario("q12-consistency-downgrade-and-restore", "quality-consistency", seq12,
         [NEW, PASS, PASS, PASS, q(E, "eo-2"), PASS, q(E, "eo-2") + ["start:overconfident:eo-2"],
          ["pass:overconfident"]] + [["pass:overconfident"]] * 5 + [q(E, "eo-2")]
         + [["pass:overconfident"]] * 7 + [q(E, "eo-2") + ["end:overconfident:eo-2:clear"], PASS])

# 13. Missing keys: ais sends ce on 1 of 3 reports for M1 and none for M2; the
#     source rate is the mean of 0.667 and 1.0, above 0.5: alert at once.
M1, M2 = "ais/M1", "ais/M2"
scenario("q13-consistency-missing-ce-alert", "quality-consistency", [
    ("ingest", rep("ais", "M1", 0, ce=20)),
    ("ingest", rep("ais", "M2", 0, 500)),
    ("ingest", rep("ais", "M1", 10000)),
    ("ingest", rep("ais", "M2", 10000, 500)),
    ("ingest", rep("ais", "M1", 20000)),
    ("ingest", rep("ais", "M2", 20000, 500)),
    ("tick", 20000),
    ("ingest", rep("ais", "M1", 30000)),
], [NEW, NEW, PASS, PASS, PASS, PASS, q(M1, M2, "ais") + ["start:no-error:ais"], PASS])

# 14. Implied speed: a track moves east at 100 m/s but reports 60 m/s. The
#     difference averages 40 m/s and the mark starts; once the window holds
#     only reports of 100 m/s the mean is below 10 and the mark ends. speed_ms
#     without course is no velocity measurement, so the filter takes velocity
#     from positions alone.
seq14 = [("ingest", rep(RAD, "T1", i * 10000, i * 1000.0, 0, ce=30, speed_ms=60)) for i in range(4)]
seq14.append(("tick", 30000))
seq14 += [("ingest", rep(RAD, "T1", i * 10000, i * 1000.0, 0, ce=30, speed_ms=100)) for i in range(4, 11)]
seq14.append(("tick", 100000))
scenario("q14-consistency-speed-mismatch-mark", "quality-consistency", seq14,
         [NEW, PASS, PASS, PASS, q(T1) + ["start:speed-mismatch:" + T1] + q(RAD)]
         + [["pass:speed-mismatch"]] * 7 + [q(T1) + ["end:speed-mismatch:%s:clear" % T1] + q(RAD)])

# 15. Actions stack in pack order: a source downgrade and an entity mark on one
#     report. A report without ce is forwarded with default_ce_m times factor.
scenario("q15-consistency-actions-stack", "quality-consistency", [
    ("ingest", rep("eo-2", "E1", 0, 40, -40, ce=5, speed_ms=60, **{"course": 0})),
    ("ingest", rep("eo-2", "E1", 5000, -40, 40, ce=5, speed_ms=60, course=0)),
    ("ingest", rep("eo-2", "E1", 10000, 40, -40, ce=5, speed_ms=60, course=0)),
    ("ingest", rep("eo-2", "E1", 15000, -40, 40, ce=5, speed_ms=60, course=0)),
    ("tick", 15000),
    ("tick", 16000),
    ("ingest", rep("eo-2", "E1", 20000, 40, -40, speed_ms=60, course=0, **{"quality.marks": ["upstream"]})),
    ("ingest", rep("eo-2", "E1", 25000, -40, 40, ce=7.5, speed_ms=60, course=0)),
], [NEW, PASS, PASS, PASS, q(E) + ["start:speed-mismatch:" + E] + q("eo-2"),
    q(E, "eo-2") + ["start:overconfident:eo-2"],
    ["pass:overconfident:speed-mismatch"], ["pass:overconfident:speed-mismatch"]])


# --- quality-time (0.2) -----------------------------------------------------

SRC4 = ["adsb", "ais", "eo-2", "radar-1"]


STATED = dict(time_state="coherent", time_error_ms=5)


def rounds(times, skew, pos=None, **kw):
    """One report per source per round, sources in SRC4 order; `skew` adds ms
    to a source's time_ms (its clock offset)."""
    steps = []
    for t in times:
        for i, src in enumerate(SRC4):
            e = 1000.0 * i if pos is None else pos
            steps.append(("ingest", rep(src, "T", t + skew.get(src, 0), e, 0, **STATED)))
    return steps


def qs(*sources):
    return q(*(src + "/T" for src in sources))


ALL_E = qs(*SRC4)

# 16. Lateness: eo-2's clock is 3 s behind. Against the median of the other
#     sources' latest times its reports are about 3 s late; the mean exceeds
#     2000 ms on two ticks and the alert starts. The other sources stay within
#     a round of each other, so none is behind or ahead.
st16 = rounds([0, 1000, 2000, 3000], {"eo-2": -3000}) + [("tick", 3000), ("tick", 3500)]
scenario("q16-time-lateness-behind", "quality-time", st16,
         [NEW] * 4 + [PASS] * 12 + [ALL_E + q(*SRC4), ALL_E + q("adsb", "ais", "eo-2") + ["start:behind:eo-2"] + q("radar-1")])

# 17. A clock ahead: eo-2 stamps 3 s ahead. Every one of its reports is more
#     than 1.5 s ahead of the others, so its reports are marked from the next
#     report on. A median over the other sources keeps the three honest
#     sources from reading as behind.
st17 = rounds([0, 1000, 2000], {"eo-2": 3000}) + [("tick", 2000)] + rounds([3000], {"eo-2": 3000})
scenario("q17-time-ahead-marks", "quality-time", st17,
         [NEW] * 4 + [PASS] * 8 + [ALL_E + q("adsb", "ais", "eo-2") + ["start:ahead:eo-2"] + q("radar-1"),
                                   PASS, PASS, ["pass:ahead"], PASS])

# 18. Source order across tracks: radar-1 reports T1 to T3 at 10 s, then
#     three new tracks at 4 s, as after a clock step back. Each new track is
#     in order for itself (first report) but earlier than its source's latest:
#     source_out_of_order reaches 3 and the alert starts. out_of_order stays 0.
st18 = [("ingest", rep(RAD, "T%d" % i, 10000, 100.0 * i)) for i in (1, 2, 3)]
st18 += [("ingest", rep(RAD, "T%d" % i, 4000, 100.0 * i)) for i in (4, 5, 6)]
st18 += [("tick", 10000)]
scenario("q18-time-source-out-of-order", "quality-time", st18,
         [NEW] * 6 + [q(*("radar-1/T%d" % i for i in range(1, 7))) + q(RAD)[:0]
                      + ["q:" + RAD, "start:source-disorder:" + RAD]])

# 19. Time state: ais goes free-running. The worst state in its window
#     reaches 2 and the downgrade starts: forwarded ce is multiplied by 4. It
#     ends once the free-running report has left the window.
AIS = "ais/M1"
st19 = [("ingest", rep("ais", "M1", t, ce=20, time_state="coherent", time_error_ms=5)) for t in (0, 10000, 20000)]
st19 += [("ingest", rep("ais", "M1", 30000, ce=20, time_state="free-running", time_error_ms=40)), ("tick", 30000)]
st19 += [("ingest", rep("ais", "M1", t, ce=20, time_state="coherent", time_error_ms=5)) for t in (40000, 50000, 60000, 70000, 80000, 90000)]
st19 += [("tick", 89999), ("tick", 90000), ("ingest", rep("ais", "M1", 100000, ce=20, time_state="coherent", time_error_ms=5))]
scenario("q19-time-free-running-downgrade", "quality-time", st19,
         [NEW, PASS, PASS, PASS, q(AIS) + ["q:ais", "start:free-running:ais"]]
         + [["pass:free-running"]] * 6 + [q(AIS, "ais"), q(AIS) + ["q:ais", "end:free-running:ais:clear"], PASS])

# 20. Resolution of the time keys, per key: the report's value, else the
#     pack's time_default for the source, else unstated. net-a states nothing
#     and takes its default (error 150 ms, drifting): time-error marks it. One
#     report overrides the error with 20 ms. radar-1 states nothing and has no
#     default: its time measures are absent, never 0, and time-unstated
#     alerts. An unknown state or a negative error is absent.
NA = "net-a/N1"
st20 = [
    ("ingest", rep("net-a", "N1", 0)),
    ("ingest", rep(RAD, "T1", 0, 500)),
    ("ingest", rep("net-a", "N1", 1000, time_error_ms=-5, time_state="unsure")),
    ("ingest", rep(RAD, "T1", 1000, 500, time_state="unsure", time_error_ms="5")),
    ("ingest", rep("net-a", "N1", 2000, time_error_ms=20)),
    ("ingest", rep(RAD, "T1", 2000, 500)),
    ("tick", 2000),
    ("ingest", rep("net-a", "N1", 3000)),
    ("ingest", rep(RAD, "T1", 3000, 500)),
]
scenario("q20-time-default-and-unstated", "quality-time", st20,
         [NEW, NEW, PASS, PASS, PASS, PASS,
          q(NA, T1) + ["q:net-a", "start:time-error:net-a", "q:" + RAD, "start:time-unstated:" + RAD],
          ["pass:time-error"], PASS])

# --- quality-edge (0.2) ------------------------------------------------------

# 21. A forwarded ce that overflows binary64 is the largest finite binary64.
scenario("q21-edge-ce-overflow-clamped", "quality-edge", [
    ("ingest", rep(RAD, "T1", 0, ce=1e10)),
    ("ingest", rep(RAD, "T1", 1000, ce=1e10)),
    ("tick", 1000),
    ("ingest", rep(RAD, "T1", 2000, ce=1e10)),
], [NEW, PASS, q(T1) + ["start:huge:" + T1] + q(RAD), ["pass:huge"]])

# 22. Key collision: source a/b with uid c and source a with uid b/c build
#     the same key a/b/c. They are one entity, whose source is that of its
#     first report (a/b); the second report's source a is a source with no
#     entity, so it has no quality event. The second report makes two
#     reports, so the entity rule huge starts.
scenario("q22-edge-key-collision", "quality-edge", [
    ("ingest", {"track.source_id": "a/b", "uid": "c", "time_ms": 0, "lat": 1.0, "lon": 1.0}),
    ("ingest", {"track.source_id": "a", "uid": "b/c", "time_ms": 1000, "lat": 1.0, "lon": 1.0}),
    ("tick", 1000),
], [NEW, PASS, q("a/b/c") + ["start:huge:a/b/c"] + q("a/b")])


# --- load vectors -----------------------------------------------------------

FEED = open(os.path.join(ROOT, "packs", "quality-feed", "pack.def"), encoding="utf-8").read()
HEAD = ("pack     t\nversion  0.1.0\n"
        "filter   accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
        "window   window_ms=60000 min_samples=3 forget_ms=300000\n")
OK_RULE = "rule a scope=entity measure=age op=> limit=10 for=1 clear=5 action=alert\n"

LOADS = [
    ("01-valid-feed", FEED, False),
    ("02-valid-no-rules", HEAD, False),
    ("03-unknown-directive", HEAD + "gate distance max_m=1\n", True),
    ("04-repeated-directive", HEAD + "window   window_ms=1 min_samples=1 forget_ms=1\n", True),
    ("05-missing-pack", HEAD.replace("pack     t\n", ""), True),
    ("06-missing-version", HEAD.replace("version  0.1.0\n", ""), True),
    ("07-missing-filter", HEAD.replace("filter   accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n", ""), True),
    ("08-missing-window", HEAD.replace("window   window_ms=60000 min_samples=3 forget_ms=300000\n", ""), True),
    ("09-pack-two-values", HEAD.replace("pack     t", "pack     t u"), True),
    ("10-filter-missing-param", HEAD.replace(" unknown_vel_ms=100", ""), True),
    ("11-filter-zero-sigma", HEAD.replace("vel_sigma_ms=5", "vel_sigma_ms=0"), True),
    ("12-filter-negative-accel", HEAD.replace("accel_var=1", "accel_var=-1"), True),
    ("13-filter-zero-accel-loads", HEAD.replace("accel_var=1", "accel_var=0"), False),
    ("14-window-unknown-param", HEAD.replace("forget_ms=300000", "forget_ms=300000 stale_ms=1"), True),
    ("15-window-zero-min-samples", HEAD.replace("min_samples=3", "min_samples=0"), True),
    ("16-window-zero-window", HEAD.replace("window_ms=60000", "window_ms=0"), True),
    ("17-window-float-integer", HEAD.replace("window_ms=60000", "window_ms=60000.0"), True),
    ("18-number-with-exponent", HEAD.replace("default_ce_m=50", "default_ce_m=5e1"), True),
    ("19-rule-without-name", HEAD + OK_RULE.replace("rule a ", "rule "), True),
    ("20-rule-bad-name", HEAD + OK_RULE.replace("rule a ", "rule a|b "), True),
    ("21-rule-repeated-name", HEAD + OK_RULE + OK_RULE, True),
    ("22-rule-missing-param", HEAD + OK_RULE.replace(" for=1", ""), True),
    ("23-rule-unknown-param", HEAD + OK_RULE.replace(" for=1", " for=1 after=2"), True),
    ("24-rule-repeated-param", HEAD + OK_RULE.replace(" for=1", " for=1 for=2"), True),
    ("25-rule-param-without-equals", HEAD + OK_RULE.replace(" for=1", " for=1 extra"), True),
    ("26-rule-bad-scope", HEAD + OK_RULE.replace("scope=entity", "scope=group"), True),
    ("27-rule-unknown-measure", HEAD + OK_RULE.replace("measure=age", "measure=speed"), True),
    ("28-rule-entities-on-entity", HEAD + OK_RULE.replace("measure=age", "measure=entities"), True),
    ("29-rule-entities-on-source-loads", HEAD + OK_RULE.replace("scope=entity measure=age", "scope=source measure=entities"), False),
    ("30-rule-bad-op", HEAD + OK_RULE.replace("op=>", "op=="), True),
    ("31-rule-bad-action", HEAD + OK_RULE.replace("action=alert", "action=log"), True),
    ("32-rule-for-zero", HEAD + OK_RULE.replace("for=1", "for=0"), True),
    ("33-rule-limit-not-number", HEAD + OK_RULE.replace("limit=10", "limit=ten"), True),
    ("34-rule-clear-wrong-side-above", HEAD + OK_RULE.replace("clear=5", "clear=11"), True),
    ("35-rule-clear-wrong-side-below", HEAD + OK_RULE.replace("op=>", "op=<"), True),
    ("36-rule-clear-equal-limit-loads", HEAD + OK_RULE.replace("clear=5", "clear=10"), False),
    ("37-downgrade-without-factor", HEAD + OK_RULE.replace("action=alert", "action=downgrade"), True),
    ("38-factor-without-downgrade", HEAD + OK_RULE.replace("action=alert", "action=alert factor=2"), True),
    ("39-downgrade-factor-below-one", HEAD + OK_RULE.replace("action=alert", "action=downgrade factor=0.5"), True),
    ("40-downgrade-factor-one-loads", HEAD + OK_RULE.replace("action=alert", "action=downgrade factor=1"), False),
    ("42-rule-for-not-integer", HEAD + OK_RULE.replace("for=1", "for=1.5"), True),
    ("43-rule-clear-not-number", HEAD + OK_RULE.replace("clear=5", "clear=five"), True),
    ("44-downgrade-factor-not-number", HEAD + OK_RULE.replace("action=alert", "action=downgrade factor=two"), True),
    ("45-version-two-values", HEAD.replace("version  0.1.0", "version  0.1.0 0.2.0"), True),
    ("46-crlf-loads", HEAD.replace("\n", "\r\n"), False),
    ("47-inner-cr", HEAD.replace("pack     t", "pack     t\rx"), True),
    ("48-form-feed", HEAD.replace("pack     t", "pack\fu"), True),
    ("49-no-break-space-is-not-a-separator", HEAD.replace("pack     t", "pack\u00a0t"), True),
    ("50-tab-separator-loads", HEAD.replace("pack     t", "pack\tt"), False),
    ("51-number-not-finite", HEAD + OK_RULE.replace("limit=10", "limit=1" + "0" * 400), True),
    ("52-time-default-loads", HEAD + "time_default net-a error_ms=150 state=drifting\n", False),
    ("53-time-default-state-only-loads", HEAD + "time_default net-a state=free-running\n", False),
    ("54-time-default-error-only-loads", HEAD + "time_default net-a error_ms=0\n", False),
    ("55-time-default-no-params", HEAD + "time_default net-a\n", True),
    ("56-time-default-no-source", HEAD + "time_default error_ms=5\n", True),
    ("57-time-default-same-source-twice", HEAD + "time_default net-a state=drifting\ntime_default net-a error_ms=5\n", True),
    ("58-time-default-negative-error", HEAD + "time_default net-a error_ms=-1\n", True),
    ("59-time-default-bad-state", HEAD + "time_default net-a state=lost\n", True),
    ("60-time-default-unknown-param", HEAD + "time_default net-a error_ms=5 offset_ms=2\n", True),
    ("61-time-default-exponent", HEAD + "time_default net-a error_ms=1e2\n", True),
    ("62-time-default-two-sources-loads", HEAD + "time_default net-a state=drifting\ntime_default net-b state=coherent\n", False),
    ("41-negative-limit-loads", HEAD + OK_RULE.replace("op=> limit=10 for=1 clear=5", "op=< limit=-10 for=1 clear=-5"), False),
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


def main():
    ok = True
    for name, pack_name, steps, decide in SCENARIOS:
        eng = Engine(load_pack(os.path.join(ROOT, "packs", pack_name)))
        out_steps = []
        if len(decide) != len(steps):
            print("%s: decide has %d entries for %d steps" % (name, len(decide), len(steps)))
            ok = False
        for (kind, arg), want in zip(steps, decide):
            events, trace = eng.ingest(arg) if kind == "ingest" else eng.tick(arg)
            got = [token(e) for e in events]
            if got != want:
                print("%s step %d: events %s, decided %s" % (name, len(out_steps), got, want))
                ok = False
            out_steps.append({kind: arg, "expect": clean(events), "trace": clean(trace)})
        vec = {"name": name, "pack": pack_name, "steps": out_steps, "snapshot": clean(eng.snapshot())}
        path = os.path.join(ROOT, "packs", pack_name, "vectors", name + ".json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(vec, f, indent=1)
            f.write("\n")
    for name, text, want_error in LOADS:
        try:
            parse_pack(text)
            got_error = False
        except PackError:
            got_error = True
        if got_error != want_error:
            print("load %s: error %s, decided %s" % (name, got_error, want_error))
            ok = False
        path = os.path.join(ROOT, "spec", "quality-load-vectors", name + ".json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"name": name, "pack_def": text, "expect_error": want_error}, f, indent=1)
            f.write("\n")
    if not ok:
        sys.exit(1)
    print("wrote %d vectors and %d load vectors" % (len(SCENARIOS), len(LOADS)))


if __name__ == "__main__":
    main()
