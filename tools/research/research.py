#!/usr/bin/env python3
"""Research harness: score and time prototype methods (README.md).

  run VARIANT [VARIANT ...] [--set bench|holdout|all] [--jobs N]
        run each variant on the scenarios, score with tools/bench/score.py,
        write build/research/<set>/<variant>.json
  compare BASE VARIANT [--set bench|holdout|all] [--boot N]
        pooled measures per set, the named weaknesses, and the paired
        bootstrap noise of each pooled difference
  perf VARIANT [VARIANT ...] [--repeats N]
        reports per second on the tools/perf large scenario

Run with python3 -I. Standard library only.
"""

import argparse
import json
import multiprocessing
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools", "bench"))
sys.path.insert(0, os.path.join(ROOT, "tools", "perf"))

import adapters  # noqa: E402
import scenarios  # noqa: E402
import score as scoring  # noqa: E402
import variants  # noqa: E402

OUT = os.path.join(ROOT, "build", "research")
# A second random set, never used to choose a parameter: the held-out check.
HOLDOUT_SEED = 20261120
MEASURES = [("f1", "F1", 1), ("precision", "precision", 1), ("recall", "recall", 1),
            ("false_merges", "false merges", -1), ("missed_merges", "missed merges", -1),
            ("swaps", "identity swaps", -1), ("tta_s", "time to associate s", -1),
            ("rms_m", "position RMS m", -1), ("gospa_m", "GOSPA m", -1)]
WEAK = [("random-17", "f1"), ("random-28", "f1"), ("number-drop", "f1"), ("number-drop", "tta_s")]


def scenario_list(which):
    sc = []
    if which in ("bench", "all"):
        sc += scenarios.named() + scenarios.randomized()
    if which in ("holdout", "all"):
        for s in scenarios.randomized(seed=HOLDOUT_SEED):
            s.name = "holdout-" + s.name[len("random-"):]
            s.family = "holdout"
            sc.append(s)
    return sc


def make(variant):
    pack_name, cls, opt = variants.VARIANTS[variant]
    pack = adapters.load_pack(os.path.join(ROOT, "packs", pack_name))
    if cls is None:
        return pack, adapters.make_engine(pack)
    return pack, cls(pack, **opt)


def run_one(variant, vector):
    """The events of one variant over one scenario (tools/bench/adapters.py, run_pack)."""
    pack, eng = make(variant)
    ticks = {}
    for step in vector["steps"]:
        if "ingest" in step:
            eng.ingest(step["ingest"])
            continue
        now = step["tick"]
        events, _ = eng.tick(now)
        if pack.method == "assign":
            tracks = [adapters._track(ev["system"], ev) for ev in events if ev.get("ev") == "system"]
        else:
            tracks = [adapters._track(ev["group"], ev) for ev in events if ev.get("ev") == "fused"]
            tracks.extend(adapters._ungrouped(eng, now))
        ticks[now] = json.loads(json.dumps(tracks))
    return ticks


def _job(arg):
    variant, sc = arg
    vector, truth = sc.build()
    t0 = time.perf_counter()
    ticks = run_one(variant, vector)
    dt = time.perf_counter() - t0
    return variant, vector["name"], truth["family"], scoring.score(truth, vector, ticks), dt


def cmd_run(names, which, jobs):
    scs = scenario_list(which)
    work = [(v, s) for v in names for s in scs]
    # Long scenarios first, so the pool ends together.
    work.sort(key=lambda w: -w[1].duration_s)
    res = {v: {"raw": {}, "family": {}, "seconds": 0.0} for v in names}
    with multiprocessing.Pool(jobs) as pool:
        for v, name, fam, raw, dt in pool.imap_unordered(_job, work):
            res[v]["raw"][name] = raw
            res[v]["family"][name] = fam
            res[v]["seconds"] += dt
    for v in names:
        path = os.path.join(OUT, which, v + ".json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(res[v], f, sort_keys=True)
        print("%-28s %3d scenarios, engine %.1f s -> %s" % (v, len(res[v]["raw"]), res[v]["seconds"], path))


SETS = {"named": lambda fam: fam not in ("random", "time", "holdout"),
        "random": lambda fam: fam == "random", "time": lambda fam: fam == "time",
        "holdout": lambda fam: fam == "holdout"}


def pooled(res, names):
    tot = None
    for n in names:
        tot = res["raw"][n] if tot is None else scoring.add(tot, res["raw"][n])
    return scoring.derive(tot)


def load(variant, which):
    with open(os.path.join(OUT, which, variant + ".json"), encoding="utf-8") as f:
        return json.load(f)


class Lcg:
    """A small seeded generator for the bootstrap (splitmix64)."""
    def __init__(self, seed):
        self.s = seed

    def below(self, n):
        self.s = (self.s + 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
        z = self.s
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & 0xFFFFFFFFFFFFFFFF
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & 0xFFFFFFFFFFFFFFFF
        return (z ^ (z >> 31)) % n


def compare(base, var, which, boot):
    a, b = load(base, which), load(var, which)
    out = {}
    for set_name, keep in SETS.items():
        names = sorted(n for n, fam in a["family"].items() if keep(fam) and n in b["raw"])
        if not names:
            continue
        pa, pb = pooled(a, names), pooled(b, names)
        # Paired bootstrap over scenarios: the spread of the pooled difference
        # when the set of scenarios is drawn again. 2.5 % and 97.5 % points.
        rng = Lcg(len(names) * 7919 + 1)
        diffs = {m: [] for m, _, _ in MEASURES}
        for _ in range(boot):
            pick = [names[rng.below(len(names))] for _ in names]
            da, db = pooled(a, pick), pooled(b, pick)
            for m, _, _ in MEASURES:
                if da[m] is not None and db[m] is not None:
                    diffs[m].append(db[m] - da[m])
        rows = []
        for m, label, sign in MEASURES:
            d = sorted(diffs[m])
            lo = d[int(0.025 * len(d))] if d else None
            hi = d[min(len(d) - 1, int(0.975 * len(d)))] if d else None
            rows.append({"measure": m, "label": label, "base": pa[m], "variant": pb[m],
                         "diff": None if pa[m] is None or pb[m] is None else pb[m] - pa[m],
                         "lo": lo, "hi": hi, "better": sign})
        out[set_name] = {"n": len(names), "rows": rows}
    weak = []
    for n, m in WEAK:
        if n in a["raw"] and n in b["raw"]:
            weak.append({"scenario": n, "measure": m, "base": scoring.derive(a["raw"][n])[m],
                         "variant": scoring.derive(b["raw"][n])[m]})
    return {"base": base, "variant": var, "sets": out, "weak": weak,
            "seconds": {"base": a["seconds"], "variant": b["seconds"]}}


def fmt(x):
    if x is None:
        return "-"
    if isinstance(x, int) or float(x).is_integer() and abs(x) >= 1:
        return "%d" % x
    return "%.3f" % x if abs(x) < 10 else "%.1f" % x


def cmd_compare(base, var, which, boot, as_json):
    c = compare(base, var, which, boot)
    if as_json:
        print(json.dumps(c, indent=1))
        return
    print("%s -> %s (engine time %.0f s -> %.0f s)" % (base, var, c["seconds"]["base"], c["seconds"]["variant"]))
    for set_name, s in c["sets"].items():
        print("\n%s (%d scenarios)" % (set_name, s["n"]))
        for r in s["rows"]:
            flag = ""
            if r["diff"] is not None and r["lo"] is not None:
                if r["lo"] > 0 or r["hi"] < 0:
                    flag = "better" if (r["diff"] > 0) == (r["better"] > 0) else "WORSE"
                elif r["diff"] != 0:
                    flag = "noise"
            print("  %-22s %8s %8s  diff %8s  95%% [%s, %s]  %s" % (
                r["label"], fmt(r["base"]), fmt(r["variant"]), fmt(r["diff"]), fmt(r["lo"]), fmt(r["hi"]), flag))
    print("\nnamed weaknesses")
    for w in c["weak"]:
        print("  %-12s %-6s %8s -> %8s" % (w["scenario"], w["measure"], fmt(w["base"]), fmt(w["variant"])))


def cmd_perf(names, repeats, size):
    """Repeats are interleaved (every variant once, then again), so a change in
    the machine's load falls on every variant alike. Each line gives the
    median time and the median of the per-repeat ratio to the first variant."""
    import scenario as perf_scenario
    steps = perf_scenario.build(size)[0]
    n_ing = sum(1 for s in steps if "ingest" in s)
    times = {v: [] for v in names}
    for _ in range(repeats):
        for v in names:
            _, eng = make(v)
            t0 = time.perf_counter()
            for st in steps:
                if "ingest" in st:
                    eng.ingest(st["ingest"])
                else:
                    eng.tick(st["tick"])
            eng.snapshot()
            times[v].append(time.perf_counter() - t0)
    base = times[names[0]]
    print("%s scenario, %d reports, %d repeats, interleaved" % (size, n_ing, repeats))
    for v in names:
        t = sorted(times[v])
        med = t[len(t) // 2]
        ratios = sorted(x / b for x, b in zip(times[v], base))
        print("%-28s %8.1f s median, %8.0f reports/s, range %.1f-%.1f s, ratio to %s %.3f" % (
            v, med, n_ing / med, t[0], t[-1], names[0], ratios[len(ratios) // 2]))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("variants", nargs="+")
    r.add_argument("--set", default="bench", choices=["bench", "holdout", "all"])
    r.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    c = sub.add_parser("compare")
    c.add_argument("base")
    c.add_argument("variant")
    c.add_argument("--set", default="bench", choices=["bench", "holdout", "all"])
    c.add_argument("--boot", type=int, default=1000)
    c.add_argument("--json", action="store_true")
    p = sub.add_parser("perf")
    p.add_argument("variants", nargs="+")
    p.add_argument("--repeats", type=int, default=3)
    p.add_argument("--size", default="large", choices=["large", "smoke"])
    a = ap.parse_args()
    for v in getattr(a, "variants", []) + [getattr(a, "base", None), getattr(a, "variant", None)]:
        if v is not None and v not in variants.VARIANTS:
            raise SystemExit("unknown variant %s; known: %s" % (v, ", ".join(variants.VARIANTS)))
    if a.cmd == "run":
        cmd_run(a.variants, a.set, a.jobs)
    elif a.cmd == "compare":
        cmd_compare(a.base, a.variant, a.set, a.boot, a.json)
    elif a.cmd == "perf":
        cmd_perf(a.variants, a.repeats, a.size)


if __name__ == "__main__":
    main()
