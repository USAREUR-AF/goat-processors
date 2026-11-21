#!/usr/bin/env python3
"""Correlation benchmark: scenarios with ground truth, engine runs, scores.

Commands (run with `python3 -I`):

  generate [--set tuning|evaluation] --out DIR
                                 write every scenario of a set and its truth file
  run --scenarios DIR --out DIR  run every pack in tools/bench/adapters.py:PACKS
  score --scenarios DIR --events DIR
                                 score the events files in DIR (any engine)
  report [--jobs N] [--timeout S] [--eval]
                                 run every pack on the tuning set and, with --eval, the
                                 evaluation set (benchmark maintainer only: private seeds
                                 and BENCH_EVAL_OWNER); write docs/benchmark.md and
                                 docs/figures/bench/ (results.json and the charts). Without
                                 --eval the last evaluation block is kept as it is
  check                          re-run a short subset of the tuning set and confirm the
                                 committed results and documents are what the tool writes
  diff OLD NEW [--group G]       compare two results files group by group: "better" or
                                 "worse" only where the 95 % intervals separate

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


def cmd_report(jobs=None, timeout=TIMEOUT_S, with_eval=False):
    import report
    t0 = time.monotonic()
    metas, raw, secs = run_parallel(all_scenarios("tuning"), jobs=jobs, timeout=timeout, label="tuning")
    t_tuning = time.monotonic() - t0
    res = results_from(raw, {m["name"]: m["family"] for m in metas})
    res["meta"] = metas
    res["tuning"] = {"groups": summarize(raw, metas), "seconds": round(t_tuning),
                     "jobs": jobs or max(1, (os.cpu_count() or 2) - 2), "timeout_s": timeout}
    old_eval = None
    if os.path.exists(RESULTS):
        with open(RESULTS, encoding="utf-8") as f:
            old_eval = json.load(f).get("evaluation")
    if with_eval:
        evaluation = dataset.evaluation_set()      # refuses without the seeds and BENCH_EVAL_OWNER
        t1 = time.monotonic()
        emetas, eraw, esecs = run_parallel(evaluation, jobs=jobs, timeout=timeout, label="evaluation")
        res["evaluation"] = {"groups": summarize(eraw, emetas), "seconds": round(time.monotonic() - t1),
                             "jobs": res["tuning"]["jobs"], "timeout_s": timeout,
                             "scenarios": len(emetas),
                             "families": sorted(set(m["family"] for m in emetas)),
                             "rotation": dataset.eval_rotation()}
        os.makedirs(EVAL_PRIVATE, exist_ok=True)
        adapters.write_json(os.path.join(EVAL_PRIVATE, "raw.json"),
                            {"meta": emetas, "raw": eraw, "seconds": esecs})
    else:
        res["evaluation"] = old_eval     # keep the last evaluation run (it needs the private seeds)
    adapters.write_json(RESULTS, res)
    report.write_all(res)


def cmd_check():
    import report
    with open(RESULTS, encoding="utf-8") as f:
        committed = json.load(f)
    pairs = list(build(set(QUICK), "tuning"))
    raw = run_all(pairs)
    bad = 0
    for pack, runs in raw.items():
        for name, s in runs.items():
            want = committed["raw"].get(pack, {}).get(name)
            if want is None and name in committed["raw"].get(pack, {}):
                continue        # did not finish in the committed run (scale): nothing to compare
            if want != json.loads(json.dumps(s)):
                print("results differ: %s %s" % (pack, name))
                bad += 1
    bad += report.check_all(committed)
    if bad:
        print("committed results are not current: run python3 -I tools/bench/bench.py report")
        sys.exit(1)
    print("committed results are current (%d runs re-checked)" % sum(len(r) for r in raw.values()))


def cmd_diff(old_path, new_path, which="evaluation", group=None):
    """Group by group and pack: each measure's verdict from the 95 % intervals."""
    old, new = (json.load(open(p, encoding="utf-8"))[which]["groups"] for p in (old_path, new_path))
    rows = 0
    for pack in new:
        for grp in sorted(new[pack]):
            if group and grp != group:
                continue
            a, b = old.get(pack, {}).get(grp), new[pack][grp]
            if not a or not a.get("pooled") or not b.get("pooled"):
                continue
            for m in stats.MEASURES:
                v = stats.verdict(m, a["ci95"].get(m), b["ci95"].get(m))
                if v != "no difference shown":
                    print("%-24s %-28s %-14s %s: %.4g -> %.4g" % (pack, grp, m, v, a["pooled"][m], b["pooled"][m]))
                    rows += 1
    print("%d differences shown (all others: intervals overlap)" % rows)


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
    sub.add_parser("check")
    d = sub.add_parser("diff")
    d.add_argument("old")
    d.add_argument("new")
    d.add_argument("--set", default="evaluation", choices=["tuning", "evaluation"])
    d.add_argument("--group")
    a = ap.parse_args()
    if a.cmd == "generate":
        cmd_generate(a.out, set(a.only) if a.only else None, a.set)
    elif a.cmd == "run":
        run_all(load_scenarios(a.scenarios), out=a.out)
    elif a.cmd == "score":
        cmd_score(a.scenarios, a.events)
    elif a.cmd == "report":
        cmd_report(a.jobs, a.timeout, a.eval and not a.no_eval)
    elif a.cmd == "diff":
        cmd_diff(a.old, a.new, a.set, a.group)
    elif a.cmd == "check":
        cmd_check()


if __name__ == "__main__":
    main()
