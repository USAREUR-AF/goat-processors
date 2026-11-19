#!/usr/bin/env python3
"""Write README.md from tools/readme/template.md and the tree.

    python3 -I tools/readme/make-readme.py           # write README.md
    python3 -I tools/readme/make-readme.py --check   # exit 1 if README.md is out of date

Every number in the README comes from here: counts of specifications, packs
and vectors; a trace record copied from a vector; lines of source per engine;
the benchmark scores from docs/figures/bench/results.json. The template holds
the prose and names each generated part as {{name}}. Standard library only.
"""

import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
REPO = "USAREUR-AF/goat-processors"

ENGINES = [  # language, directory, command that runs every vector, source globs
    ("Python", "python", "cd engines/python && PYTHONPATH=src python3 -m unittest discover -s tests", ["src/**/*.py"]),
    ("Rust", "rust", "cd engines/rust && cargo test", ["src/**/*.rs"]),
    ("Go", "go", "cd engines/go && go test ./...", ["*.go"]),
    ("Java", "java", "engines/java/build.sh", ["src/**/*.java"]),
    ("C++", "cpp", "cmake -S engines/cpp -B build/cpp && cmake --build build/cpp && ctest --test-dir build/cpp",
     ["src/**/*.cpp", "src/**/*.hpp", "src/**/*.h"]),
    ("Erlang", "erlang", "engines/erlang/run_tests", ["src/**/*.erl", "src/**/*.hrl"]),
    ("Zig", "zig", "cd engines/zig && zig build test", ["src/**/*.zig"]),
]


def rel(*p):
    return os.path.join(ROOT, *p)


def read(*p):
    return open(rel(*p), encoding="utf-8").read()


def pack_dirs():
    return sorted(d for d in glob.glob(rel("packs", "*")) if os.path.isfile(os.path.join(d, "pack.def")))


def vectors_of(pack_dir):
    return sorted(glob.glob(os.path.join(pack_dir, "vectors", "*.json")))


def method_of(pack_dir):
    m = re.search(r"^method\s+(\S+)", open(os.path.join(pack_dir, "pack.def"), encoding="utf-8").read(), re.M)
    return m.group(1) if m else None


def spec_rows():
    """Rows of the table in spec/README.md: function, specification file, what it does."""
    rows = []
    for line in read("spec", "README.md").splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 4 or cells[0] in ("Function", "") or set(cells[0]) <= set("-"):
            continue
        m = re.search(r"\(([^)]+\.md)\)", cells[1])
        rows.append((cells[0], m.group(1) if m else None, cells[3]))
    return rows


def spec_version(name):
    m = re.search(r"^Status:\s*(\w+)\.\s*Version\s+(\d+(?:\.\d+)*)", read("spec", name), re.M)
    return (m.group(1), m.group(2)) if m else (None, None)


# ---------------------------------------------------------------- parts
def functions():
    out = ["| Function | What it does | Specification | Packs | Vectors | Status |", "|---|---|---|---:|---:|---|"]
    for fn, spec, what in spec_rows():
        base = fn.split(",")[0].strip()
        assign = "method assign" in fn
        packs = [d for d in pack_dirs() if os.path.basename(d).startswith(base + "-")
                 and (base != "correlate" or (method_of(d) == "assign") == assign)]
        nv = sum(len(vectors_of(d)) for d in packs)
        if spec and os.path.isfile(rel("spec", spec)):
            st, ver = spec_version(spec)
            sp = "[%s](spec/%s) %s" % (spec, spec, ver or "")
        else:
            st, sp = None, "none"
        if nv:
            n = len(present_engines())
            status = "Built in %s languages" % WORDS.get(n, str(n)).lower()
        elif st:
            status = st
        else:
            status = "Designed, not built"
        out.append("| %s | %s | %s | %d | %d | %s |" % (fn, what, sp.strip(), len(packs), nv, status))
    return "\n".join(out)


def present_engines():
    return [e for e in ENGINES if os.path.isdir(rel("engines", e[1]))]


def counts():
    vs = [v for d in pack_dirs() for v in vectors_of(d)]
    steps = traces = 0
    for v in vs:
        for st in json.load(open(v, encoding="utf-8"))["steps"]:
            steps += 1
            traces += len(st.get("trace", []))
    loads = len(glob.glob(rel("spec", "*-load-vectors", "*.json")))
    return {"vectors": len(vs), "steps": steps, "traces": traces, "loads": loads, "packs": len(pack_dirs())}


def lines_of(lang_dir, globs):
    n = 0
    seen = set()
    for g in globs:
        for f in glob.glob(rel("engines", lang_dir, g), recursive=True):
            if f in seen or "/test" in f.replace(rel("engines", lang_dir), ""):
                continue
            seen.add(f)
            n += sum(1 for line in open(f, encoding="utf-8", errors="replace") if line.strip())
    return n


def conformance():
    c = counts()
    out = ["| Language | Engine | Lines of source | Runs every vector with |", "|---|---|---:|---|"]
    for name, d, cmd, globs in present_engines():
        out.append("| %s | [`engines/%s`](engines/%s) | %s | `%s` |" % (name, d, d, format(lines_of(d, globs), ","), cmd))
    out.append("")
    out.append("Each engine runs all %s scenario vectors (%s steps, %s trace records) and %s load vectors "
               "on every pull request and every push to `main`." % tuple(format(c[k], ",") for k in ("vectors", "steps", "traces", "loads")))
    return "\n".join(out)


def trace_example():
    path = "packs/correlate-gnn/vectors/04-separation-dissolves.json"
    v = json.load(open(rel(path), encoding="utf-8"))
    step = 2
    st = v["steps"][step]
    rec = next(t for t in st["trace"] if t["test"] == "mahalanobis")
    ev = st["expect"][0]
    gate = next(line.strip() for line in read("packs", v["pack"], "pack.def").splitlines()
                if line.split()[:2] == ["gate", rec["test"]])
    return ("Step %d of [`%s`](%s) ingests a report from `%s`. The engine's first test of it against `%s` "
            "is this record, copied from the vector:\n\n```json\n%s\n```\n\n"
            "The value is the squared distance between the two tracks in units of their combined "
            "uncertainty. The limit is the pack's rule `%s` in [`packs/%s/pack.def`](packs/%s/pack.def). "
            "After %d more records the step returns `%s`." % (
                step + 1, os.path.basename(path), path, rec["a"], rec["b"], json.dumps(rec), re.sub(r"\s+", " ", gate),
                v["pack"], v["pack"], len(st["trace"]) - 1, json.dumps(ev)))


def benchmark():
    p = rel("docs", "figures", "bench", "results.json")
    if not os.path.isfile(p):
        return "The benchmark is designed, not built on this tree."
    d = json.load(open(p, encoding="utf-8"))
    fam = [m.get("family") for m in d.get("meta", [])]
    n_random = sum(1 for f in fam if f == "random")
    n_named = len(fam) - n_random
    head = ("| Pack | Set | Pairwise F1 | Precision | Recall | False merges | Missed merges | Identity swaps | GOSPA, m |\n"
            "|---|---|---:|---:|---:|---:|---:|---:|---:|")
    rows = []
    for pack in d["packs"]:
        for key, label in (("named", "%d named" % n_named), ("random", "%d random" % n_random)):
            s = d["scenarios"][pack][key]
            rows.append("| %s | %s | %.3f | %.3f | %.3f | %d | %d | %d | %.1f |" % (
                pack.replace("correlate-", ""), label, s["f1"], s["precision"], s["recall"],
                s["false_merges"], s["missed_merges"], s["swaps"], s["gospa_m"]))
    best = max(d["packs"], key=lambda k: d["scenarios"][k]["random"]["f1"])
    return "%s\n%s\n\nHighest pairwise F1 over the random set: `%s`, %.3f." % (
        head, "\n".join(rows), best, d["scenarios"][best]["random"]["f1"])


def picture(name, alt, width=None):
    w = ' width="%d"' % width if width else ""
    return ('<picture>\n  <source media="(prefers-color-scheme: dark)" srcset="%s-dark.svg">\n'
            '  <img alt="%s" src="%s-light.svg"%s>\n</picture>' % (name, alt, name, w))


def figure_alt(name):
    """The figure's own description, so the alt text says what the drawing says."""
    s = read("docs", "figures", name + "-light.svg")
    m = re.search(r"<desc[^>]*>(.*?)</desc>", s, re.S)
    alt = m.group(1) if m else name
    return alt.replace('"', "&quot;")


def figure(name):
    return picture("docs/figures/" + name, figure_alt(name))


WORDS = {2: "Two", 3: "Three", 4: "Four", 5: "Five", 6: "Six", 7: "Seven", 8: "Eight", 9: "Nine"}


def tolerance():
    m = re.search(r"abs\(got - want\) <= ([0-9.e-]+)", read("spec", "vector-format.md"))
    return m.group(1)


def parts():
    c = counts()
    n = len(present_engines())
    p = {
        "n_engines_word": WORDS.get(n, str(n)),
        "n_engines": WORDS.get(n, str(n)).lower(),
        "n_others_word": WORDS.get(n - 1, str(n - 1)).lower(),
        "tolerance": tolerance(),
        "badge": "[![conformance](https://github.com/%s/actions/workflows/conformance.yml/badge.svg?branch=main)]"
                 "(https://github.com/%s/actions/workflows/conformance.yml)" % (REPO, REPO),
        "functions": functions(),
        "conformance": conformance(),
        "trace_example": trace_example(),
        "benchmark": benchmark(),
        "n_vectors": format(c["vectors"], ","),
        "n_packs": format(c["packs"], ","),
    }
    for name in ("processing-layer", "correlate-decision", "assign-matrix", "seven-engines"):
        p["figure:" + name] = figure(name)
    if os.path.isfile(rel("docs", "figures", "bench", "random-light.svg")):
        p["figure:bench"] = picture("docs/figures/bench/random", "Pooled scores over the random set of the "
                                    "benchmark, one bar per correlate pack")
    else:
        p["figure:bench"] = ""
    return p


def render():
    tpl = read("tools", "readme", "template.md")
    p = parts()

    def sub(m):
        k = m.group(1)
        if k not in p:
            raise SystemExit("template names {{%s}}, which make-readme.py does not make" % k)
        return p[k]

    out = re.sub(r"\{\{([a-z_:-]+)\}\}", sub, tpl)
    return "<!-- Written by tools/readme/make-readme.py from tools/readme/template.md. Edit those, not this file. -->\n" + out


def main(argv):
    out = render()
    if "--check" in argv:
        if read("README.md") != out:
            print("README.md is out of date; run python3 -I tools/readme/make-readme.py", file=sys.stderr)
            return 1
        return 0
    with open(rel("README.md"), "w", encoding="utf-8") as f:
        f.write(out)
    print("README.md")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
