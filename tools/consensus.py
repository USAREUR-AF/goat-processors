#!/usr/bin/env python3
"""Run the seven engines on a vector and compare them with it.

The vector generators (tools/make-*-vectors.py) use this module to compute a
candidate vector with the Rust engine and to accept it only when every engine
agrees. It drives each engine only through its command-line runner,
engines/<lang>/runner/build and run (tools/perf/README.md, "Runner contract"),
and compares with exactly the comparison of spec/vector-format.md.

As a command, it checks committed vectors against every engine:

    python3 -I tools/consensus.py [--engines rust,go,...] packs/correlate-gnn/vectors/*.json

and prints every disagreement as engine, step, field, expected, got.
Standard library only.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINES = ("python", "rust", "go", "java", "cpp", "erlang", "zig")

# The test command of each engine, as README.md lists them. They run every
# scenario vector and every load vector of every function.
TEST_COMMANDS = {
    "python": ("engines/python", "PYTHONPATH=src python3 -m unittest discover -s tests"),
    "rust": ("engines/rust", "cargo test"),
    "go": ("engines/go", "go test ./..."),
    "java": (".", "engines/java/build.sh"),
    "cpp": (".", "cmake -S engines/cpp -B build/cpp && cmake --build build/cpp && ctest --test-dir build/cpp"),
    "erlang": (".", "engines/erlang/run_tests"),
    "zig": ("engines/zig", "zig build test"),
}

_built = set()


class RunnerError(Exception):
    pass


def build(engine):
    """Build an engine's runner, once per process."""
    if engine in _built:
        return
    script = os.path.join(ROOT, "engines", engine, "runner", "build")
    if os.path.exists(script):
        p = subprocess.run([script], cwd=ROOT, capture_output=True, text=True)
        if p.returncode != 0:
            raise RunnerError("%s: runner build failed:\n%s%s" % (engine, p.stdout, p.stderr))
    _built.add(engine)


def run(engine, function, pack_dir, steps):
    """Run `steps` (a list of {"ingest": report} or {"tick": now_ms}) on a new
    engine of `pack_dir`. Return (results, snapshot), results being one
    {"events": [...], "trace": [...]} per step."""
    build(engine)
    with tempfile.TemporaryDirectory(prefix="goat-consensus-") as tmp:
        steps_path = os.path.join(tmp, "steps.json")
        events_path = os.path.join(tmp, "events.jsonl")
        with open(steps_path, "w", encoding="utf-8") as f:
            json.dump({"steps": steps}, f)
        p = subprocess.run([os.path.join(ROOT, "engines", engine, "runner", "run"),
                            "--function", function, "--pack", pack_dir, "--steps", steps_path,
                            "--events", events_path, "--trace"],
                           cwd=ROOT, capture_output=True, text=True)
        if p.returncode != 0:
            raise RunnerError("%s: runner exit %d: %s" % (engine, p.returncode, p.stderr.strip()))
        with open(events_path, encoding="utf-8") as f:
            lines = [json.loads(line) for line in f if line.strip()]
    if not lines or "snapshot" not in lines[-1] or len(lines) != len(steps) + 1:
        raise RunnerError("%s: events file has %d lines for %d steps" % (engine, len(lines), len(steps)))
    results = []
    for i, line in enumerate(lines[:-1]):
        if line.get("step") != i:
            raise RunnerError("%s: events line %d is step %r" % (engine, i, line.get("step")))
        results.append({"events": line["events"], "trace": line["trace"]})
    return results, lines[-1]["snapshot"]


def loads(engine, function, pack_def):
    """Whether the text of a pack.def loads: the runner, given the pack and no
    steps, exits 0 (a pack that does not load exits non-zero)."""
    build(engine)
    with tempfile.TemporaryDirectory(prefix="goat-consensus-") as tmp:
        pack_dir = os.path.join(tmp, "pack")
        os.mkdir(pack_dir)
        with open(os.path.join(pack_dir, "pack.def"), "w", encoding="utf-8", newline="") as f:
            f.write(pack_def)
        steps_path = os.path.join(tmp, "steps.json")
        with open(steps_path, "w", encoding="utf-8") as f:
            f.write('{"steps": []}')
        p = subprocess.run([os.path.join(ROOT, "engines", engine, "runner", "run"),
                            "--function", function, "--pack", pack_dir, "--steps", steps_path],
                           cwd=ROOT, capture_output=True, text=True)
        return p.returncode == 0


def clean(x):
    """Write negative zero as zero."""
    if isinstance(x, float):
        return 0.0 if x == 0 else x
    if isinstance(x, list):
        return [clean(v) for v in x]
    if isinstance(x, dict):
        return {k: clean(v) for k, v in x.items()}
    return x


def compute(pack_name, steps):
    """A candidate vector's outputs, computed by the Rust engine: for steps
    given as (kind, arg) pairs, return ([(events, trace) per step], snapshot)
    with negative zero written as zero."""
    results, snapshot = run("rust", function_of(pack_name), os.path.join(ROOT, "packs", pack_name),
                            [{kind: arg} for kind, arg in steps])
    return [(clean(r["events"]), clean(r["trace"])) for r in results], clean(snapshot)


def vector_steps(steps, results):
    """The steps of a vector: each input with its expected events and trace."""
    return [{kind: arg, "expect": ev, "trace": tr} for (kind, arg), (ev, tr) in zip(steps, results)]


def accept(vectors, consensus=True):
    """The names of the candidate vectors every engine agrees with, from a
    dict {name: vector}; print each disagreement. With consensus False,
    accept them all without running the engines."""
    if not consensus:
        return set(vectors)
    found = check(vectors)
    for name in vectors:
        report(name, found[name])
    return {name for name in vectors if not found[name]}


def write_json(path, obj, sort_keys=False):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, sort_keys=sort_keys)
        f.write("\n")


def write_vector(path, vec):
    """Write a scenario vector in canonical bytes: keys sorted, so the file
    depends on no engine's map order (key order is not engine behavior)."""
    write_json(path, vec, sort_keys=True)


def write_load_vectors(function, load_dir, loads_, consensus=True):
    """Write the load vectors (name, pack_def, expect_error) under load_dir.
    The expected result is stated by hand; the Rust runner must agree with
    it, else the vector is refused. With consensus, every engine's own test
    command must then pass; if one fails, the previous files are put back.
    Return (paths written, ok)."""
    ok, old, written = True, {}, []
    for name, text, expect_error in loads_:
        if loads("rust", function, text) == expect_error:
            print("load %s: rust %s, decided %s" % (
                name, "loads it" if expect_error else "refuses it",
                "error" if expect_error else "loads"))
            ok = False
            continue
        path = os.path.join(load_dir, name + ".json")
        if os.path.exists(path):
            with open(path, "rb") as f:
                old[path] = f.read()
        write_json(path, {"name": name, "pack_def": text, "expect_error": expect_error})
        written.append(path)
    if consensus:
        failed = run_tests()
        for engine, tail in failed:
            print("%s: its test command fails:\n%s" % (engine, tail))
        if failed:
            ok = False
            for path in written:
                if path in old:
                    with open(path, "wb") as f:
                        f.write(old[path])
                else:
                    os.remove(path)
    return written, ok


# --- the comparison of spec/vector-format.md --------------------------------

def _number(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def differences(want, got, field=""):
    """Every place where `got` differs from `want`: a list of (field, want, got)."""
    if _number(want) and _number(got):
        if abs(got - want) <= 1e-6 * max(1.0, abs(want)):
            return []
        return [(field, want, got)]
    if isinstance(want, dict) and isinstance(got, dict):
        out = []
        for k in want:
            if k not in got:
                out.append(("%s.%s" % (field, k), want[k], "<absent>"))
            else:
                out += differences(want[k], got[k], "%s.%s" % (field, k))
        for k in got:
            if k not in want:
                out.append(("%s.%s" % (field, k), "<absent>", got[k]))
        return out
    if isinstance(want, list) and isinstance(got, list):
        if len(want) != len(got):
            return [(field + ".length", len(want), len(got))]
        out = []
        for i, (w, g) in enumerate(zip(want, got)):
            out += differences(w, g, "%s[%d]" % (field, i))
        return out
    if isinstance(want, str) and isinstance(got, str):
        return [] if want.encode("utf-8") == got.encode("utf-8") else [(field, want, got)]
    if want is None or isinstance(want, bool):
        return [] if got is want else [(field, want, got)]
    return [(field, want, got)]


def disagreements(engine, vector):
    """Run one engine on a vector's steps and compare with its expected
    events, trace and snapshot: a list of (engine, step, field, expected,
    got), step being None for the snapshot."""
    steps = [{k: s[k] for k in ("ingest", "tick") if k in s} for s in vector["steps"]]
    try:
        results, snapshot = run(engine, function_of(vector["pack"]),
                                os.path.join(ROOT, "packs", vector["pack"]), steps)
    except RunnerError as e:
        return [(engine, None, "runner", "a run", str(e))]
    out = []
    for i, (s, r) in enumerate(zip(vector["steps"], results)):
        out += [(engine, i, "expect" + f, w, g) for f, w, g in differences(s["expect"], r["events"])]
        out += [(engine, i, "trace" + f, w, g) for f, w, g in differences(s["trace"], r["trace"])]
    out += [(engine, None, "snapshot" + f, w, g) for f, w, g in differences(vector["snapshot"], snapshot)]
    return out


def check(vectors, engines=ENGINES):
    """Every engine on every vector of a dict {name: vector}, in parallel.
    Return {name: disagreements}."""
    for e in engines:
        build(e)  # each once, before the parallel runs
    jobs = [(name, e) for name in vectors for e in engines]
    with ThreadPoolExecutor(max(4, os.cpu_count() or 1)) as pool:
        found = list(pool.map(lambda j: disagreements(j[1], vectors[j[0]]), jobs))
    out = {name: [] for name in vectors}
    for (name, _), d in zip(jobs, found):
        out[name] += d
    return out


def report(name, disagreements):
    """Print each disagreement as engine, step, field, expected, got."""
    for engine, step, field, want, got in disagreements:
        print("%s: %s, step %s, %s: expected %s, got %s" % (
            name, engine, "snapshot" if step is None else step, field,
            json.dumps(want), json.dumps(got)))


def run_tests(engines=ENGINES):
    """Run each engine's own test command (README.md). Return the engines
    whose command failed, each with the tail of its output."""
    failed = []
    for e in engines:
        cwd, cmd = TEST_COMMANDS[e]
        p = subprocess.run(cmd, shell=True, cwd=os.path.join(ROOT, cwd),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if p.returncode != 0:
            failed.append((e, p.stdout[-2000:]))
    return failed


def function_of(pack_name):
    return pack_name.split("-", 1)[0]


def main(argv):
    engines = ENGINES
    if argv[:1] == ["--engines"]:
        engines = tuple(argv[1].split(","))
        argv = argv[2:]
    if not argv or any(e not in ENGINES for e in engines):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    vectors = {}
    for path in argv:
        with open(path, encoding="utf-8") as f:
            vectors[os.path.relpath(os.path.abspath(path), ROOT)] = json.load(f)
    found = check(vectors, engines)
    for name in vectors:
        report(name, found[name])
    bad = sum(1 for d in found.values() if d)
    print("%d vectors, %d with a disagreement, engines %s" % (len(argv), bad, ",".join(engines)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
