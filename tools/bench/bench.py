#!/usr/bin/env python3
"""Correlation benchmark: scenarios with ground truth, engine runs, scores.

Commands (run with `python3 -I`):

  generate [--set tuning|evaluation] --out DIR
                                 write every scenario of a set and its truth file
  run --scenarios DIR --out DIR  run every pack in tools/bench/adapters.py:PACKS
  score --scenarios DIR --events DIR
                                 score the events files in DIR (any engine)
  report [--jobs N] [--timeout S] [--eval] [--baselines]
                                 run every pack on the tuning set and, with --eval, the
                                 evaluation set (benchmark maintainer only: private seeds
                                 and BENCH_EVAL_OWNER); with --baselines also the outside
                                 baselines of tools/baselines (needs its requirements.txt);
                                 write docs/benchmark.md and docs/figures/bench/ (results.json,
                                 the per-scenario CSV and the charts). Without --eval (or
                                 --baselines) the last evaluation (baseline) results are kept
  check [--baselines]            re-run a short subset of the tuning set and confirm the
                                 committed results and documents are what the tool writes
  diff OLD NEW [--group G] [--set S] [--old-raw F --new-raw F]
                                 compare two results files group by group with the paired
                                 bootstrap: "better" or "worse" only where the interval of
                                 the difference excludes zero. The evaluation set needs the
                                 maintainer's private per-scenario files (--old-raw, --new-raw)

The two sets and their seeds: tools/bench/dataset.py.

See tools/bench/README.md for the formats and every score's formula.
"""

import argparse
import json
import os
import signal
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import adapters  # noqa: E402
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "baselines"))
import dataset  # noqa: E402
import scenarios  # noqa: E402
import score as scoring  # noqa: E402
import stats  # noqa: E402

ROOT = adapters.ROOT
BUILD = os.path.join(ROOT, "build", "bench")
RESULTS = os.path.join(ROOT, "docs", "figures", "bench", "results.json")
# The evaluation set's per-scenario results stay private (they would let a pack be tuned to it).
EVAL_PRIVATE = os.path.expanduser("~/re/bench-eval-results")
# The short subset `check` re-runs: one scenario of each tuning family (not scale).
QUICK = ["straight-level", "turn-6dps", "crossing-20deg", "error-understated",
         "number-swap", "false-tracks", "clock-offset-200ms", "random-01", "random-02",
         "formation-01", "crossing-01", "maneuver-01", "sensor-problems-01", "clutter-01",
         "mixed-domains-01", "track-management-01"]
TIMEOUT_S = 300         # per pack and scenario; a run past it is reported as not finished
SPLIT_OBJECTS = 20      # above this, a scenario's packs run as separate jobs
BASELINE_TIMEOUT_FACTOR = 4   # an outside baseline's speed is not what is measured: it gets 4 times the limit


def all_scenarios(which="tuning"):
    return dataset.SETS[which]()


def build(names=None, which="tuning"):
    """Yield (vector, truth) for every scenario of a set (or the named ones)."""
    for sc in all_scenarios(which):
        if names is None or sc.name in names:
            yield sc.build()


def cmd_generate(out, names=None, which="tuning"):
    count = 0
    for vector, truth in build(names, which):
        adapters.write_json(os.path.join(out, vector["name"] + ".json"), vector)
        adapters.write_json(os.path.join(out, vector["name"] + ".truth.json"), truth)
        count += 1
    print("wrote %d scenarios to %s" % (count, out))


def load_scenarios(directory):
    out = []
    for f in sorted(os.listdir(directory)):
        if f.endswith(".truth.json"):
            name = f[: -len(".truth.json")]
            with open(os.path.join(directory, name + ".json"), encoding="utf-8") as fv:
                vector = json.load(fv)
            with open(os.path.join(directory, f), encoding="utf-8") as ft:
                truth = json.load(ft)
            out.append((vector, truth))
    return out


def run_all(pairs, packs=None, out=None):
    """Run every pack on every scenario; return {pack: {scenario: raw counts}}."""
    raw = {}
    for pack in packs or adapters.PACKS:
        raw[pack] = {}
        for vector, truth in pairs:
            ev = adapters.run_pack(pack, vector)
            if out:
                adapters.write_json(os.path.join(out, pack, vector["name"] + ".events.json"), ev)
            ticks = {t["now_ms"]: t["tracks"] for t in ev["ticks"]}
            raw[pack][vector["name"]] = scoring.score(truth, vector, ticks)
        print("ran %s on %d scenarios" % (pack, len(pairs)), file=sys.stderr)
    return raw


class _Timeout(Exception):
    pass


def _alarm(signum, frame):
    raise _Timeout()


def _run_scenario(job):
    """Worker: build one scenario, run every pack on it with a time limit each."""
    sc, packs, timeout = job
    vector, truth = sc.build()
    meta = {"name": truth["name"], "family": truth["family"], "tests": truth["tests"],
            "sensors": truth["sensors"], "objects": len(truth["objects"]),
            "reports": sum(1 for s in vector["steps"] if "ingest" in s),
            "false_reports": sum(1 for s, lab in zip(vector["steps"], truth["labels"])
                                 if "ingest" in s and lab is None)}
    out = {}
    signal.signal(signal.SIGALRM, _alarm)
    for pack in packs:
        t0 = time.monotonic()
        signal.alarm(timeout)
        try:
            ev = adapters.run_pack(pack, vector)
            ticks = {t["now_ms"]: t["tracks"] for t in ev["ticks"]}
            out[pack] = scoring.score(truth, vector, ticks)
        except _Timeout:
            out[pack] = None
        finally:
            signal.alarm(0)
        out.setdefault("_seconds", {})[pack] = round(time.monotonic() - t0, 3)
    return meta, out


def run_parallel(scs, packs=None, jobs=None, timeout=TIMEOUT_S, label=""):
    """Run every pack on every scenario in `jobs` processes.
    Returns (metas, {pack: {scenario: raw or None}}, {pack: {scenario: seconds}})."""
    import multiprocessing as mp
    packs = list(packs or adapters.PACKS)
    jobs = jobs or max(1, (os.cpu_count() or 2) - 2)
    raw = {p: {} for p in packs}
    secs = {p: {} for p in packs}
    metas = []
    # Largest first, so the long scenarios do not finish last on one worker. A scenario with
    # more than SPLIT_OBJECTS objects runs as one job per pack, so its packs run side by side.
    order = sorted(scs, key=lambda sc: -len(sc.objects) * sc.duration_s)
    work = []
    for sc in order:
        if len(sc.objects) > SPLIT_OBJECTS:
            work += [(sc, [p], timeout) for p in packs]
        else:
            work.append((sc, packs, timeout))
    seen = set()
    with mp.get_context("fork").Pool(jobs) as pool:
        for meta, out in pool.imap_unordered(_run_scenario, work):
            if meta["name"] not in seen:
                seen.add(meta["name"])
                metas.append(meta)
                if len(seen) % 50 == 0:
                    print("%s: %d of %d scenarios" % (label, len(seen), len(order)), file=sys.stderr, flush=True)
            for p in out:
                if p == "_seconds":
                    continue
                raw[p][meta["name"]] = out[p]
                secs[p][meta["name"]] = out["_seconds"][p]
    names = [sc.name for sc in scs]
    metas.sort(key=lambda m: names.index(m["name"]))
    return metas, raw, secs


def cmd_score(scen_dir, events_dir):
    pairs = load_scenarios(scen_dir)
    total, engine, rows = None, None, []
    for vector, truth in pairs:
        path = os.path.join(events_dir, vector["name"] + ".events.json")
        if not os.path.exists(path):
            print("%-22s no events file" % vector["name"])
            continue
        engine, ticks = adapters.read_events(path)
        s = scoring.score(truth, vector, ticks)
        rows.append((vector["name"], s))
        total = s if total is None else scoring.add(total, s)
    result = {"engine": engine, "scenarios": {n: scoring.derive(s) for n, s in rows},
              "raw": {n: s for n, s in rows}}
    if total is not None:
        result["all"] = scoring.derive(total)
    print(json.dumps(result, indent=1))


# Families pooled as a set of their own instead of with the named set.
OWN_SET = {"random": "random", "time": "time"}
_NAMED = []


def named_names():
    """The 21 named and 7 time scenarios (scenarios.named()): the earlier named set."""
    if not _NAMED:
        _NAMED.extend(sc.name for sc in scenarios.named())
    return set(_NAMED)


def groups_of(metas):
    """{group: [scenario names]}: the random set, the time set, the 21 named, and each family."""
    g = {}
    for m in metas:
        fam, name = m["family"], m["name"]
        if fam == "random":
            g.setdefault("random", []).append(name)
        elif fam == "time":
            g.setdefault("time", []).append(name)
        elif name in named_names():
            g.setdefault("named", []).append(name)
        else:
            g.setdefault("family: " + fam, []).append(name)
    return g


def summarize(raw, metas):
    """Per pack and group: pooled measures, 95 % intervals, scenarios run and not finished."""
    out = {}
    for pack, runs in raw.items():
        out[pack] = {}
        for grp, names in groups_of(metas).items():
            done = [runs[n] for n in names if runs.get(n) is not None]
            out[pack][grp] = dict(stats.summary(done), not_finished=len(names) - len(done))
    return out


# The measures compared pack against pack (stats.paired); the rest are context.
PAIRED = ["f1", "idf1", "completeness", "ambiguity", "spuriousness", "longest_segment", "false_merges",
          "missed_merges", "swaps", "gospa_m"]


def paired_groups(raw, metas, measures=PAIRED):
    """Per group: every pair of packs compared on the scenarios both of them finished.

    {group: {"gain": {B: {A: {measure: [lo, hi]}}}, "n": {B: {A: scenarios}}}} for each B
    after A in raw's order: the 95 % interval of how much better B is than A (positive is
    better), and how many scenarios it rests on."""
    packs = list(raw)
    out = {}
    for grp, names in groups_of(metas).items():
        cache = {}

        def values(p, common):
            key = (p, tuple(common))
            if key not in cache:
                cache[key] = stats.resampled([raw[p][n] for n in common], stats.draws(len(common)), measures)
            return cache[key]

        gain, count = {}, {}
        for j, b in enumerate(packs):
            for a in packs[:j]:
                common = [n for n in names if raw[a].get(n) is not None and raw[b].get(n) is not None]
                if not common:
                    continue
                va, vb = values(a, common), values(b, common)
                gain.setdefault(b, {})[a] = {m: stats.paired_from(va[m], vb[m], m) for m in measures}
                count.setdefault(b, {})[a] = len(common)
        out[grp] = {"gain": gain, "n": count}
    return out


def gain_of(paired_group, a, b, m):
    """Interval of how much better b is than a, from paired_groups' output (None when absent)."""
    g = paired_group["gain"]
    if b in g and a in g[b]:
        return g[b][a].get(m)
    if a in g and b in g[a]:
        ci = g[a][b].get(m)
        return [-ci[1], -ci[0]] if ci else None
    return None


def _run_baseline(job):
    sc, name, timeout = job
    vector, truth = sc.build()
    import baselines
    signal.signal(signal.SIGALRM, _alarm)
    t0 = time.monotonic()
    signal.alarm(timeout)
    try:
        ev = baselines.run(name, vector)
        ticks = {t["now_ms"]: t["tracks"] for t in ev["ticks"]}
        out = scoring.score(truth, vector, ticks)
    except _Timeout:
        out = None
    finally:
        signal.alarm(0)
    return truth["name"], out, round(time.monotonic() - t0, 3)


def run_baselines(scs, jobs=None, timeout=TIMEOUT_S, label=""):
    """Run every outside baseline on every scenario: ({name: {scenario: raw or None}}, seconds)."""
    import multiprocessing as mp
    import baselines
    baselines.require()
    jobs = jobs or max(1, (os.cpu_count() or 2) - 2)
    timeout = timeout * BASELINE_TIMEOUT_FACTOR
    raw = {b: {} for b in baselines.NAMES}
    secs = {b: {} for b in baselines.NAMES}
    work = [(sc, b, timeout) for b in baselines.NAMES
            for sc in sorted(scs, key=lambda sc: -len(sc.objects) * sc.duration_s)]
    with mp.get_context("fork").Pool(jobs) as pool:
        for k, (job, res) in enumerate(zip(work, pool.imap(_run_baseline, work))):
            name, out, sec = res
            raw[job[1]][name] = out
            secs[job[1]][name] = sec
            if (k + 1) % 100 == 0:
                print("%s: %d of %d baseline runs" % (label, k + 1, len(work)), file=sys.stderr, flush=True)
    return raw, secs


def results_from(raw, family):
    """Per pack: derived scores per scenario, pooled over the named set, the random
    set and the time set. `family` maps a scenario name to its family."""
    out = {"packs": list(raw), "scenarios": {}, "raw": raw}
    for pack, runs in raw.items():
        per = {n: scoring.derive(s) for n, s in runs.items() if s is not None}
        tot = {"named": None, "random": None, "time": None}
        for n, s in runs.items():
            if s is None or (family[n] not in OWN_SET and n not in named_names()):
                continue
            k = OWN_SET.get(family[n], "named")
            tot[k] = s if tot[k] is None else scoring.add(tot[k], s)
        out["scenarios"][pack] = dict(
            {"per": per}, **{k: (scoring.derive(v) if v else None) for k, v in tot.items()})
    return out


def cmd_report(jobs=None, timeout=TIMEOUT_S, with_eval=False, with_baselines=False):
    import report
    old = {}
    if os.path.exists(RESULTS):
        with open(RESULTS, encoding="utf-8") as f:
            old = json.load(f)
    jobs = jobs or max(1, (os.cpu_count() or 2) - 2)
    t0 = time.monotonic()
    tuning = all_scenarios("tuning")
    metas, raw, secs = run_parallel(tuning, jobs=jobs, timeout=timeout, label="tuning")
    t_tuning = time.monotonic() - t0
    res = results_from(raw, {m["name"]: m["family"] for m in metas})
    res["meta"] = metas
    if with_baselines:
        braw, _ = run_baselines(tuning, jobs=jobs, timeout=timeout, label="tuning")
    else:
        braw = {b: r for b, r in (old.get("baseline_raw") or {}).items()}
        if braw and set(next(iter(braw.values()))) != set(m["name"] for m in metas):
            braw = {}                    # the set changed: the old baseline runs no longer cover it
    res["baselines"] = list(braw)
    res["baseline_raw"] = braw
    both = dict(raw, **braw)
    res["tuning"] = {"groups": summarize(both, metas), "paired": paired_groups(both, metas),
                     "seconds": round(t_tuning), "jobs": jobs, "timeout_s": timeout}
    if with_eval:
        evaluation = dataset.evaluation_set()      # refuses without the seeds and BENCH_EVAL_OWNER
        t1 = time.monotonic()
        emetas, eraw, esecs = run_parallel(evaluation, jobs=jobs, timeout=timeout, label="evaluation")
        seconds = round(time.monotonic() - t1)
        if with_baselines:
            ebraw, ebsecs = run_baselines(evaluation, jobs=jobs, timeout=timeout, label="evaluation")
        else:
            ebraw, ebsecs = {}, {}
            prev = os.path.join(EVAL_PRIVATE, "raw.json")
            if os.path.exists(prev):
                with open(prev, encoding="utf-8") as f:
                    p = json.load(f)
                if set(m["name"] for m in p["meta"]) == set(m["name"] for m in emetas):
                    ebraw = {b: p["raw"][b] for b in p.get("baselines", []) if b in p["raw"]}
        eboth = dict(eraw, **ebraw)
        res["evaluation"] = {"groups": summarize(eboth, emetas), "paired": paired_groups(eboth, emetas),
                             "seconds": seconds, "jobs": jobs, "timeout_s": timeout,
                             "scenarios": len(emetas),
                             "families": sorted(set(m["family"] for m in emetas)),
                             "rotation": dataset.eval_rotation(), "baselines": list(ebraw)}
        os.makedirs(EVAL_PRIVATE, exist_ok=True)
        adapters.write_json(os.path.join(EVAL_PRIVATE, "raw.json"),
                            {"meta": emetas, "raw": eboth, "baselines": list(ebraw),
                             "seconds": dict(esecs, **ebsecs)})
    else:
        res["evaluation"] = old.get("evaluation")   # keep the last evaluation run (it needs the private seeds)
    adapters.write_json(RESULTS, res)
    report.write_all(res)


def _same(a, b):
    """Raw counts equal: integers exactly, floats to 1e-9 relative (the last bits may differ
    between machines and library builds)."""
    if a is None or b is None or set(a) != set(b):
        return a == b
    return all(a[k] == b[k] if isinstance(a[k], int) and isinstance(b[k], int)
               else abs(a[k] - b[k]) <= 1e-9 * max(1.0, abs(a[k]), abs(b[k])) for k in a)


def cmd_check(with_baselines=False):
    import report
    with open(RESULTS, encoding="utf-8") as f:
        committed = json.load(f)
    pairs = list(build(set(QUICK), "tuning"))
    raw = run_all(pairs)
    if with_baselines:
        import baselines
        baselines.require()
        for b in baselines.NAMES:
            raw[b] = {}
            for vector, truth in pairs:
                ev = baselines.run(b, vector)
                raw[b][vector["name"]] = scoring.score(truth, vector, {t["now_ms"]: t["tracks"] for t in ev["ticks"]})
    bad = 0
    for pack, runs in raw.items():
        src = committed["raw"] if pack in committed["raw"] else committed.get("baseline_raw", {})
        for name, s in runs.items():
            want = src.get(pack, {}).get(name)
            if want is None and name in src.get(pack, {}):
                continue        # did not finish in the committed run: nothing to compare
            if not _same(want, json.loads(json.dumps(s))):
                print("results differ: %s %s" % (pack, name))
                bad += 1
    bad += report.check_all(committed)
    if bad:
        print("committed results are not current: run python3 -I tools/bench/bench.py report")
        sys.exit(1)
    print("committed results are current (%d runs re-checked)" % sum(len(r) for r in raw.values()))


def _raw_of(path, which, raw_path):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    if which == "tuning":
        return doc["meta"], dict(doc["raw"], **(doc.get("baseline_raw") or {}))
    if not raw_path:
        raise SystemExit("the evaluation set's per-scenario results are private: pass --old-raw and --new-raw "
                         "(the maintainer's %s/raw.json of each run)" % EVAL_PRIVATE)
    with open(raw_path, encoding="utf-8") as f:
        doc = json.load(f)
    return doc["meta"], doc["raw"]


def cmd_diff(old_path, new_path, which="evaluation", group=None, old_raw=None, new_raw=None):
    """Group by group and pack: each measure's paired verdict, new against old."""
    ometa, old = _raw_of(old_path, which, old_raw)
    nmeta, new = _raw_of(new_path, which, new_raw)
    onames = set(m["name"] for m in ometa)
    rows = 0
    for pack in new:
        if pack not in old:
            continue
        for grp, names in sorted(groups_of(nmeta).items()):
            if group and grp != group:
                continue
            common = [n for n in names if n in onames and old[pack].get(n) is not None
                      and new[pack].get(n) is not None]
            if not common:
                continue
            a, b = [old[pack][n] for n in common], [new[pack][n] for n in common]
            pa, pb = stats.pooled(a), stats.pooled(b)
            for m, ci in stats.paired(a, b, measures=PAIRED).items():
                v = stats.verdict(ci)
                if v != "no difference shown":
                    print("%-24s %-28s %-16s %s: %.4g -> %.4g" % (pack, grp, m, v, pa[m], pb[m]))
                    rows += 1
    print("%d differences shown (every other measure: the interval of the difference includes zero)" % rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--out", default=os.path.join(BUILD, "scenarios"))
    g.add_argument("--only", nargs="*")
    g.add_argument("--set", default="tuning", choices=sorted(dataset.SETS))
    r = sub.add_parser("run")
    r.add_argument("--scenarios", default=os.path.join(BUILD, "scenarios"))
    r.add_argument("--out", default=os.path.join(BUILD, "events"))
    s = sub.add_parser("score")
    s.add_argument("--scenarios", default=os.path.join(BUILD, "scenarios"))
    s.add_argument("--events", required=True)
    rp = sub.add_parser("report")
    rp.add_argument("--jobs", type=int)
    rp.add_argument("--timeout", type=int, default=TIMEOUT_S)
    rp.add_argument("--eval", action="store_true",
                    help="also run the evaluation set (benchmark maintainer only)")
    rp.add_argument("--no-eval", action="store_true", help="the default; kept for older scripts")
    rp.add_argument("--baselines", action="store_true",
                    help="also run the outside baselines (pip install -r tools/baselines/requirements.txt)")
    ck = sub.add_parser("check")
    ck.add_argument("--baselines", action="store_true")
    d = sub.add_parser("diff")
    d.add_argument("old")
    d.add_argument("new")
    d.add_argument("--set", default="evaluation", choices=["tuning", "evaluation"])
    d.add_argument("--group")
    d.add_argument("--old-raw")
    d.add_argument("--new-raw")
    a = ap.parse_args()
    if a.cmd == "generate":
        cmd_generate(a.out, set(a.only) if a.only else None, a.set)
    elif a.cmd == "run":
        run_all(load_scenarios(a.scenarios), out=a.out)
    elif a.cmd == "score":
        cmd_score(a.scenarios, a.events)
    elif a.cmd == "report":
        cmd_report(a.jobs, a.timeout, a.eval and not a.no_eval, a.baselines)
    elif a.cmd == "diff":
        cmd_diff(a.old, a.new, a.set, a.group, a.old_raw, a.new_raw)
    elif a.cmd == "check":
        cmd_check(a.baselines)


if __name__ == "__main__":
    main()
