#!/usr/bin/env python3
"""Accuracy of fuse, filter and quality against ground truth (correlate: bench.py).

Commands (run with `python3 -I`):

  report   run every case, write docs/benchmark-functions.md and
           docs/figures/bench/functions.json
  check    run every case again and confirm both files are what the tool writes
  score F PACK   print one pack's scores as JSON (F: fuse, filter or quality)

Every case is generated from public tuning seeds. What each case generates
and the formula of every score: tools/bench/README.md, "Functions".
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import adapters  # noqa: E402
import dataset  # noqa: E402
from scenarios import Rng, to_deg, to_plane  # noqa: E402

from goat_core import FUNCTIONS  # noqa: E402  (adapters puts the Python engine on the path)

ROOT = adapters.ROOT
RESULTS = os.path.join(ROOT, "docs", "figures", "bench", "functions.json")
DOC = os.path.join(ROOT, "docs", "benchmark-functions.md")
B, BOOT_SEED = 1000, 20261124

FUSE_PACKS = ["fuse-independent", "fuse-shared", "fuse-best", "fuse-latest", "fuse-priority"]
FILTER_PACKS = ["filter-area", "filter-dateline"]
QUALITY_PACKS = ["quality-feed", "quality-consistency", "quality-time"]
# Packs with no case, each with the reason.
NOT_COVERED = {
    "filter-thin": "its rules act on report fields and intervals, so truth cannot disagree with them; "
                   "what thinning costs the picture is not measured",
    "quality-edge": "a conformance pack of edge values, not for operational use",
}
N_RANDOM, N_FILTER, N_QUALITY = 60, 30, 30
CHI2_95_2DOF = 5.991464547107979


def engine(function, pack):
    return FUNCTIONS[function].open(os.path.join(ROOT, "packs", pack))


def seed(*parts):
    return dataset._seed(dataset.TUNING_ROOT, "functions/" + "/".join(str(p) for p in parts))


# ---------------------------------------------------------------------------
# Counts, scores and intervals. A run's raw counts are summed over runs.


def add(runs):
    return {k: sum(r[k] for r in runs) for k in runs[0]}


def derive_decisions(s):
    tp, fp, fn = s["tp"], s["fp"], s["fn"]
    out = {"precision": tp / (tp + fp) if tp + fp else None,
           "recall": tp / (tp + fn) if tp + fn else None,
           "f1": 2 * tp / (2 * tp + fp + fn) if tp + fp + fn else None}
    if "delay_n" in s:
        out["delay_s"] = s["delay_s"] / s["delay_n"] if s["delay_n"] else None
    return out


def derive_fuse(s):
    n = s["n"]
    return {"rms_m": math.sqrt(s["sq"] / n), "nees": s["nees"] / n, "within95": s["in95"] / n} if n else {}


DERIVE = {"fuse": derive_fuse, "filter": derive_decisions, "quality": derive_decisions}


def summarize(function, runs):
    """Pooled scores and 95 % bootstrap intervals over scenarios."""
    derive, n = DERIVE[function], len(runs)
    pooled = derive(add(runs))
    rng, vals = Rng(BOOT_SEED), {k: [] for k in pooled}
    for _ in range(B):
        d = derive(add([runs[rng.integer(0, n - 1)] for _ in range(n)]))
        for k in vals:
            if d.get(k) is not None:
                vals[k].append(d[k])
    ci = {}
    for k, v in vals.items():
        v.sort()
        ci[k] = [v[int(0.025 * (len(v) - 1))], v[int(0.975 * (len(v) - 1))]] if len(v) >= 0.9 * B else None
    return {"n": n, "pooled": pooled, "ci95": ci, "runs": runs}   # runs: for the paired comparison (tools/review)


# ---------------------------------------------------------------------------
# Fuse: the true grouping is given, so only the estimate is scored.


# In a sensor's summary, the words that name a fault other than latency and missed detections.
FAULT_WORDS = ("bias", "error reported", "no error", "swap", "drop", "false", "clock")


def fuse_cases():
    """{case: [(vector, truth)]} with fuse.group set to the true object."""
    tuning = dataset.tuning_set()
    built = [sc.build() for sc in tuning if sc.family == "random"]
    honest = [c for c in built if not any(w in s for s in c[1]["sensors"] for w in FAULT_WORDS)][:N_RANDOM]
    rnd = built[:N_RANDOM]
    problems = [sc.build() for sc in tuning if sc.family == "sensor problems"
                and sc.name.startswith("sensor-problems-")]
    shared = []
    for i, (vector, truth) in enumerate(honest):
        # A second tracker follows the first source's sensor: the same position error, plus 5 m of its own.
        rng = Rng(seed("shared", i))
        first = min(s["ingest"]["track.source_id"] for s in vector["steps"] if "ingest" in s)
        steps, labels = [], []
        for step, label in zip(vector["steps"], truth["labels"]):
            steps.append(step)
            labels.append(label)
            if step.get("ingest", {}).get("track.source_id") == first:
                r = dict(step["ingest"])
                e, n = to_plane(r["lat"], r["lon"])
                r["lat"], r["lon"] = to_deg(e + rng.normal(5.0), n + rng.normal(5.0))
                r["track.source_id"] = first + "-second"
                steps.append({"ingest": r})
                labels.append(label)
        shared.append((dict(vector, steps=steps), dict(truth, labels=labels)))
    return {"honest sensors": honest, "honest, one sensor tracked twice": shared, "random, all faults": rnd,
            "sensor problems": problems}


# Within "random, all faults", each estimate by the state of its members, the worst first.
BREAKDOWN = ["a member changed object", "a member is silent", "neither"]


def run_fuse(pack, case):
    """Counts over every estimate, and one set of counts per BREAKDOWN state."""
    vector, truth = case
    eng = engine("fuse", pack)
    ticks = {t: i for i, t in enumerate(truth["ticks"])}
    last, heard, described = {}, {}, {}
    zero = {"n": 0, "sq": 0.0, "nees": 0.0, "in95": 0}
    out, parts = dict(zero), {b: dict(zero) for b in BREAKDOWN}
    for step, label in zip(vector["steps"], truth["labels"]):
        if "ingest" in step:
            if label is None:
                continue                # a false track belongs to no object
            r = step["ingest"]
            eng.ingest(dict(r, **{"fuse.group": label}))
            key = r["track.source_id"] + "/" + r["uid"]
            last[label] = max(last.get(label, 0), r["time_ms"])
            heard[key] = max(heard.get(key, 0), r["time_ms"])
            described.setdefault(key, set()).add(label)
            continue
        now = step["tick"]
        for ev in eng.tick(now)[0]:
            if ev.get("ev") != "fused" or now - last.get(ev["group"], -10**9) > truth["live_ms"]:
                continue
            pos = truth["objects"][ev["group"]]["pos"][ticks[now]]
            if pos is None:
                continue
            (e, n), (te, tn) = to_plane(ev["lat"], ev["lon"]), to_plane(*pos)
            d2, var = (e - te) ** 2 + (n - tn) ** 2, ev["ce"] ** 2
            state = (BREAKDOWN[0] if any(len(described[m]) > 1 for m in ev["members"]) else
                     BREAKDOWN[1] if any(now - heard[m] > truth["live_ms"] for m in ev["members"]) else BREAKDOWN[2])
            for c in (out, parts[state]):
                c["n"] += 1
                c["sq"] += d2
                c["nees"] += d2 / (2 * var)
                c["in95"] += d2 <= CHI2_95_2DOF * var
    return out, parts


# ---------------------------------------------------------------------------
# Filter: the right decision is the pack's rules on the true position,
# computed here from the pack's plain description; the engine sees a position
# with error. Keep is the positive class.

FILTER_SIGMAS = [20, 100, 500]
R_M = 6371008.8


def distance_m(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians((b[1] - a[1] + 540) % 360 - 180)
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * R_M * math.asin(min(1.0, math.sqrt(h)))


def moved(pos, east, north):
    lat = pos[0] + math.degrees(north / R_M)
    lon = pos[1] + math.degrees(east / (R_M * math.cos(math.radians(pos[0]))))
    return lat, (lon + 540) % 360 - 180


def right_area(pos, own, env, hae):
    if not (0.5 < pos[0] < 1.5 and 0.5 < pos[1] < 1.5) or distance_m(pos, (1.3, 1.3)) <= 5000:
        return False
    return distance_m(pos, own) <= 40000 or (env == "A" and hae >= 6000)


def right_dateline(pos, own, env, hae):
    return (-10 < pos[0] < 10 and abs(pos[1]) > 175) or distance_m(pos, (20.0, 180.0)) <= 10000


def run_filter(pack, sigma, i):
    """20 tracks, 60 s, one report a second each, starting within 15 km of a boundary."""
    rng = Rng(seed(pack, sigma, i))
    eng = engine("filter", pack)
    area = pack == "filter-area"
    right = right_area if area else right_dateline
    own = (1.0, 1.0)
    tracks = []
    for k in range(20):
        off = rng.uniform(-15000, 15000)
        along = rng.uniform(-1, 1)
        if area:
            pos = rng.choice([moved((0.5, 1.0 + 0.45 * along), 0, off), moved((1.0 + 0.45 * along, 1.5), off, 0),
                              moved((1.3, 1.3), off, rng.uniform(-8000, 8000)),
                              moved(own, (40000 + off) * math.cos(3 * along), (40000 + off) * math.sin(3 * along))])
        else:
            pos = rng.choice([moved((9.0 * along, 175.0), off, 0), moved((10.0, 180.0 + 4.5 * along), 0, off),
                              moved((20.0, 180.0), off, rng.uniform(-12000, 12000))])
        tracks.append({"pos": pos, "env": rng.choice(["A", "S"]), "hae": rng.uniform(0, 12000),
                       "v": (rng.uniform(-150, 150), rng.uniform(-150, 150))})
    s = {"tp": 0, "fp": 0, "fn": 0, "tn": 0}
    for t in range(60):
        if area:
            eng.ingest({"track.source_id": "own", "uid": "OS1", "time_ms": t * 1000, "lat": own[0], "lon": own[1],
                        "type": "a-f-S"})
        for k, tr in enumerate(tracks):
            pos = moved(tr["pos"], tr["v"][0] * t, tr["v"][1] * t)
            seen = moved(pos, rng.normal(sigma), rng.normal(sigma))
            events, _ = eng.ingest({"track.source_id": "radar", "uid": "T%d" % k, "time_ms": t * 1000,
                                    "lat": seen[0], "lon": seen[1], "ce": float(sigma), "hae": tr["hae"],
                                    "type": "a-u-" + tr["env"]})
            kept = any(e.get("ev") == "keep" for e in events)
            if not kept and not any(e.get("ev") == "drop" for e in events):
                raise SystemExit("filter gave neither keep nor drop: %r" % events)
            want = right(pos, own, tr["env"], tr["hae"])
            s["tp" if kept and want else "fp" if kept else "fn" if want else "tn"] += 1
    return s


# ---------------------------------------------------------------------------
# Quality: one source (or track) has a fault of graded size around the rule's
# meaning; the right answer is known from the size injected.

DURATION_S, WARMUP_S = 300, 90      # the pack's window is 60 s; scores start once it is full


def fault_slow(rng):
    m = rng.uniform(0.5, 1.8)
    return {"interval_s": 10 * m}, m > 1


def fault_latent(rng):
    m = rng.uniform(0.5, 2.0)
    return {"latency_s": 2 * m}, m > 1


def fault_overconfident(rng):
    f = rng.choice([1.0, 1.25, 1.5, 2.0, 2.5, 3.0])
    return {"sigma_factor": f}, f >= 2


def fault_no_error(rng):
    p = rng.uniform(0.1, 0.9)
    return {"missing_ce": p}, p > 0.5


def fault_speed(rng):
    b = rng.uniform(0, 45)
    return {"speed_bias": b}, b > 20


def fault_behind(rng):
    o = rng.uniform(0.5, 4.0)
    return {"clock_s": -o}, o > 2


def fault_ahead(rng):
    o = rng.uniform(0.3, 3.0)
    return {"clock_s": o}, o > 1.5


def fault_unstated(rng):
    p = rng.uniform(0.1, 0.9)
    return {"unstated": p}, p > 0.5


# pack -> rule -> (scope, fault, what makes the right answer "active")
FAULTS = {
    "quality-feed": {
        "slow": ("entity", fault_slow, "true mean interval above 10 s"),
        "source-latent": ("source", fault_latent, "true mean latency above 2 s")},
    "quality-consistency": {
        "overconfident": ("source", fault_overconfident, "true error at least 2 times the stated error"),
        "no-error": ("source", fault_no_error, "error left out of more than half the reports"),
        "speed-mismatch": ("entity", fault_speed, "reported speed more than 20 m/s wrong")},
    "quality-time": {
        "behind": ("source", fault_behind, "clock more than 2 s behind"),
        "ahead": ("source", fault_ahead, "clock more than 1.5 s ahead"),
        "time-unstated": ("source", fault_unstated, "time state left out of more than half the reports")},
}


def run_quality(pack, rule, i):
    """Four sources of three tracks (half turning at 3 deg/s in part); source s0 has the fault."""
    scope, fault, _ = FAULTS[pack][rule]
    rng = Rng(seed(pack, rule, i))
    params, positive = fault(rng)
    reports = []
    for s in range(4):
        p = params if s == 0 else {}
        for k in range(3):
            e, n = rng.uniform(-30000, 30000), rng.uniform(-30000, 30000)
            heading, speed = rng.uniform(0, 2 * math.pi), rng.uniform(60, 220)
            turns = rng.chance(0.5)
            period, ce = p.get("interval_s", 1.0), 30.0
            t, t_last = rng.uniform(0, period), 0.0
            while t < DURATION_S:
                steps = max(1, int((t - t_last) * 10))
                dt = (t - t_last) / steps
                for j in range(steps):
                    if turns and 120 <= (t_last + j * dt) % 200 < 150:
                        heading += math.radians(3) * dt
                    e += speed * math.sin(heading) * dt
                    n += speed * math.cos(heading) * dt
                t_last = t
                sigma = ce * p.get("sigma_factor", 1.0)
                lat, lon = to_deg(e + rng.normal(sigma), n + rng.normal(sigma))
                latency = p.get("latency_s", 0.4) * rng.uniform(0.5, 1.5)
                r = {"track.source_id": "s%d" % s, "uid": "T%d" % k,
                     "time_ms": 100000 + int(round((t + p.get("clock_s", 0.0)) * 1000)),
                     "received_ms": 100000 + int(round((t + latency) * 1000)), "lat": lat, "lon": lon,
                     "course": math.degrees(heading) % 360,
                     "speed_ms": max(0.0, speed + p.get("speed_bias", 0.0) + rng.normal(1.0))}
                if not rng.chance(p.get("missing_ce", 0.0)):
                    r["ce"] = ce
                if not rng.chance(p.get("unstated", 0.0)):
                    r["time_state"], r["time_error_ms"] = "coherent", 1
                reports.append((t + latency, r["track.source_id"], r["uid"], r))
                t += period * rng.uniform(0.8, 1.2)
    reports.sort(key=lambda x: x[:3])
    eng = engine("quality", pack)
    subjects = {"source": ["s%d" % s for s in range(4)],
                "entity": ["s%d/T%d" % (s, k) for s in range(4) for k in range(3)]}[scope]
    active, first, j = set(), {}, 0
    out = {"tp": 0, "fp": 0, "fn": 0, "tn": 0, "delay_s": 0.0, "delay_n": 0}
    for now in range(1, DURATION_S + 1):
        while j < len(reports) and reports[j][0] <= now:
            eng.ingest(reports[j][3])
            j += 1
        for ev in eng.tick(100000 + now * 1000)[0]:
            if ev.get("rule") != rule:
                continue
            if ev["ev"] == "action-start":
                active.add(ev["subject"])
                first.setdefault(ev["subject"], now)
            elif ev["ev"] == "action-end":
                active.discard(ev["subject"])
        if now <= WARMUP_S:
            continue
        for sub in subjects:
            want = positive and sub.split("/")[0] == "s0"
            got = sub in active
            out["tp" if got and want else "fp" if got else "fn" if want else "tn"] += 1
    if positive:
        for sub in subjects:
            if sub.split("/")[0] == "s0" and sub in first:
                out["delay_s"] += first[sub]
                out["delay_n"] += 1
    return out


# ---------------------------------------------------------------------------
# Every case, the document and the check


def score_pack(function, pack, cases=None):
    if function == "fuse":
        out = {}
        for g, cs in (cases or fuse_cases()).items():
            runs = [run_fuse(pack, c) for c in cs]
            out[g] = summarize("fuse", [r for r, _ in runs])
            if g == "random, all faults":
                for b in BREAKDOWN:
                    out["random: " + b] = summarize("fuse", [parts[b] for _, parts in runs])
        return out
    if function == "filter":
        return {"position error %d m" % s: summarize("filter", [run_filter(pack, s, i) for i in range(N_FILTER)])
                for s in FILTER_SIGMAS}
    return {rule: summarize("quality", [run_quality(pack, rule, i) for i in range(N_QUALITY)])
            for rule in FAULTS[pack]}


PACKS = {"fuse": FUSE_PACKS, "filter": FILTER_PACKS, "quality": QUALITY_PACKS}


def run_all():
    cases = fuse_cases()
    return {f: {p: score_pack(f, p, cases if f == "fuse" else None) for p in PACKS[f]} for f in PACKS}


def cell(s, key, f="%.3f"):
    v, ci = s["pooled"].get(key), s["ci95"].get(key)
    if v is None:
        return "–"
    return (f + " (" + f + " to " + f + ")") % (v, ci[0], ci[1]) if ci else f % v


def document(res):
    L = ["# Accuracy of fuse, filter and quality", "",
         "Status: Measured, on the public tuning seeds. Generated by `python3 -I tools/bench/functions.py report`; "
         "do not edit by hand. Correlate is in [benchmark.md](benchmark.md). What every case generates and the "
         "formula of every score: [tools/bench/README.md](../tools/bench/README.md#functions).", "",
         "Every pack runs in the Python engine; the other six engines give the same output on every conformance "
         "vector. Brackets are 95 % bootstrap intervals over scenarios. No held-out set exists for these three "
         "functions.", "",
         "## Fuse", "",
         "The true grouping is given, so these numbers hold the estimate alone and no correlation error. "
         "**Error ratio** is the squared position error over the variance fuse states, per axis: 1 when the stated "
         "error is honest, above 1 when it claims too much. **Inside 95 %** is the share of estimates whose true "
         "position lies in the stated 95 % circle; 0.95 when honest.", "",
         "| Case | Pack | Scenarios | Position error RMS, m | Error ratio | Inside 95 % |", "|---|---|---|---|---|---|"]
    for g in next(iter(res["fuse"].values())):
        for p in FUSE_PACKS:
            s = res["fuse"][p][g]
            L.append("| %s | `%s` | %d | %s | %s | %s |" % (g, p, s["n"], cell(s, "rms_m", "%.1f"),
                                                          cell(s, "nees", "%.2f"), cell(s, "within95")))
    L += ["", "`fuse-priority` ranks the sources `eo-2` and `radar-1`, which no scenario has, so every source ranks "
          "last and ties decide.", "", "## Filter", "",
          "The right decision is the pack's rules applied to the **true** position; the engine sees a position with "
          "the stated error. Tracks start near a boundary, where the error matters. Keep is the positive class.", "",
          "| Pack | Case | Scenarios | F1 | Precision | Recall |", "|---|---|---|---|---|---|"]
    for p in FILTER_PACKS:
        for g, s in res["filter"][p].items():
            L.append("| `%s` | %s | %d | %s | %s | %s |" % (p, g, s["n"], cell(s, "f1"), cell(s, "precision"),
                                                          cell(s, "recall")))
    L += ["", "## Quality", "",
          "One source of four has a fault whose size is drawn on both sides of the line in the second column. Each "
          "tick after the first 90 s, each subject's rule is right when it is active exactly when the fault is past "
          "the line. **Delay** is the mean time from the start of the run to the first activation; three samples and "
          "the rule's tick count are part of it.", "",
          "| Pack and rule | Active is right when | Scenarios | F1 | Precision | Recall | Delay, s |",
          "|---|---|---|---|---|---|---|"]
    for p in QUALITY_PACKS:
        for rule, s in res["quality"][p].items():
            L.append("| `%s` `%s` | %s | %d | %s | %s | %s | %s |" % (
                p, rule, FAULTS[p][rule][2], s["n"], cell(s, "f1"), cell(s, "precision"), cell(s, "recall"),
                cell(s, "delay_s", "%.1f")))
    L += ["", "Rules with no case here (`silent`, `late`, `disorder`, `source-disorder`, `free-running`, "
          "`time-error`) compare one exact value with a limit, so the conformance vectors already settle them.", "",
          "## Not covered", "", "| Pack | Why |", "|---|---|"]
    L += ["| `%s` | %s |" % kv for kv in NOT_COVERED.items()]
    return "\n".join(L) + "\n"


def same(a, b):
    """Equal, with floats compared to 1e-6 relative: platform math libraries differ in the last bit."""
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    if isinstance(a, float) or isinstance(b, float):
        return a is not None and b is not None and math.isclose(a, b, rel_tol=1e-6, abs_tol=1e-9)
    return a == b


def main(argv):
    if argv == ["report"]:
        res = run_all()
        adapters.write_json(RESULTS, res, indent=1)
        with open(DOC, "w", encoding="utf-8") as f:
            f.write(document(res))
    elif argv == ["check"]:
        with open(RESULTS, encoding="utf-8") as f:
            committed = json.load(f)
        with open(DOC, encoding="utf-8") as f:
            doc_ok = f.read() == document(committed)
        ok = same(committed, json.loads(json.dumps(run_all())))
        if not (ok and doc_ok):
            print("not current (%s): run python3 -I tools/bench/functions.py report"
                  % ("results" if not ok else "document"))
            return 1
        print("function results are current")
    elif len(argv) == 3 and argv[0] == "score" and argv[1] in PACKS:
        print(json.dumps(score_pack(argv[1], argv[2]), indent=1))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
