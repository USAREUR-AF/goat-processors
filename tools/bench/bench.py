#!/usr/bin/env python3
"""Correlation benchmark: scenarios with ground truth, engine runs, scores.

Commands (run with `python3 -I`):

  generate --out DIR             write every scenario and its truth file
  run --scenarios DIR --out DIR  run every pack in tools/bench/adapters.py:PACKS
  score --scenarios DIR --events DIR
                                 score the events files in DIR (any engine)
  report                         generate, run, score, and write docs/benchmark.md,
                                 docs/figures/bench/ (results.json and the charts)
  check                          re-run a short subset and confirm the committed
                                 results and documents are what the tool writes

See tools/bench/README.md for the formats and every score's formula.
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import adapters  # noqa: E402
import scenarios  # noqa: E402
import score as scoring  # noqa: E402

ROOT = adapters.ROOT
BUILD = os.path.join(ROOT, "build", "bench")
RESULTS = os.path.join(ROOT, "docs", "figures", "bench", "results.json")
# The short subset `check` re-runs: one scenario of each family.
QUICK = ["straight-level", "turn-6dps", "crossing-20deg", "error-understated",
         "number-swap", "false-tracks", "clock-offset-200ms", "random-01", "random-02"]


def all_scenarios():
    return scenarios.named() + scenarios.randomized()


def build(names=None):
    """Yield (vector, truth) for every scenario (or the named ones)."""
    for sc in all_scenarios():
        if names is None or sc.name in names:
            yield sc.build()


def cmd_generate(out, names=None):
    count = 0
    for vector, truth in build(names):
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


def results_from(raw, family):
    """Per pack: derived scores per scenario, pooled over the named set, the random
    set and the time set. `family` maps a scenario name to its family."""
    out = {"packs": list(raw), "scenarios": {}, "raw": raw}
    for pack, runs in raw.items():
        per = {n: scoring.derive(s) for n, s in runs.items()}
        tot = {"named": None, "random": None, "time": None}
        for n, s in runs.items():
            k = OWN_SET.get(family[n], "named")
            tot[k] = s if tot[k] is None else scoring.add(tot[k], s)
        out["scenarios"][pack] = dict(
            {"per": per}, **{k: (scoring.derive(v) if v else None) for k, v in tot.items()})
    return out


def cmd_report():
    import report
    pairs = list(build())
    raw = run_all(pairs)
    res = results_from(raw, {t["name"]: t["family"] for _, t in pairs})
    res["meta"] = [{"name": t["name"], "family": t["family"], "tests": t["tests"],
                    "sensors": t["sensors"], "objects": len(t["objects"]),
                    "reports": sum(1 for s in v["steps"] if "ingest" in s),
                    "false_reports": sum(1 for s, lab in zip(v["steps"], t["labels"])
                                         if "ingest" in s and lab is None)}
                   for v, t in pairs]
    adapters.write_json(RESULTS, res, indent=1)
    report.write_all(res)


def cmd_check():
    import report
    with open(RESULTS, encoding="utf-8") as f:
        committed = json.load(f)
    pairs = list(build(set(QUICK)))
    raw = run_all(pairs)
    bad = 0
    for pack, runs in raw.items():
        for name, s in runs.items():
            want = committed["raw"].get(pack, {}).get(name)
            if want != json.loads(json.dumps(s)):
                print("results differ: %s %s" % (pack, name))
                bad += 1
    bad += report.check_all(committed)
    if bad:
        print("committed results are not current: run python3 -I tools/bench/bench.py report")
        sys.exit(1)
    print("committed results are current (%d runs re-checked)" % sum(len(r) for r in raw.values()))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--out", default=os.path.join(BUILD, "scenarios"))
    g.add_argument("--only", nargs="*")
    r = sub.add_parser("run")
    r.add_argument("--scenarios", default=os.path.join(BUILD, "scenarios"))
    r.add_argument("--out", default=os.path.join(BUILD, "events"))
    s = sub.add_parser("score")
    s.add_argument("--scenarios", default=os.path.join(BUILD, "scenarios"))
    s.add_argument("--events", required=True)
    sub.add_parser("report")
    sub.add_parser("check")
    a = ap.parse_args()
    if a.cmd == "generate":
        cmd_generate(a.out, set(a.only) if a.only else None)
    elif a.cmd == "run":
        run_all(load_scenarios(a.scenarios), out=a.out)
    elif a.cmd == "score":
        cmd_score(a.scenarios, a.events)
    elif a.cmd == "report":
        cmd_report()
    elif a.cmd == "check":
        cmd_check()


if __name__ == "__main__":
    main()
