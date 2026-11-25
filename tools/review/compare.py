#!/usr/bin/env python3
"""Score another tracker on the benchmark and compare it with every pack.

    python3 -I tools/bench/bench.py generate --out build/bench/scenarios
    # run your tracker on each build/bench/scenarios/<name>.json and write
    # <name>.events.json into one directory (format: tools/bench/README.md, "Events file")
    python3 -I tools/review/compare.py EVENTS_DIR [--scenarios DIR] [--against PACK ...] [--json]

Every group whose scenarios all have an events file is scored and set against
the packs' committed results on the same scenarios, with the repository's rule:
better or worse only when the 95 % intervals do not overlap. A group with a
missing events file is listed as partial and not compared, since its interval
would come from other scenarios.

The output holds scores only, no positions; it can go into an issue or a pull
request as it is. The path, end to end: reviews/README.md, "Compare your tracker".
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools", "bench"))
sys.path.insert(0, HERE)

import adapters  # noqa: E402
import bench  # noqa: E402
import review  # noqa: E402
import score as scoring  # noqa: E402

DEFAULT_SCENARIOS = os.path.join(ROOT, "build", "bench", "scenarios")
DEFAULT_AGAINST = ["correlate-assign-time", "correlate-gnn", "correlate-window"]


def score_dir(events_dir, scenarios_dir):
    """(name of the engine, metas, {scenario: raw counts or None when no events file})."""
    pairs = bench.load_scenarios(scenarios_dir)
    if not pairs:
        raise review.Refused("no scenarios in %s: run python3 -I tools/bench/bench.py generate --out %s"
                             % (scenarios_dir, scenarios_dir))
    engine, metas, raw = None, [], {}
    for vector, truth in pairs:
        metas.append({"name": truth["name"], "family": truth["family"]})
        path = os.path.join(events_dir, vector["name"] + ".events.json")
        if not os.path.exists(path):
            raw[truth["name"]] = None
            continue
        engine, ticks = adapters.read_events(path)
        raw[truth["name"]] = scoring.score(truth, vector, ticks)
    if engine is None:
        raise review.Refused("no <scenario>.events.json in %s" % events_dir)
    return engine, metas, raw


def compare_dir(events_dir, scenarios_dir, against, base=None):
    engine, metas, raw = score_dir(events_dir, scenarios_dir)
    base = review.base_commit(base)
    # A group's scenarios are the ones the committed results hold, not the ones on disk.
    text = review.git("show", "%s:docs/figures/bench/results.json" % base)
    if text is None:
        raise review.Refused("%s has no docs/figures/bench/results.json" % base[:12])
    canon = bench.groups_of(json.loads(text)["meta"])
    complete = {g for g, names in canon.items() if all(raw.get(n) is not None for n in names)}
    mine = {g: s for g, s in bench.summarize({"x": raw}, metas)["x"].items() if g in complete}
    groups = {g: n for g, n in canon.items() if any(m in raw for m in n)}
    out = {"engine": engine, "base": base, "scored": sum(v is not None for v in raw.values()),
           "scenarios": len(raw), "partial": sorted(set(groups) - complete), "against": {}}
    for pack in against:
        theirs = review.committed("correlate", pack, base)
        cmp = review.compare(theirs, mine)
        out["against"][pack] = {"groups": cmp, **review.outcomes(cmp)}
    return out


def show(res):
    print("%s: %d of %d scenarios scored; base %s" % (res["engine"], res["scored"], res["scenarios"], res["base"][:12]))
    if res["partial"]:
        print("not compared (an events file is missing): %s" % ", ".join(res["partial"]))
    for pack, r in res["against"].items():
        print("\nagainst %s: %d better, %d worse (every other measure: the intervals overlap)"
              % (pack, len(r["better"]), len(r["worse"])))
        for g, d in r["groups"].items():
            f1 = d["measures"].get("f1")
            if f1:
                print("  %-28s F1 %.3f against %.3f" % (g, f1["value"], f1["base_value"]))
        for v in ("better", "worse"):
            for item in r[v]:
                print("  %s: %s" % (v, item))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("events")
    ap.add_argument("--scenarios", default=DEFAULT_SCENARIOS)
    ap.add_argument("--against", nargs="+", default=DEFAULT_AGAINST)
    ap.add_argument("--base")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    try:
        res = compare_dir(a.events, a.scenarios, a.against, a.base)
    except review.Refused as e:
        print("refused: %s" % e, file=sys.stderr)
        return 2
    print(json.dumps(res, indent=1)) if a.json else show(res)
    return 0


if __name__ == "__main__":
    sys.exit(main())
