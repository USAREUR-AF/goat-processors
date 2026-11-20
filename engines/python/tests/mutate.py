"""Mutation testing of the Python engine, standard library only.

    python3 tests/mutate.py [--jobs N] [--files a.py,b.py] [--suite vectors|all]
                            [--only-survivors FILE] [--out FILE] [--limit N]

Each mutant changes one operator or one constant in one source file of
src/goat_core (the engine; the goat_* re-export packages hold no logic):

  comparison   <  <=  >  >=  ==  !=  in  not in  is  is not  (each to its pair)
  arithmetic   +  -  *  /  //  %  **  (+ and -, * and /, // and *, % and //, ** and *),
               also in augmented assignment (+= and -=, ...)
  boolean      and  or  (each to the other); `not x` to `x`; `-x` to `x`
  constant     an integer n to n + 1; a float x to x + 1 (0.0) or 2x; True and False

Docstrings, strings, and everything inside a `raise` (error messages) are
not mutated. The mutated module is written with ast.unparse, and every file
is first checked unmutated (unparse alone must pass).

A mutant is killed when the suite fails or runs out of time (a mutant may
loop forever). --suite vectors (the default) runs the scenario and load
vectors of the functions the file serves: the question is whether the
vectors catch real faults. --suite all runs every test of tests/.
--only-survivors re-runs the survivors listed in an earlier --out file.
Writes a JSON report (--out) and prints the kill rate and every survivor."""

import argparse
import ast
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", "src"))
ENGINE = os.path.join(SRC, "goat_core")

VECTORS = {
    "correlate": ["test_vectors"],
    "filter": ["test_filter_vectors"],
    "fuse": ["test_fuse_vectors"],
    "quality": ["test_quality_vectors"],
}
ALL_VECTORS = sum(VECTORS.values(), [])
SERVES = {
    "tracks.py": "correlate", "gate.py": "correlate", "correlate.py": "correlate",
    "correlate_pack.py": "correlate", "confirm.py": "correlate", "assign.py": "correlate",
    "ranking.py": "correlate", "bias.py": "correlate",
    "filter.py": "filter", "fuse.py": "fuse", "quality.py": "quality",
}

CMP = {ast.Lt: ast.LtE, ast.LtE: ast.Lt, ast.Gt: ast.GtE, ast.GtE: ast.Gt, ast.Eq: ast.NotEq,
       ast.NotEq: ast.Eq, ast.In: ast.NotIn, ast.NotIn: ast.In, ast.Is: ast.IsNot, ast.IsNot: ast.Is}
BIN = {ast.Add: ast.Sub, ast.Sub: ast.Add, ast.Mult: ast.Div, ast.Div: ast.Mult, ast.FloorDiv: ast.Mult,
       ast.Mod: ast.FloorDiv, ast.Pow: ast.Mult}
BOOL = {ast.And: ast.Or, ast.Or: ast.And}
SYMBOL = {ast.Lt: "<", ast.LtE: "<=", ast.Gt: ">", ast.GtE: ">=", ast.Eq: "==", ast.NotEq: "!=",
          ast.In: "in", ast.NotIn: "not in", ast.Is: "is", ast.IsNot: "is not", ast.Add: "+",
          ast.Sub: "-", ast.Mult: "*", ast.Div: "/", ast.FloorDiv: "//", ast.Mod: "%", ast.Pow: "**",
          ast.And: "and", ast.Or: "or"}


def _skipped_nodes(tree):
    """Nodes not to mutate: docstrings, raise statements, string formatting."""
    skip = set()
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if isinstance(body, list) and body and isinstance(body[0], ast.Expr) \
                and isinstance(body[0].value, ast.Constant) and isinstance(body[0].value.value, str):
            skip.add(id(body[0].value))
        if isinstance(node, (ast.Raise, ast.JoinedStr)):
            skip.update(id(n) for n in ast.walk(node))
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mod) and isinstance(node.left, ast.Constant) \
                and isinstance(node.left.value, str):
            skip.update(id(n) for n in ast.walk(node))
    return skip


def mutation_points(tree):
    """Every (node index in ast.walk order, kind, description) of a module."""
    skip = _skipped_nodes(tree)
    out = []
    for i, node in enumerate(ast.walk(tree)):
        if id(node) in skip:
            continue
        line = getattr(node, "lineno", 0)
        if isinstance(node, ast.Compare):
            for k, op in enumerate(node.ops):
                if type(op) in CMP:
                    out.append((i, ("cmp", k), "line %d: %s -> %s" % (line, SYMBOL[type(op)], SYMBOL[CMP[type(op)]])))
        elif isinstance(node, (ast.BinOp, ast.AugAssign)) and type(node.op) in BIN:
            out.append((i, ("bin",), "line %d: %s -> %s" % (line, SYMBOL[type(node.op)], SYMBOL[BIN[type(node.op)]])))
        elif isinstance(node, ast.BoolOp):
            out.append((i, ("bool",), "line %d: %s -> %s" % (line, SYMBOL[type(node.op)], SYMBOL[BOOL[type(node.op)]])))
        elif isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.Not, ast.USub)):
            out.append((i, ("unary",), "line %d: drop %s" % (line, "not" if isinstance(node.op, ast.Not) else "-")))
        elif isinstance(node, ast.Constant):
            v = node.value
            if isinstance(v, bool):
                out.append((i, ("const",), "line %d: %r -> %r" % (line, v, not v)))
            elif isinstance(v, int):
                out.append((i, ("const",), "line %d: %r -> %r" % (line, v, v + 1)))
            elif isinstance(v, float):
                out.append((i, ("const",), "line %d: %r -> %r" % (line, v, v + 1.0 if v == 0.0 else 2 * v)))
    return out


class _Unary(ast.NodeTransformer):
    def __init__(self, target):
        self.target = target

    def visit_UnaryOp(self, node):
        if node is self.target:
            return self.generic_visit(node).operand
        return self.generic_visit(node)


def mutate(source, index, kind):
    """The source with mutation (index, kind) applied."""
    tree = ast.parse(source)
    node = list(ast.walk(tree))[index]
    if kind[0] == "cmp":
        node.ops[kind[1]] = CMP[type(node.ops[kind[1]])]()
    elif kind[0] == "bin":
        node.op = BIN[type(node.op)]()
    elif kind[0] == "bool":
        node.op = BOOL[type(node.op)]()
    elif kind[0] == "unary":
        tree = _Unary(node).visit(tree)
    else:
        v = node.value
        if isinstance(v, bool):
            node.value = not v
        elif isinstance(v, int):
            node.value = v + 1
        else:
            node.value = v + 1.0 if v == 0.0 else 2 * v
    return ast.unparse(ast.fix_missing_locations(tree))


def suite_for(filename, suite):
    if suite == "all":
        return None
    f = SERVES.get(filename)
    return VECTORS[f] if f else ALL_VECTORS


def run_suite(src_dir, modules, timeout):
    """True when the suite passes."""
    env = dict(os.environ, PYTHONPATH=src_dir, GOAT_FUZZ_CASES="300", GOAT_FUZZ_SECONDS="1")
    if modules:
        cmd = [sys.executable, "-m", "unittest", "-f", "-q"] + modules
    else:
        cmd = [sys.executable, "-m", "unittest", "discover", "-f", "-q", "-s", HERE]
    try:
        p = subprocess.run(cmd, cwd=HERE, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        return False
    return p.returncode == 0


class Worker:
    """A private copy of src/ per thread, one file swapped per mutant."""

    def __init__(self, root):
        self.dir = tempfile.mkdtemp(prefix="goat-mutate-", dir=root)
        shutil.copytree(SRC, os.path.join(self.dir, "src"), ignore=shutil.ignore_patterns("__pycache__"))
        self.src = os.path.join(self.dir, "src")

    def run(self, filename, text, original, modules, timeout):
        path = os.path.join(self.src, "goat_core", filename)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        try:
            return run_suite(self.src, modules, timeout)
        finally:
            with open(path, "w", encoding="utf-8") as f:
                f.write(original)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    ap.add_argument("--files", default="")
    ap.add_argument("--suite", choices=("vectors", "all"), default="vectors")
    ap.add_argument("--only-survivors", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--timeout", type=float, default=120.0)
    args = ap.parse_args(argv)

    files = sorted(f for f in os.listdir(ENGINE) if f.endswith(".py"))
    if args.files:
        files = [f for f in files if f in args.files.split(",")]
    sources = {f: open(os.path.join(ENGINE, f), encoding="utf-8").read() for f in files}

    jobs = []
    if args.only_survivors:
        with open(args.only_survivors, encoding="utf-8") as fh:
            for s in json.load(fh)["survivors"]:
                if s["file"] in sources:
                    jobs.append((s["file"], s["index"], tuple(s["kind"]), s["what"]))
    else:
        for f in files:
            for index, kind, what in mutation_points(ast.parse(sources[f])):
                jobs.append((f, index, kind, what))
    if args.limit:
        jobs = jobs[:args.limit]

    root = tempfile.mkdtemp(prefix="goat-mutate-")
    workers = [Worker(root) for _ in range(args.jobs)]
    free = list(workers)
    start = time.monotonic()
    try:
        # The unmutated files, through ast.unparse, must pass.
        for f in files:
            w = workers[0]
            if not w.run(f, ast.unparse(ast.parse(sources[f])), sources[f], suite_for(f, args.suite),
                         args.timeout):
                print("unparse alone fails the suite for %s" % f)
                return 2

        def one(job):
            f, index, kind, what = job
            w = free.pop()
            try:
                text = mutate(sources[f], index, kind)
                ok = w.run(f, text, sources[f], suite_for(f, args.suite), args.timeout)
            finally:
                free.append(w)
            return job, not ok

        results = []
        with ThreadPoolExecutor(max_workers=args.jobs) as ex:
            for n, (job, killed) in enumerate(ex.map(one, jobs), 1):
                results.append((job, killed))
                if n % 100 == 0:
                    print("%d/%d mutants, %.0f s" % (n, len(jobs), time.monotonic() - start), flush=True)
    finally:
        shutil.rmtree(root, ignore_errors=True)

    killed = sum(1 for _, k in results if k)
    survivors = [{"file": f, "index": i, "kind": list(kind), "what": what}
                 for (f, i, kind, what), k in results if not k]
    per_file = {}
    for (f, _, _, _), k in results:
        t = per_file.setdefault(f, [0, 0])
        t[0] += 1
        t[1] += 1 if k else 0
    print("\nsuite: %s; %d mutants, %d killed, %d survived: kill rate %.1f%% (%.0f s)"
          % (args.suite, len(results), killed, len(survivors), 100.0 * killed / max(1, len(results)),
             time.monotonic() - start))
    for f in sorted(per_file):
        n, k = per_file[f]
        print("  %-18s %4d mutants %4d killed %5.1f%%" % (f, n, k, 100.0 * k / n))
    for s in survivors:
        print("SURVIVED %s %s" % (s["file"], s["what"]))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump({"suite": args.suite, "mutants": len(results), "killed": killed,
                       "per_file": per_file, "survivors": survivors}, fh, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
