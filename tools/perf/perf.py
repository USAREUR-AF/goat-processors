#!/usr/bin/env python3
"""Performance harness: reports per second and peak memory, per engine, per function.

    python3 -I tools/perf/perf.py generate [--size large|smoke] --out DIR
    python3 -I tools/perf/perf.py baseline [--repeats N] [--large-repeats N]
                                           [--engines a,b] [--work DIR]
    python3 -I tools/perf/perf.py report [--check]
    python3 -I tools/perf/perf.py smoke

`baseline` measures and writes docs/figures/perf/results.json, then the page
docs/performance.md. `report` rewrites the page from results.json (`--check`:
exit 1 if the committed page differs). `smoke` is CI's short run: the Python
engine's runner on the smoke scenario for every function and one vector
command; it checks that they run, not their numbers. Expected outputs of the
large scenario come from the Rust runner, as every vector does (tools/consensus.py). Method and the meaning of every
number: tools/perf/README.md.
"""

import argparse
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import tarfile
import io
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(1, os.path.join(ROOT, "tools"))
import consensus  # noqa: E402  (the comparison of spec/vector-format.md)
import scenario  # noqa: E402

REFERENCE = "rust"   # the engine whose output is the expected output (as tools/consensus.py)

RESULTS = os.path.join(ROOT, "docs", "figures", "perf", "results.json")
# The pre-refactor baseline (commit ed5d55a), kept so the page can state each cell's change.
BEFORE = os.path.join(ROOT, "docs", "figures", "perf", "results-before.json")
DOC = os.path.join(ROOT, "docs", "performance.md")
ENGINES = ["python", "rust", "go", "java", "cpp", "erlang", "zig"]
FUNCTIONS = ["correlate", "filter", "fuse", "quality"]
# The packs the large scenario runs, per function.
LARGE_PACKS = {"correlate": ["correlate-gnn-imm", "correlate-assign-time"], "filter": ["filter-thin"],
               "fuse": ["fuse-independent"], "quality": ["quality-time"]}
LOAD_DIRS = {"correlate": "correlate-load-vectors", "filter": "filter-load-vectors",
             "fuse": "fuse-load-vectors", "quality": "quality-load-vectors"}


# ---------------------------------------------------------------------------
# Measuring


TIME = "/usr/bin/time"   # GNU time: peak RSS of the command it runs


def measure(argv, cwd=None, env=None, timeout=3600):
    """Run argv once; (wall s, peak RSS KB, exit code, output tail).

    Wall time is taken here around the whole command. Peak RSS is the maximum
    resident set of the command as GNU time reports it (`%M`, from wait4 on its
    own child). It is not read from this process's wait4: on Linux a child
    forked from the harness can report the harness's own resident set, which
    hides an engine smaller than that.
    """
    import tempfile
    have_time = os.access(TIME, os.X_OK)
    with tempfile.NamedTemporaryFile("r", suffix=".rss") as rf:
        full = [TIME, "-q", "-f", "%M", "-o", rf.name] + list(argv) if have_time else list(argv)
        t0 = time.perf_counter()
        p = subprocess.Popen(full, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = []
        # Drain output so a chatty runner cannot block on a full pipe.
        for line in p.stdout:
            out.append(line)
            if len(out) > 400:
                del out[:200]
        p.wait(timeout=timeout)
        wall = time.perf_counter() - t0
        rss = 0
        if have_time:
            vals = [x for x in rf.read().split() if x.isdigit()]
            rss = int(vals[-1]) if vals else 0
    tail = b"".join(out[-20:]).decode("utf-8", "replace")
    return wall, rss, p.returncode, tail


def spread(xs):
    """Median and the full range of a sample."""
    xs = sorted(xs)
    return {"median": statistics.median(xs), "min": xs[0], "max": xs[-1], "n": len(xs)}


def repeat(argv, n, cwd=None, env=None, parse=None):
    """n runs; medians and ranges of wall and peak RSS; the runner's own counters if `parse`."""
    walls, rss, own = [], [], []
    status, tail = 0, ""
    for _ in range(n):
        w, r, code, t = measure(argv, cwd=cwd, env=env)
        if code != 0:
            return {"ok": False, "exit": code, "tail": t[-1500:]}
        walls.append(w)
        rss.append(r)
        tail = t
        if parse:
            own.append(parse(t))
    res = {"ok": True, "wall_s": spread(walls), "rss_kb": spread(rss)}
    if own:
        res["run_s"] = spread([o["run_ns"] / 1e9 for o in own])
        res["parse_s"] = spread([o["parse_ns"] / 1e9 for o in own])
        res["counters"] = {k: own[0][k] for k in ("steps", "ingest", "tick", "events", "trace_records")}
    return res


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def last_json(text):
    for line in reversed(text.strip().splitlines()):
        line = line.strip()
        if line.startswith("{"):
            return json.loads(line)
    raise ValueError("no JSON counters line in output")


# ---------------------------------------------------------------------------
# Inputs


def vector_counts(tree, function):
    """Scenario vectors, their ingest steps and ticks, and load vectors, for one function."""
    import glob
    files = sorted(glob.glob(os.path.join(tree, "packs", function + "-*", "vectors", "*.json")))
    ing = tick = 0
    for f in files:
        for s in load_json(f)["steps"]:
            if "ingest" in s:
                ing += 1
            else:
                tick += 1
    loads = len(glob.glob(os.path.join(tree, "spec", LOAD_DIRS[function], "*.json")))
    return {"vectors": len(files), "ingest": ing, "tick": tick, "load_vectors": loads}


def export_tree(dest):
    """The committed tree (HEAD) into dest: the engines are timed on what is committed."""
    if os.path.exists(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    data = subprocess.run(["git", "-C", ROOT, "archive", "--format=tar", "HEAD"],
                          check=True, capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(data)) as t:
        t.extractall(dest, filter="data")
    return subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"],
                          check=True, capture_output=True, text=True).stdout.strip()


def write_steps(work, size="large"):
    """The generated steps file of each function; returns {function: path} and the description."""
    os.makedirs(work, exist_ok=True)
    paths, desc = {}, ""
    for f in FUNCTIONS:
        d = scenario.steps_for(f, size)
        desc = d["description"]
        p = os.path.join(work, "%s-%s.json" % (size, f))
        with open(p, "w", encoding="utf-8") as fh:
            json.dump(d, fh, separators=(",", ":"))
        paths[f] = p
    return paths, desc


def reference_run(tree, function, pack_dir, steps_path, events_path):
    """Run the reference engine's runner of `tree` with --trace; return its events lines."""
    p = subprocess.run([os.path.join(tree, "engines", REFERENCE, "runner", "run"), "--function", function,
                        "--pack", pack_dir, "--steps", steps_path, "--events", events_path, "--trace"],
                       cwd=tree, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("%s runner exit %d: %s" % (REFERENCE, p.returncode, p.stderr.strip()[-500:]))
    with open(events_path, encoding="utf-8") as fh:
        return [json.loads(x) for x in fh if x.strip()]


def large_tree(base, dest, steps, work):
    """A copy of the committed tree whose only scenario vectors are the large scenario,
    one per pack of LARGE_PACKS, with expected events, trace and snapshot from the
    Rust runner (as the vector generators compute them, tools/consensus.py). Load vectors stay."""
    if os.path.exists(dest):
        shutil.rmtree(dest)
    shutil.copytree(base, dest, symlinks=True)
    _run([os.path.join(base, "engines", REFERENCE, "runner", "build")], cwd=base)
    for d in os.listdir(os.path.join(dest, "packs")):
        vd = os.path.join(dest, "packs", d, "vectors")
        if os.path.isdir(vd):
            shutil.rmtree(vd)
            os.makedirs(vd)
    for f, packs in LARGE_PACKS.items():
        doc = load_json(steps[f])
        for pack in packs:
            lines = reference_run(base, f, os.path.join(base, "packs", pack), steps[f],
                                  os.path.join(work, "expected-%s.jsonl" % pack))
            if len(lines) != len(doc["steps"]) + 1 or "snapshot" not in lines[-1]:
                raise RuntimeError("%s runner: %d events lines for %d steps" % (REFERENCE, len(lines), len(doc["steps"])))
            out = []
            for st, line in zip(doc["steps"], lines):
                kind = "ingest" if "ingest" in st else "tick"
                out.append({kind: st[kind], "expect": consensus.clean(line["events"]),
                            "trace": consensus.clean(line["trace"])})
            vec = {"name": "perf-large", "pack": pack, "steps": out, "snapshot": consensus.clean(lines[-1]["snapshot"])}
            with open(os.path.join(dest, "packs", pack, "vectors", "perf-large.json"), "w",
                      encoding="utf-8") as fh:
                json.dump(vec, fh, separators=(",", ":"))


# ---------------------------------------------------------------------------
# Engines: build once (not timed), then one command per function.


def _v(argv):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        return (r.stdout + r.stderr).strip().splitlines()[0]
    except (OSError, subprocess.SubprocessError, IndexError):
        return "not found"


def versions():
    return {
        "python": _v([sys.executable, "--version"]),
        "rust": _v(["rustc", "--version"]),
        "go": _v(["go", "version"]),
        "java": _v(["java", "-version"]),
        "cpp": _v(["g++", "--version"]),
        "erlang": "OTP " + _v(["erl", "-noshell", "-eval",
                               "io:format(\"~s~n\",[erlang:system_info(otp_release)]),halt()."]),
        "zig": "zig " + _v(["zig", "version"]),
        "cmake": _v(["cmake", "--version"]),
    }


def machine():
    cpu = "unknown"
    try:
        with open("/proc/cpuinfo") as fh:
            for line in fh:
                if line.startswith("model name"):
                    cpu = line.split(":", 1)[1].strip()
                    break
    except OSError:
        pass
    mem = 0
    try:
        with open("/proc/meminfo") as fh:
            for line in fh:
                if line.startswith("MemTotal"):
                    mem = int(line.split()[1]) // (1024 * 1024)
    except OSError:
        pass
    return {"cpu": cpu, "cores": os.cpu_count(), "memory_gb": mem,
            "os": "%s %s" % (platform.system(), platform.release())}


def load_average():
    """The 1, 5 and 15 minute load averages (/proc/loadavg), or None."""
    try:
        with open("/proc/loadavg") as fh:
            return [float(x) for x in fh.read().split()[:3]]
    except (OSError, ValueError):
        return None


def fail_line(tail):
    """The line of a failed run's output that says what failed."""
    lines = [x.strip() for x in tail.strip().splitlines() if x.strip()]
    for x in lines:
        if any(k in x for k in ("FAIL", "Error", "error", "panicked", "Exception", "differs", "mismatch")):
            return x
    return lines[-1] if lines else ""


def _run(argv, cwd=None, env=None):
    r = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("%s failed in %s:\n%s" % (" ".join(argv), cwd, (r.stdout + r.stderr)[-3000:]))
    return r.stdout


PY_TESTS = {"correlate": "test_vectors", "filter": "test_filter_vectors", "fuse": "test_fuse_vectors",
            "quality": "test_quality_vectors"}
RUST_TESTS = {"correlate": "vectors", "filter": "filter_vectors", "fuse": "fuse_vectors",
              "quality": "quality_vectors"}
GO_PKGS = {"correlate": ".", "filter": "./filter", "fuse": "./fuse", "quality": "./quality"}
JAVA_CLASSES = {"correlate": "correlator.VectorTest", "filter": "filter.VectorTest",
                "fuse": "fuse.FuseVectorTest", "quality": "quality.VectorTest"}
CPP_BINS = {"correlate": "run_vectors", "filter": "run_filter_vectors", "fuse": "run_fuse_vectors",
            "quality": "run_quality_vectors"}
ERL_MODULES = {"correlate": "correlator_vectors", "filter": "filter_vectors", "fuse": "fuse_vectors",
               "quality": "quality_vectors"}
ZIG_TESTS = {"correlate": "src/vectors_test.zig", "filter": "src/filter_vectors_test.zig",
             "fuse": "src/fuse_vectors_test.zig", "quality": "src/quality_vectors_test.zig"}

# What a vector-command number covers, per engine.
COVERS = {
    "python": "`python3 -m unittest <function test module>` (CPython, no build): interpreter start, "
              "JSON parse of every vector file, the engine, comparison with the expected events, trace "
              "and snapshot",
    "rust": "the function's test binary from `cargo test --release --no-run`, run with "
            "`--test-threads=1`: JSON parse, engine, comparison; its scenario, load and shipped-pack tests",
    "go": "the package's test binary from `go test -c`, run in the package directory: JSON parse, engine, "
          "comparison; every test of that package (unit tests included)",
    "java": "`java -cp build <VectorTest class> <root>` after `javac --release 17`: JVM start and JIT "
            "warm-up, JSON parse, engine, comparison",
    "cpp": "the function's runner from `cmake --build` (CMAKE_BUILD_TYPE Release, the project default), "
           "run with the root: JSON parse, engine, comparison",
    "erlang": "`erl -noshell -run <module> main <root>` after `erlc`: VM start, JSON parse, engine, "
              "comparison",
    "zig": "the function's test file compiled by `zig test -O ReleaseFast --test-no-exec` with the same "
           "`paths` module build.zig makes, then run: JSON parse, engine, comparison",
}


def build_engine(engine, tree, work):
    """Build (not timed); return {function: (argv, cwd, env)}."""
    eng_dir = os.path.join(tree, "engines", engine)
    os.makedirs(work, exist_ok=True)
    env = dict(os.environ)
    cmds = {}
    if engine == "python":
        env["PYTHONPATH"] = os.path.join(eng_dir, "src")
        for f, mod in PY_TESTS.items():
            cmds[f] = ([sys.executable, "-m", "unittest", mod], os.path.join(eng_dir, "tests"), env)
    elif engine == "rust":
        out = _run(["cargo", "test", "--release", "--no-run", "--message-format=json"], cwd=eng_dir)
        bins = {}
        for line in out.splitlines():
            if not line.startswith("{"):
                continue
            m = json.loads(line)
            if m.get("reason") == "compiler-artifact" and m.get("executable") and \
                    "test" in m["target"].get("kind", []):
                bins[m["target"]["name"]] = m["executable"]
        for f, name in RUST_TESTS.items():
            cmds[f] = ([bins[name], "--test-threads=1"], eng_dir, env)
    elif engine == "go":
        for f, pkg in GO_PKGS.items():
            exe = os.path.join(work, "go-%s.test" % f)
            _run(["go", "test", "-c", "-o", exe, pkg], cwd=eng_dir)
            cmds[f] = ([exe], os.path.normpath(os.path.join(eng_dir, pkg)), env)
    elif engine == "java":
        build = os.path.join(work, "java-build")
        if os.path.exists(build):
            shutil.rmtree(build)
        os.makedirs(build)
        srcs = []
        for d, _, fs in os.walk(os.path.join(eng_dir, "src")):
            srcs += [os.path.join(d, x) for x in fs if x.endswith(".java")]
        _run(["javac", "--release", "17", "-d", build] + sorted(srcs))
        for f, cls in JAVA_CLASSES.items():
            cmds[f] = (["java", "-cp", build, cls, tree], tree, env)
    elif engine == "cpp":
        b = os.path.join(work, "cpp-build")
        _run(["cmake", "-S", eng_dir, "-B", b])
        _run(["cmake", "--build", b, "-j", str(os.cpu_count() or 1)])
        for f, exe in CPP_BINS.items():
            cmds[f] = ([os.path.join(b, exe), tree], b, env)
    elif engine == "erlang":
        _run([os.path.join(eng_dir, "build.sh")])
        for f, mod in ERL_MODULES.items():
            cmds[f] = (["erl", "-noshell", "-pa", os.path.join(eng_dir, "ebin"), "-run", mod, "main", tree],
                       tree, env)
    elif engine == "zig":
        opts = os.path.join(work, "zig-paths.zig")
        with open(opts, "w") as fh:
            for name, rel in (("packs_dir", "packs"), ("load_vectors_dir", "spec/correlate-load-vectors"),
                              ("quality_load_vectors_dir", "spec/quality-load-vectors"),
                              ("filter_load_vectors_dir", "spec/filter-load-vectors"),
                              ("fuse_load_vectors_dir", "spec/fuse-load-vectors")):
                fh.write("pub const %s: []const u8 = %s;\n" % (name, json.dumps(os.path.join(tree, rel))))
        for f, src in ZIG_TESTS.items():
            exe = os.path.join(work, "zig-%s-test" % f)
            _run(["zig", "test", "-O", "ReleaseFast", "--test-no-exec", "-femit-bin=" + exe,
                  "--dep", "paths", "-Mroot=" + os.path.join(eng_dir, src), "-Mpaths=" + opts],
                 cwd=eng_dir)
            cmds[f] = ([exe], eng_dir, env)
    return cmds


# ---------------------------------------------------------------------------
# Runners (README.md, "Runner contract")


def runner(engine, tree):
    """(build argv or None, run argv) of an engine's contract runner, or None if it has none."""
    d = os.path.join(tree, "engines", engine, "runner")
    if os.access(os.path.join(d, "run"), os.X_OK):
        b = os.path.join(d, "build")
        return ([b] if os.access(b, os.X_OK) else None), [os.path.join(d, "run")]
    return None


def same(got, want):
    """Equality under spec/vector-format.md ("What the engine checks"): numbers within
    1e-6 * max(1, abs(want)), every other value exactly (tools/consensus.py)."""
    return not consensus.differences(want, got)


def check_events(path, ref_path):
    """None when a runner's events file equals the reference's, else where it first differs."""
    with open(path, encoding="utf-8") as a, open(ref_path, encoding="utf-8") as b:
        for i, (la, lb) in enumerate(zip(a, b)):
            d = consensus.differences(json.loads(lb), json.loads(la))
            if d:
                return "line %d differs at %s" % (i + 1, d[0][0] or "<root>")
        if a.readline() or b.readline():
            return "different number of lines"
    return None


# ---------------------------------------------------------------------------
# Baseline


def baseline(a):
    work = os.path.abspath(a.work)
    os.makedirs(work, exist_ok=True)
    engines = a.engines.split(",") if a.engines else ENGINES
    tree = os.path.join(work, "tree")
    commit = export_tree(tree)
    steps, desc = write_steps(os.path.join(work, "steps"))
    print("generating the large vectors with the %s runner (expected outputs) ..." % REFERENCE, flush=True)
    ltree = os.path.join(work, "tree-large")
    large_tree(tree, ltree, steps, work)
    sizes = {pack: os.path.getsize(os.path.join(ltree, "packs", pack, "vectors", "perf-large.json"))
             for packs in LARGE_PACKS.values() for pack in packs}

    load_start = load_average()
    res = {"commit": commit, "machine": machine(), "versions": versions(), "repeats": a.repeats,
           "large_repeats": a.large_repeats, "large": {"description": desc, "vector_bytes": sizes},
           "counts": {f: vector_counts(tree, f) for f in FUNCTIONS},
           "large_counts": {f: vector_counts(ltree, f) for f in FUNCTIONS},
           "vectors": {}, "large_vectors": {}, "runner": {}}

    for e in engines:
        print("== %s: build" % e, flush=True)
        try:
            cmds = build_engine(e, tree, os.path.join(work, "build-" + e))
            lcmds = build_engine(e, ltree, os.path.join(work, "build-large-" + e))
        except (RuntimeError, OSError, KeyError) as err:
            res["vectors"][e] = {f: {"ok": False, "exit": None, "tail": "build failed: %s" % err}
                                 for f in FUNCTIONS}
            res["large_vectors"][e] = res["vectors"][e]
            continue
        res["vectors"][e], res["large_vectors"][e] = {}, {}
        for f in FUNCTIONS:
            print("   %s vectors x%d" % (f, a.repeats), flush=True)
            res["vectors"][e][f] = repeat(cmds[f][0], a.repeats, cwd=cmds[f][1], env=cmds[f][2])
            print("   %s large x%d" % (f, a.large_repeats), flush=True)
            res["large_vectors"][e][f] = repeat(lcmds[f][0], a.large_repeats, cwd=lcmds[f][1], env=lcmds[f][2])

    print("== runners (engine calls only)", flush=True)
    # The reference events: the expected outputs written by large_tree.
    refs = {pack: os.path.join(work, "expected-%s.jsonl" % pack) for ps in LARGE_PACKS.values() for pack in ps}
    for e in engines:
        r = runner(e, tree)
        if r is None:
            continue
        build, run = r
        if build:
            _run(build)
        res["runner"][e] = {}
        for f, packs in LARGE_PACKS.items():
            for pack in packs:
                pd = os.path.join(tree, "packs", pack)
                argv = run + ["--function", f, "--pack", pd, "--steps", steps[f]]
                cell = dict(repeat(argv, a.large_repeats, parse=last_json), function=f)
                # Output check: the events and trace equal the reference runner's on this input.
                ev = os.path.join(work, "events-%s-%s.jsonl" % (e, pack))
                code = subprocess.run(argv + ["--events", ev, "--trace"], capture_output=True).returncode
                if code != 0:
                    cell["output"] = "exit %d" % code
                else:
                    cell["output"] = check_events(ev, refs[pack]) or "equal to %s" % REFERENCE
                res["runner"][e][pack] = cell
    res["load"] = {"start": load_start, "end": load_average()}
    os.makedirs(os.path.dirname(RESULTS), exist_ok=True)
    with open(RESULTS, "w", encoding="utf-8") as fh:
        json.dump(res, fh, indent=1, sort_keys=True)
        fh.write("\n")
    write_doc(load_json(RESULTS))   # the page always comes from the saved results, as `report` does


# ---------------------------------------------------------------------------
# The page


def _rate(n, cell):
    w = cell["wall_s"]
    return n / w["median"], n / w["max"], n / w["min"]


def _cell_rate(n, cell):
    if not cell.get("ok"):
        return "fails (exit %s)" % cell.get("exit")
    med, lo, hi = _rate(n, cell)
    return "%s (%s to %s)" % (_num(med), _num(lo), _num(hi))


def _cell_rss(cell):
    if not cell.get("ok"):
        return "–"
    r = cell["rss_kb"]
    return "%.0f (%.0f to %.0f)" % (r["median"] / 1024, r["min"] / 1024, r["max"] / 1024)


def _load(ld):
    if not ld or not ld.get("start"):
        return "not recorded"
    f = lambda v: ", ".join("%.1f" % x for x in v) if v else "–"  # noqa: E731
    return "%s / %s (other work on the machine during the run; a quiet machine reads near 0)" % (
        f(ld["start"]), f(ld.get("end")))


def _num(x):
    if x >= 100:
        return "{:,.0f}".format(x)
    if x >= 10:
        return "%.1f" % x
    return "%.2f" % x


def table(head, rows):
    out = ["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    out += ["| " + " | ".join(r) + " |" for r in rows]
    return "\n".join(out) + "\n"


def render(res):
    L = ["# Performance\n",
         "Status: Measured. Generated by "
         "`python3 -I tools/perf/perf.py baseline`; do not edit by hand. Method, the runner "
         "contract and what every number covers: [tools/perf/README.md](../tools/perf/README.md).\n"]
    m, v = res["machine"], res["versions"]
    L.append(table(["Item", "Value"], [
        ["commit measured", "`%s`" % res["commit"]],
        ["CPU", "%s, %d logical cores" % (m["cpu"], m["cores"])],
        ["memory", "%d GB" % m["memory_gb"]], ["OS", m["os"]],
        ["load average (1, 5, 15 min) at start / end", _load(res.get("load"))],
        ["repeats", "%d per vector command, %d per large run; each cell is the median, with the "
                    "range (slowest to fastest run) in brackets" % (res["repeats"], res["large_repeats"])],
    ] + [[k, "`%s`" % v[k]] for k in ("python", "rust", "go", "java", "cpp", "cmake", "erlang", "zig")]))
    L.append("Timings depend on the machine; compare numbers only within one page. "
             "CI does not check them.\n")

    L.append("## Conformance vectors, per function\n")
    c = res["counts"]
    L.append("Each engine's own vector test command for the function, after its build. "
             "Reports per second = the ingest steps of the function's scenario vectors "
             "divided by the command's wall time; the time also covers the load vectors, "
             "process start, JSON parsing and the comparison with the expected output "
             "(\"What each number covers\"). Peak memory is the process's maximum resident set, MB.\n")
    L.append(table(["Function", "Scenario vectors", "Ingest steps", "Ticks", "Load vectors"],
                   [[f, str(c[f]["vectors"]), str(c[f]["ingest"]), str(c[f]["tick"]),
                     str(c[f]["load_vectors"])] for f in FUNCTIONS]))
    engines = [e for e in ENGINES if e in res["vectors"]]
    L.append("Reports per second:\n")
    L.append(table(["Engine"] + FUNCTIONS,
                   [[e] + [_cell_rate(c[f]["ingest"], res["vectors"][e][f]) for f in FUNCTIONS]
                    for e in engines]))
    L.append("Peak memory, MB:\n")
    L.append(table(["Engine"] + FUNCTIONS,
                   [[e] + [_cell_rss(res["vectors"][e][f]) for f in FUNCTIONS] for e in engines]))

    L.append("## Large generated scenario\n")
    lg = res["large"]
    L.append("Input, written by the harness (`tools/perf/scenario.py`, seeded, deterministic): %s. "
             "The same reports go to every function; fuse's also carry `fuse.group` (the truth "
             "object). Packs: %s.\n" % (lg["description"], ", ".join(
                 "%s (%s)" % (", ".join("`%s`" % p for p in ps), f) for f, ps in LARGE_PACKS.items())))
    L.append("Through the vector commands: the harness writes the scenario as a vector of each pack, "
             "with the expected events, trace and snapshot from the Rust runner (as every vector, "
             "`tools/consensus.py`), into a copy of the "
             "tree that holds no other scenario vectors, builds every engine there and times the same "
             "commands. So each number also covers parsing that vector and comparing every step; "
             "vector file sizes: %s. A cell that fails is an engine that cannot run the large "
             "scenario through its vector command, or whose output differs from the Rust "
             "runner's on it beyond the tolerance of `spec/vector-format.md`.\n" % ", ".join(
                 "`%s` %.0f MB" % (p, s / 1e6) for p, s in sorted(lg["vector_bytes"].items())))
    lc = res["large_counts"]
    L.append("Reports per second:\n")
    L.append(table(["Engine"] + ["%s (%s reports, %d pack%s)" % (f, "{:,}".format(lc[f]["ingest"]), lc[f]["vectors"],
                                                    "" if lc[f]["vectors"] == 1 else "s")
                                 for f in FUNCTIONS],
                   [[e] + [_cell_rate(lc[f]["ingest"], res["large_vectors"][e][f]) for f in FUNCTIONS]
                    for e in engines]))
    L.append("Peak memory, MB:\n")
    L.append(table(["Engine"] + FUNCTIONS,
                   [[e] + [_cell_rss(res["large_vectors"][e][f]) for f in FUNCTIONS] for e in engines]))

    L.append("### Engine calls only (runner contract)\n")
    L.append("An engine's contract runner (README.md, \"Runner contract\") times its engine calls "
             "only: every `ingest` and `tick`, and `snapshot()`, not reading or parsing the input. "
             "Reports per second here = reports / run time; peak memory is the whole runner "
             "process. Its events, trace and snapshot are checked against the Rust runner's on the same "
             "input, with the comparison of `spec/vector-format.md` (numbers within 1e-6 relative).\n")
    rows = []
    for e in ENGINES:
        cells = res["runner"].get(e)
        if not cells:
            rows.append([e, "no runner yet", "–", "–", "–", "–", "–"])
            continue
        for pack in [p for ps in LARGE_PACKS.values() for p in ps if p in cells]:
            cell = cells[pack]
            if not cell.get("ok"):
                rows.append([e, pack, "fails (exit %s)" % cell.get("exit"), "–", "–", "–", "–"])
                continue
            n = cell["counters"]["ingest"]
            r = cell["run_s"]
            rows.append([e, pack, "%s (%s to %s)" % (_num(n / r["median"]), _num(n / r["max"]), _num(n / r["min"])),
                         "%.2f" % r["median"], "%.2f" % cell["parse_s"]["median"], _cell_rss(cell),
                         cell.get("output", "–")])
    L.append(table(["Engine", "Pack", "Reports per second", "Run, s", "Parse, s", "Peak memory, MB",
                    "Output"], rows))
    if os.path.exists(BEFORE):
        L.append(against_before(res, load_json(BEFORE)))
    L.append("## What each number covers\n")
    L.append(table(["Engine", "Vector command timed"], [[e, COVERS[e]] for e in engines]))
    failures = [(e, f, "large" if k == "large_vectors" else "vectors", res[k][e][f])
                for k in ("vectors", "large_vectors") for e in engines for f in FUNCTIONS
                if not res[k][e][f].get("ok")]
    if failures:
        L.append("## Runs that did not pass\n")
        L.append(table(["Engine", "Function", "Input", "Exit", "Last output"],
                       [[e, f, which, str(c.get("exit")),
                         "`%s`" % fail_line(c.get("tail", ""))[:160].replace("|", "\\|")
                         if c.get("tail", "").strip() else "–"]
                        for e, f, which, c in failures]))
    return "\n".join(L)


def _median_s(cell):
    return cell["wall_s"]["median"] if cell and cell.get("ok") else None


def against_before(res, before):
    """Each vector-command cell's median wall time against the pre-refactor baseline."""
    L = ["## Against the pre-refactor baseline\n",
         "Median wall time of each cell divided by the same cell of the baseline measured before "
         "the refactor (commit `%s`; load average at start / end %s). Below 1.00 is faster. A cell is "
         "marked **slower** when its fastest run now is slower than the slowest run before (the "
         "ranges do not overlap). The two runs were on the same machine under different load, "
         "so read a ratio near 1 as no change.\n" % (before["commit"], _load(before.get("load")))]
    engines = [e for e in ENGINES if e in res["vectors"]]
    for key, title in (("vectors", "Conformance vectors"), ("large_vectors", "Large scenario, vector commands")):
        rows = []
        for e in engines:
            row = [e]
            for f in FUNCTIONS:
                a, b = res[key][e][f], before.get(key, {}).get(e, {}).get(f)
                ma, mb = _median_s(a), _median_s(b)
                if ma is None or mb is None:
                    row.append("now fails" if mb is not None else ("new" if ma is not None else "–"))
                    continue
                slower = a["wall_s"]["min"] > b["wall_s"]["max"]
                row.append(("**%.2f slower**" if slower else "%.2f") % (ma / mb))
            rows.append(row)
        L.append("%s:\n" % title)
        L.append(table(["Engine"] + FUNCTIONS, rows))
    return "\n".join(L)


def write_doc(res):
    with open(DOC, "w", encoding="utf-8") as fh:
        fh.write(render(res))
    print("wrote %s" % DOC)


# ---------------------------------------------------------------------------
# Smoke (CI)


def smoke(_a):
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        steps, desc = write_steps(d, "smoke")
        print("smoke scenario: " + desc)
        for f, packs in LARGE_PACKS.items():
            for pack in packs:
                out = subprocess.run([os.path.join(ROOT, "engines", "python", "runner", "run"),
                                      "--function", f, "--pack", os.path.join(ROOT, "packs", pack),
                                      "--steps", steps[f], "--events", os.path.join(d, pack + ".jsonl")],
                                     check=True, capture_output=True, text=True).stdout
                c = last_json(out)
                assert c["ingest"] > 0 and c["steps"] == c["ingest"] + c["tick"], c
                print("  %-22s %d reports, %d events" % (pack, c["ingest"], c["events"]))
        cmds = build_engine("python", ROOT, d)
        wall, rss, code, tail = measure(cmds["filter"][0], cwd=cmds["filter"][1], env=cmds["filter"][2])
        if code != 0:
            raise SystemExit("python filter vector command failed:\n" + tail)
        print("  python filter vector command: ok (%.2f s, %d KB)" % (wall, rss))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate")
    g.add_argument("--size", default="large", choices=sorted(scenario.SIZES))
    g.add_argument("--out", required=True)
    b = sub.add_parser("baseline")
    b.add_argument("--repeats", type=int, default=10)
    b.add_argument("--large-repeats", type=int, default=3)
    b.add_argument("--engines")
    b.add_argument("--work", default=os.path.join(ROOT, "build", "perf"))
    r = sub.add_parser("report")
    r.add_argument("--check", action="store_true")
    sub.add_parser("smoke")
    a = ap.parse_args()
    if a.cmd == "generate":
        paths, desc = write_steps(a.out, a.size)
        print(desc)
        for f, p in paths.items():
            print("  %s: %s" % (f, p))
    elif a.cmd == "baseline":
        baseline(a)
    elif a.cmd == "report":
        res = load_json(RESULTS)
        text = render(res)
        if a.check:
            with open(DOC, encoding="utf-8") as fh:
                current = fh.read()
            if current != text:
                raise SystemExit("docs/performance.md is not what perf.py report writes")
            print("docs/performance.md is current")
        else:
            write_doc(res)
    elif a.cmd == "smoke":
        smoke(a)


if __name__ == "__main__":
    main()
