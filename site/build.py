#!/usr/bin/env python3
"""Prepare site/ for publishing and check its numbers. Standard library only.

    python3 -I site/build.py

1. Copies the files the page shows from the tree into site/assets/from-tree/
   (git-ignored): the figures that docs/figures/make-figures.py writes, and the
   vector the hero replays. The page never carries its own copy of them.
2. Measures the four numbers in the strip under the hero, and the benchmark
   row, from the tree, and fails if site/index.html states anything else.
3. Checks each agent interface status on the page (data-status) against
   tools/readme/agentic.json, the file the README's agent section is written from.
4. Runs site/fitcheck.py: in headless Chrome at 1440 and 390 px, no command box
   is cut off, and no output box at 1440 px.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
OUT = os.path.join(SITE, "assets", "from-tree")

FIGURES = [
    "docs/figures/processing-layer-light.svg", "docs/figures/processing-layer-dark.svg",
    "docs/figures/correlate-decision-light.svg", "docs/figures/correlate-decision-dark.svg",
    "docs/figures/seven-engines-light.svg", "docs/figures/seven-engines-dark.svg",
    "docs/figures/bench/random-light.svg", "docs/figures/bench/random-dark.svg",
    "docs/explainers/correlation-steps-light.svg", "docs/explainers/correlation-steps-dark.svg",
    "docs/explainers/what-goat-adds-light.svg", "docs/explainers/what-goat-adds-dark.svg",
]
HERO_VECTOR = "packs/correlate-gnn/vectors/04-separation-dissolves.json"


def bench_numbers(pack="correlate-assign-time"):
    """The evaluation set's random scenarios, from docs/figures/bench/results.json: pack's F1 with its
    95 % interval, its IDF1 and GOSPA, the packs level with it on F1 by the paired test, and the
    outside baseline's F1."""
    with open(os.path.join(ROOT, "docs/figures/bench/results.json")) as f:
        ev = json.load(f)["evaluation"]
    g, paired = ev["groups"], (ev.get("paired") or {}).get("random", {}).get("gain", {})
    r = g[pack]["random"]
    v, (lo, hi) = r["pooled"]["f1"], r["ci95"]["f1"]

    def gain(a, b):                       # how much better b is than a, 95 % interval
        if b in paired and a in paired[b]:
            return paired[b][a]["f1"]
        c = paired.get(a, {}).get(b, {}).get("f1")
        return [-c[1], -c[0]] if c else None

    base = ev.get("baselines") or []
    ties = [p[len("correlate-"):] for p in g if p != pack and p not in base and gain(pack, p)
            and gain(pack, p)[0] <= 0 <= gain(pack, p)[1]]
    out = {"f1-random": f"{v:.3f} ({lo:.3f} to {hi:.3f})",
           "idf1-random": f"{r['pooled']['idf1']:.3f}",
           "gospa-random": f"{r['pooled']['gospa_m']:.0f}",
           "f1-ties": " and ".join(ties) if ties else "no other pack"}
    for b in base:
        out["baseline-f1"] = f"{g[b]['random']['pooled']['f1']:.3f}"
    return out


def measure():
    vectors = sorted(glob.glob(os.path.join(ROOT, "packs/*/vectors/*.json")))
    traces = 0
    for path in vectors:
        with open(path) as f:
            traces += sum(len(s.get("trace", [])) for s in json.load(f)["steps"])
    engines = [d for d in os.listdir(os.path.join(ROOT, "engines"))
               if os.path.isdir(os.path.join(ROOT, "engines", d))]
    return dict({
        "engines": f"{len(engines)}",
        "vectors": f"{len(vectors)}",
        "traces": f"{traces:,}",
        "packs": f"{len(glob.glob(os.path.join(ROOT, 'packs/*/pack.def')))}",
    }, **bench_numbers())


ORDER = ["Designed", "Written", "Built"]


def check_agentic(page):
    """Each data-status element must show the least-built status of the interfaces it names, as
    tools/readme/agentic.json records them, and every interface must appear on the page."""
    with open(os.path.join(ROOT, "tools/readme/agentic.json")) as f:
        status = {i["id"]: i["status"] for i in json.load(f)["interfaces"]}
    bad, seen = 0, set()
    for ids, shown in re.findall(r'data-status="([a-z ]+)">([^<]*)<', page):
        names = ids.split()
        unknown = [n for n in names if n not in status]
        if unknown:
            print(f"site/index.html: data-status names {unknown}, not in tools/readme/agentic.json")
            bad += 1
            continue
        seen.update(names)
        want = min((status[n] for n in names), key=ORDER.index)
        if shown != want:
            print(f"site/index.html: data-status=\"{ids}\" says {shown}, tools/readme/agentic.json gives {want}")
            bad += 1
    if "None of these interfaces is built yet" in page and "Designed" != max(status.values(), key=ORDER.index):
        print("site/index.html: says none of the agent interfaces is built, tools/readme/agentic.json has one Built or Written")
        bad += 1
    for n in sorted(status.keys() - seen):
        print(f"site/index.html: interface {n} of tools/readme/agentic.json has no data-status")
        bad += 1
    return bad


# Every page of the site; each number on any of them is checked against the tree.
PAGES = ["index.html", "contribute.html"]


def main():
    os.makedirs(OUT, exist_ok=True)
    for rel in FIGURES + [HERO_VECTOR]:
        shutil.copyfile(os.path.join(ROOT, rel), os.path.join(OUT, os.path.basename(rel)))
    measured = measure()
    bad = 0
    for name in PAGES:
        with open(os.path.join(SITE, name)) as f:
            page = f.read()
        stated = dict(re.findall(r'data-measure="([a-z0-9-]+)">([^<]*)<', page))
        for key, value in measured.items():
            if key not in stated:
                if name == "index.html":          # the home page states every number; others any of them
                    print(f"site/{name}: no data-measure=\"{key}\"")
                    bad += 1
            elif stated[key] != value:
                print(f"site/{name}: {key} says {stated[key]}, the tree gives {value}")
                bad += 1
        for key in stated.keys() - measured.keys():
            print(f"site/{name}: data-measure=\"{key}\" is not measured by site/build.py")
            bad += 1
        if name == "index.html":
            bad += check_agentic(page)
    if bad:
        return 1
    print("site: numbers match the tree:", ", ".join(f"{k}={v}" for k, v in measured.items()))
    fit = os.path.join(SITE, "fitcheck.py")
    return subprocess.run([sys.executable, "-I", fit, SITE] + PAGES).returncode


if __name__ == "__main__":
    sys.exit(main())
