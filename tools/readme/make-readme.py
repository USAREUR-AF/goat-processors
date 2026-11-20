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
# Every correlate pack, in plain words. The generator refuses to run when a pack
# under packs/ has no entry here, or an entry names a pack that does not exist.
#   name: (extends, what it does, what it adds over the pack it extends)
PACKS = {
    "gnn": (None, "pairs two tracks when one lies inside the other's predicted 99 % uncertainty region and they agree on "
            "course, speed and height, on two reports in a row; the nearest candidate wins",
            "the base of the per-report packs: a statistical gate, a test of the distance between two tracks measured in units of their combined uncertainty"),
    "gnn-imm": ("gnn", "as gnn, with a second motion model for turning or accelerating targets",
                "a two-model filter, so a turning target stays inside its predicted region"),
    "gnn-restart": ("gnn", "as gnn, restarting a track's motion filter when a report lands far outside its prediction",
                    "recovery when a sensor's track number moves to another object"),
    "gnn-time": ("gnn", "as gnn, widening the uncertainty of a source whose clock is known to be off (radar-1, 500 ms); "
                 "no benchmark scenario has a source named radar-1, so there it scores exactly as gnn",
                 "time quality: a clock error becomes position uncertainty"),
    "window": ("gnn", "pairs two tracks whose distance is under a fixed window that grows with both tracks' reported error",
               "a distance window in place of the statistical gate, which tolerates a sensor with a fixed position bias"),
    "distance": ("gnn", "pairs two tracks closer than 200 m, for feeds that report no error; tracks of one source may pair; "
                 "the output follows the latest report", "plain distance, for sources with no error estimate"),
    "assign": (None, "at each tick, places each source's tracks into one output track per object by the least total cost, "
               "and combines the members' positions weighted by their uncertainty",
               "the base of the assignment packs"),
    "assign-imm": ("assign", "as assign, with a second motion model for turning or accelerating targets",
                   "the two-model filter"),
    "assign-window": ("assign", "as assign, keeping up to three candidate histories over two ticks before committing",
                      "a multi-frame window"),
    "assign-bias": ("assign-imm", "as assign-imm, estimating a position offset for each pair of sensors",
                    "sensor bias estimation, so a sensor off by a few hundred meters still joins"),
    "assign-full": ("assign-bias", "as assign-bias, with filter restart, the two-tick window with a margin, and a 20 s "
                    "stale time", "every option of assign 0.5 together"),
    "assign-time": ("assign-full", "as assign-full, also fitting a clock offset for each pair of sources",
                    "clock offset: a lag along the track that grows with speed is read as a clock error, not a position bias"),
}


def correlate_pack_dirs():
    return [d for d in pack_dirs() if os.path.basename(d).startswith("correlate-")]


def bench_results():
    p = rel("docs", "figures", "bench", "results.json")
    return json.load(open(p, encoding="utf-8")) if os.path.isfile(p) else None


def default_pack(d):
    """The pack at the top of F1 on every benchmark set (ties allowed), the sets, and who it ties with per set."""
    sets = [k for k in ("named", "random", "time") if all(k in d["scenarios"][p] for p in d["packs"])]
    tops = {}
    for k in sets:
        best = max(d["scenarios"][p][k]["f1"] for p in d["packs"])
        tops[k] = [p for p in d["packs"] if d["scenarios"][p][k]["f1"] == best]
    common = [p for p in d["packs"] if all(p in tops[k] for k in sets)]
    if len(common) != 1:
        return None, sets, {}
    best = common[0]
    return best, sets, {k: [p for p in tops[k] if p != best] for k in sets}


def methods_and_packs():
    names = sorted(os.path.basename(d)[len("correlate-"):] for d in correlate_pack_dirs())
    missing = sorted(set(names) - set(PACKS))
    extra = sorted(set(PACKS) - set(names))
    if missing or extra:
        raise SystemExit("make-readme.py PACKS: no entry for %s; entry for missing pack %s" % (missing, extra))
    d = bench_results()
    order = [n for n in PACKS]
    out = ["| Pack | Method | What it does | Adds over the pack it extends | F1, named / random / time |",
           "|---|---|---|---|---|"]
    for n in order:
        parent, what, adds = PACKS[n]
        m = method_of(rel("packs", "correlate-" + n)) or "confirm"
        f1 = "not scored"
        if d and "correlate-" + n in d["scenarios"]:
            sc = d["scenarios"]["correlate-" + n]
            f1 = " / ".join("%.3f" % sc[k]["f1"] for k in ("named", "random", "time") if k in sc)
        ext = "%s: %s" % (("`%s`" % parent), adds) if parent else adds
        out.append("| [`%s`](packs/correlate-%s/pack.def) | `%s` | %s | %s | %s |" % (n, n, m, what, ext, f1))
    text = "\n".join(out)
    if d:
        best, sets, ties = default_pack(d)
        confirm = [p for p in d["packs"] if method_of(rel("packs", p)) != "assign"]
        if best:
            sb = d["scenarios"][best]
            short = lambda p: p[len("correlate-"):]
            per_set = ", ".join("%s %.3f%s" % (k, sb[k]["f1"], " (equal with %s)" % ", ".join("`%s`" % short(t) for t in ties[k])
                                                if ties[k] else "") for k in sets)
            g = sb["random"]["gospa_m"]
            lowest = all(g <= d["scenarios"][p]["random"]["gospa_m"] for p in d["packs"])
            cs = sorted(d["scenarios"][p]["random"]["swaps"] for p in confirm)
            text += ("\n\n**Default: `%s`.** It has the highest F1 of every pack on all %d benchmark sets: %s. It keeps one "
                     "output track per object and combines its members%s. Its weak point is identity swaps (an object's "
                     "output track changing to another): %d on the random set, against %d to %d for the per-report packs, "
                     "so the `confirm` method stays selectable."
                     % (short(best), len(sets), per_set,
                        ", with the lowest position error of every pack (GOSPA, a mean position error that also charges missed and "
                        "false tracks: %.0f m on the random set)" % g if lowest else "",
                        sb["random"]["swaps"], cs[0], cs[-1]))
    return text
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
               "(pack files every engine must accept, or must refuse) on every pull request and every push to `main`." % tuple(format(c[k], ",") for k in ("vectors", "steps", "traces", "loads")))
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
    d = bench_results()
    if d is None:
        return "The benchmark is designed, not built on this tree."
    fam = [m.get("family") for m in d.get("meta", [])]
    n_random = sum(1 for f in fam if f == "random")
    n_time = sum(1 for f in fam if f == "time")
    n_named = len(fam) - n_random - n_time
    head = ("| Pack | F1, %d named | F1, %d random | F1, %d time | False merges | Missed merges | Identity swaps | GOSPA, m |\n"
            "|---|---:|---:|---:|---:|---:|---:|---:|" % (n_named, n_random, n_time))
    rows = []
    for pack in d["packs"]:
        sc = d["scenarios"][pack]
        r = sc["random"]
        t = sc.get("time")
        n = pack.replace("correlate-", "")
        rows.append("| [`%s`](#methods-and-packs) | %.3f | %.3f | %s | %d | %d | %d | %.0f |" % (
            n, sc["named"]["f1"], r["f1"], "%.3f" % t["f1"] if t else "", r["false_merges"], r["missed_merges"],
            r["swaps"], r["gospa_m"]))
    return "%s\n%s\n\nFalse merges, missed merges, identity swaps and GOSPA are for the %d random scenarios." % (
        head, "\n".join(rows), n_random)


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

STATUSES = ("Built", "Written", "Designed")


def agentic_data():
    """The agent interfaces and their status, checked so that nothing is claimed ahead of its code."""
    d = json.loads(read("tools", "readme", "agentic.json"))
    for i in d["interfaces"]:
        where = "tools/readme/agentic.json, %s" % i["id"]
        if i["status"] not in STATUSES:
            raise SystemExit("%s: status %r is not one of %s" % (where, i["status"], ", ".join(STATUSES)))
        if i["status"] == "Built":
            if not i["tests"]:
                raise SystemExit("%s: Built needs the tests that prove it" % where)
            for t in i["tests"]:
                if not os.path.exists(rel(t)):
                    raise SystemExit("%s: Built names test %s, which is not in the tree" % (where, t))
        if i["status"] in ("Built", "Written") and not (i["link"] and os.path.exists(rel(i["link"]))):
            raise SystemExit("%s: %s needs a link to its code or document in the tree" % (where, i["status"]))
    return d


def agentic():
    d = agentic_data()
    rows = d["interfaces"]
    built = sum(1 for i in rows if i["status"] == "Built")
    if built == 0:
        lead = ("None of these interfaces is built yet. A row says Built only when its code and its "
                "tests are on main.")
    else:
        lead = ("%s of the %d interfaces are built. A row says Built only when its code and its tests "
                "are on main." % (WORDS.get(built, str(built)), len(rows)))
    out = [lead, "",
           "| Interface | What it lets you build | Status |", "|---|---|---|"]
    for i in rows:
        name = i["name"]
        if i["link"] and os.path.exists(rel(i["link"])):
            name = "[%s](%s)" % (name, i["link"])
        out.append("| %s | %s | %s |" % (name, i["lets_you"][0].upper() + i["lets_you"][1:], i["status"]))
    out += ["", "Built: the code and its tests are on main. Written: the document exists. "
                "Designed: decided, not yet in the tree."]
    return "\n".join(out)


def agentic_design():
    doc = agentic_data()["design_doc"]
    if os.path.exists(rel(doc)):
        return "The design, with the cost and the matching safeguard for each choice, is in [`%s`](%s)." % (doc, doc)
    return "The design document, `%s`, is not written yet." % doc


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
        "methods_and_packs": methods_and_packs(),
        "conformance": conformance(),
        "trace_example": trace_example(),
        "benchmark": benchmark(),
        "agentic": agentic(),
        "agentic_design": agentic_design(),
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
