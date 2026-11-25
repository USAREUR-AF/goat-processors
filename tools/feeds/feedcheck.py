#!/usr/bin/env python3
"""Is a recorded feed ready for correlation, and will two feeds exercise fusion?

    python3 -I tools/feeds/feedcheck.py RECORD [RECORD ...] [--pack PACK] [--json] [--rename]
    python3 -I tools/feeds/feedcheck.py --demo overlap|apart [--json]

RECORD is what the runner writes with `record.path` (JSON lines of
{"ingest": <report>} and {"tick": <now_ms>}), or JSON lines of reports.
Several files are merged in time order. The output names each source and
holds counts, rates, shares and medians only: no position, no track
identifier, no time of day. With --rename the sources are s1, s2, ... too, so
the summary can be shared outside the team.

--demo writes nothing: it checks a generated two-sensor capture, one whose
sensors see the same objects (overlap) and one whose sensors are 200 km
apart (apart), so the checks can be tried without a feed.

Every check, its limit and why: docs/real-feeds.md.
"""

import argparse
import json
import math
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools", "bench"))
sys.path.insert(0, os.path.join(ROOT, "engines", "python", "src"))

from goat_core import FUNCTIONS  # noqa: E402

R_M = 6371008.8
NEAR_M = 2000          # two tracks of different sources this close in one second could be one object
LIVE_MS = 10000        # a track is in the picture for this long after its last report
QUALITY_PACK = "quality-consistency"

# check -> (limit, how the value is compared, kind, why). A "required" check that fails makes a
# source not ready; an "advised" one is a warning; the "fusion" checks are about the sources together.
CHECKS = {
    "required keys": (1.0, ">=", "required", "a report without source, uid, time and position is rejected by every function"),
    "stated error": (0.9, ">=", "required", "without ce every report gets the pack's default error, and correlation cannot weigh one source against another"),
    "velocity": (0.5, ">=", "advised", "course and speed let correlation separate crossing and parallel tracks sooner"),
    "receive time": (0.9, ">=", "advised", "received_ms lets quality measure latency; a feed whose time is time of day only needs it"),
    "error honesty": (6.0, "<=", "required", "the median NIS above 6 means the source states an error much smaller than its real one, the leading cause of correlation errors in the benchmark"),
    "monotonic time": (0.99, ">=", "required", "a track whose reports go back in time loses them in correlate and fuse"),
    "co-observed": (0.2, ">=", "fusion", "the share of a source's track-seconds with another source's track within 2 km; below it, fusion has little to do"),
    "fused tracks": (0.1, ">=", "fusion", "the share of output tracks, per tick, holding more than one source; this is the fusion actually exercised"),
}


def distance_m(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians((b[1] - a[1] + 540) % 360 - 180)
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R_M * math.asin(min(1.0, math.sqrt(h)))


def read(paths):
    """The reports of every file, in time order, and the ticks if any file has them."""
    reports, ticks = [], []
    for p in paths:
        with open(p, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    raise SystemExit("%s:%d: not JSON" % (p, n))
                if isinstance(obj, dict) and "tick" in obj and len(obj) == 1:
                    ticks.append(obj["tick"])
                elif isinstance(obj, dict):
                    reports.append(obj.get("ingest", obj))
    reports.sort(key=lambda r: r.get("time_ms") if isinstance(r.get("time_ms"), int) else 0)
    return reports, sorted(set(ticks))


def num(r, k):
    v = r.get(k)
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def required(r):
    return (isinstance(r.get("track.source_id"), str) and isinstance(r.get("uid"), str)
            and isinstance(r.get("time_ms"), int) and num(r, "lat") and num(r, "lon"))


def per_source(reports):
    out = {}
    for r in reports:
        src = r.get("track.source_id") if isinstance(r.get("track.source_id"), str) else "(none)"
        s = out.setdefault(src, {"reports": 0, "ok": 0, "ce": 0, "vel": 0, "recv": 0, "back": 0,
                                 "last": {}, "intervals": [], "latency": [], "uids": set(), "t": []})
        s["reports"] += 1
        if not required(r):
            continue
        s["ok"] += 1
        s["ce"] += num(r, "ce") and r["ce"] > 0
        s["vel"] += num(r, "course") and num(r, "speed_ms")
        if isinstance(r.get("received_ms"), int):
            s["recv"] += 1
            s["latency"].append(r["received_ms"] - r["time_ms"])
        last = s["last"].get(r["uid"])
        if last is not None:
            if r["time_ms"] < last:
                s["back"] += 1
            else:
                s["intervals"].append(r["time_ms"] - last)
        s["last"][r["uid"]] = max(r["time_ms"], last or r["time_ms"])
        s["uids"].add(r["uid"])
        s["t"].append(r["time_ms"])
    return out


def honesty(reports):
    """Median over ticks of each source's nis_mean from the quality function."""
    eng = FUNCTIONS["quality"].open(os.path.join(ROOT, "packs", QUALITY_PACK))
    vals, nxt = {}, None
    for r in reports:
        if not required(r):
            continue
        if nxt is None:
            nxt = r["time_ms"] + 1000
        while r["time_ms"] >= nxt:
            for ev in eng.tick(nxt)[0]:
                if ev.get("ev") == "quality" and ev.get("scope") == "source" and ev["measures"].get("nis_mean") is not None:
                    vals.setdefault(ev["subject"], []).append(ev["measures"]["nis_mean"])
            nxt += 1000
        eng.ingest(r)
    return {s: statistics.median(v) for s, v in vals.items()}


def co_observed(reports):
    """Per source: the share of its track-seconds with another source's track within NEAR_M."""
    latest, hit, total, sec = {}, {}, {}, None
    def count():
        live = [(k, v) for k, v in latest.items() if sec * 1000 - v[0] <= LIVE_MS]
        for (src, uid), (t, pos) in live:
            total[src] = total.get(src, 0) + 1
            if any(o[0] != src and distance_m(pos, p) <= NEAR_M for o, (_, p) in live):
                hit[src] = hit.get(src, 0) + 1
    for r in reports:
        if not required(r):
            continue
        s = r["time_ms"] // 1000
        if sec is None:
            sec = s
        while sec < s:
            count()
            sec += 1
        latest[(r["track.source_id"], r["uid"])] = (r["time_ms"], (r["lat"], r["lon"]))
    if sec is not None:
        count()
    return {s: hit.get(s, 0) / total[s] for s in total}


def fused_share(reports, ticks, pack):
    """The share of output tracks, over ticks, whose members come from more than one source."""
    eng = FUNCTIONS["correlate"].open(os.path.join(ROOT, "packs", pack))
    good = [r for r in reports if required(r)]
    if not good:
        return None
    ticks = ticks or list(range(good[0]["time_ms"] // 1000 * 1000 + 1000, good[-1]["time_ms"] + 1001, 1000))
    multi = tracks = 0
    i = 0
    for t in ticks:
        while i < len(good) and good[i]["time_ms"] <= t:
            eng.ingest(good[i])
            i += 1
        for ev in eng.tick(t)[0]:
            if ev.get("ev") in ("system", "fused") and ev.get("members"):
                tracks += 1
                multi += len({m.split("/")[0] for m in ev["members"]}) > 1
    return multi / tracks if tracks else 0.0


def check(reports, ticks, pack="correlate-assign-time", rename=False):
    src = per_source(reports)
    names = {s: ("s%d" % (i + 1) if rename else s) for i, s in enumerate(sorted(src))}
    nis, co = honesty(reports), co_observed(reports)
    sources = {}
    for s, d in sorted(src.items()):
        ok = d["ok"] or 1
        span = (max(d["t"]) - min(d["t"])) / 1000 if d["t"] else 0
        sources[names[s]] = {
            "reports": d["reports"], "tracks": len(d["uids"]), "span_s": round(span),
            "reports_per_s": round(d["reports"] / span, 2) if span else None,
            "interval_median_s": round(statistics.median(d["intervals"]) / 1000, 2) if d["intervals"] else None,
            "latency_median_s": round(statistics.median(d["latency"]) / 1000, 2) if d["latency"] else None,
            "checks": {"required keys": d["ok"] / d["reports"], "stated error": d["ce"] / ok, "velocity": d["vel"] / ok,
                       "receive time": d["recv"] / ok, "error honesty": nis.get(s),
                       "monotonic time": 1 - d["back"] / ok, "co-observed": co.get(s, 0.0)}}
    fused = fused_share(reports, ticks, pack)
    return {"pack": pack, "sources": sources, "fused tracks": fused, "verdict": verdicts(sources, fused)}


def passes(name, v):
    limit, op, _, _ = CHECKS[name]
    return v is not None and (v >= limit if op == ">=" else v <= limit)


def verdicts(sources, fused):
    out = {}
    for s, d in sources.items():
        failed = [c for c, v in d["checks"].items() if CHECKS[c][2] == "required" and not passes(c, v)]
        warn = [c for c, v in d["checks"].items() if CHECKS[c][2] == "advised" and not passes(c, v)]
        out[s] = ("not ready: " + ", ".join(failed) if failed else
                  "ready, with warnings: " + ", ".join(warn) if warn else "ready")
    if len(sources) < 2:
        out["fusion"] = "one source: no fusion to exercise"
    else:
        seen = [s for s, d in sources.items() if passes("co-observed", d["checks"]["co-observed"])]
        out["fusion"] = ("exercised" if passes("fused tracks", fused) else
                         "not exercised: the sources rarely see the same objects" if len(seen) < 2 else
                         "not exercised although the sources see the same objects: look at correlation")
    return out


def show(res):
    for s, d in res["sources"].items():
        print("%s: %d reports, %d tracks over %d s, %s reports/s, interval %s s, latency %s s"
              % (s, d["reports"], d["tracks"], d["span_s"], d["reports_per_s"], d["interval_median_s"], d["latency_median_s"]))
        for c, v in d["checks"].items():
            limit, op, kind, _ = CHECKS[c]
            if kind == "fusion" and len(res["sources"]) < 2:
                continue
            print("  %-15s %8s   %s %-5s %-4s %s" % (c, "–" if v is None else "%.3g" % v, op, limit,
                                                    "ok" if passes(c, v) else "NO", kind))
    f = res["fused tracks"]
    print("fused tracks (%s): %s" % (res["pack"], "–" if f is None else "%.3g" % f))
    for k, v in res["verdict"].items():
        print("%s: %s" % (k, v))


def demo(kind):
    """A two-sensor capture from the benchmark's generator, as the runner would record it."""
    import scenarios as S
    objs = [S.Obj("o%d" % i, east=i * 3000.0, north=0.0, speed=200.0, heading=45.0 + 20 * i) for i in range(4)]
    sc = S.Scenario("demo-" + kind, "demo", "feedcheck demo", objs,
                    [S.radar(), S.passive()], duration_s=180, seed=7 if kind == "overlap" else 8)
    vector, _ = sc.build()
    reports, ticks = [], []
    for st in vector["steps"]:
        if "tick" in st:
            ticks.append(st["tick"])
            continue
        r = dict(st["ingest"])
        if kind == "apart" and r["track.source_id"] == "passive":
            r["lat"] += 1.8          # about 200 km north: the two sensors never see the same object
        reports.append(r)
    return reports, ticks


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("records", nargs="*")
    ap.add_argument("--demo", choices=["overlap", "apart"])
    ap.add_argument("--pack", default="correlate-assign-time")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--rename", action="store_true")
    a = ap.parse_args(argv)
    if bool(a.records) == bool(a.demo):
        ap.error("give RECORD files or --demo")
    reports, ticks = demo(a.demo) if a.demo else read(a.records)
    if not reports:
        raise SystemExit("no reports")
    res = check(reports, ticks, a.pack, a.rename)
    print(json.dumps(res, indent=1)) if a.json else show(res)
    return 0


if __name__ == "__main__":
    sys.exit(main())
