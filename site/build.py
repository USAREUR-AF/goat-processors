#!/usr/bin/env python3
"""Prepare site/ for publishing and check its numbers. Standard library only.

    python3 -I site/build.py

1. Copies the files the page shows from the tree into site/assets/from-tree/
   (git-ignored): the figures that docs/figures/make-figures.py writes, and the
   vector the hero replays. The page never carries its own copy of them.
2. Measures the four numbers in the strip under the hero, and the benchmark
   row, from the tree, and fails if site/index.html states anything else.
"""
import glob
import json
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, "site")
OUT = os.path.join(SITE, "assets", "from-tree")

FIGURES = [
    "docs/figures/processing-layer-light.svg", "docs/figures/processing-layer-dark.svg",
    "docs/figures/correlate-decision-light.svg", "docs/figures/correlate-decision-dark.svg",
    "docs/figures/seven-engines-light.svg", "docs/figures/seven-engines-dark.svg",
    "docs/figures/bench/random-light.svg", "docs/figures/bench/random-dark.svg",
]
HERO_VECTOR = "packs/correlate-gnn/vectors/04-separation-dissolves.json"


def measure():
    vectors = sorted(glob.glob(os.path.join(ROOT, "packs/*/vectors/*.json")))
    traces = 0
    for path in vectors:
        with open(path) as f:
            traces += sum(len(s.get("trace", [])) for s in json.load(f)["steps"])
    engines = [d for d in os.listdir(os.path.join(ROOT, "engines"))
               if os.path.isdir(os.path.join(ROOT, "engines", d))]
    bench = {}
    with open(os.path.join(ROOT, "docs/benchmark.md")) as f:
        for line in f:
            if line.startswith("| [assign-time]") and "random" not in bench:
                cells = [c.strip() for c in line.strip().strip("|").split("|")]
                bench["random"] = cells[1]
                bench["gospa"] = cells[-1].split(".")[0]
                break
    return {
        "engines": f"{len(engines)}",
        "vectors": f"{len(vectors)}",
        "traces": f"{traces:,}",
        "packs": f"{len(glob.glob(os.path.join(ROOT, 'packs/*/pack.def')))}",
        "f1-random": bench["random"],
        "gospa-random": bench["gospa"],
    }


def main():
    os.makedirs(OUT, exist_ok=True)
    for rel in FIGURES + [HERO_VECTOR]:
        shutil.copyfile(os.path.join(ROOT, rel), os.path.join(OUT, os.path.basename(rel)))
    with open(os.path.join(SITE, "index.html")) as f:
        page = f.read()
    measured = measure()
    stated = dict(re.findall(r'data-measure="([a-z0-9-]+)">([^<]*)<', page))
    bad = 0
    for key, value in measured.items():
        if key not in stated:
            print(f"site/index.html: no data-measure=\"{key}\"")
            bad += 1
        elif stated[key] != value:
            print(f"site/index.html: {key} says {stated[key]}, the tree gives {value}")
            bad += 1
    for key in stated.keys() - measured.keys():
        print(f"site/index.html: data-measure=\"{key}\" is not measured by site/build.py")
        bad += 1
    if bad:
        return 1
    print("site: numbers match the tree:", ", ".join(f"{k}={v}" for k, v in measured.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
