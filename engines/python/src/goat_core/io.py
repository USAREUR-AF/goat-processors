"""Input and output: the pack directory, the steps file, the events file and
the command-line runner (tools/perf/README.md, Runner contract).

The engines never read a file or a clock; this module does both, and only
around the engine calls."""

import json
import os
import sys
import time


class StepsError(Exception):
    """A steps file that does not parse."""


def read_pack_def(directory):
    """The text of <directory>/pack.def."""
    with open(os.path.join(directory, "pack.def"), encoding="utf-8") as f:
        return f.read()


def parse_steps(text):
    """spec/vector-format.md: the steps of a steps file (a JSON object whose
    `steps` is a list of objects, each holding `ingest` or `tick`). Every
    other key is ignored. Raises StepsError."""
    try:
        doc = json.loads(text)
    except (ValueError, RecursionError) as e:
        raise StepsError("not JSON: %s" % e)
    if not isinstance(doc, dict) or not isinstance(doc.get("steps"), list):
        raise StepsError("not an object with a list of steps")
    steps = doc["steps"]
    for i, s in enumerate(steps):
        if not isinstance(s, dict) or ("ingest" not in s and "tick" not in s):
            raise StepsError("step %d holds neither ingest nor tick" % i)
    return steps


def read_steps(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise StepsError(str(e))
    return parse_steps(text)


def run_steps(engine, steps):
    """The runner's engine calls: ingest or tick per step in order, then
    snapshot(). Returns ([(events, trace) per step], snapshot)."""
    out = []
    append = out.append
    ingest, tick = engine.ingest, engine.tick
    for s in steps:
        append(ingest(s["ingest"]) if "ingest" in s else tick(s["tick"]))
    return out, engine.snapshot()


def write_events(path, outputs, snapshot, with_trace):
    """Runner contract, Events file: one line per step, then the snapshot."""
    with open(path, "w", encoding="utf-8") as f:
        for i, (events, trace) in enumerate(outputs):
            line = {"step": i, "events": events}
            if with_trace:
                line["trace"] = trace
            f.write(json.dumps(line) + "\n")
        f.write(json.dumps({"snapshot": snapshot}) + "\n")


def _args(argv):
    out = {"events": None, "trace": False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--trace":
            out["trace"] = True
            i += 1
        elif a in ("--function", "--pack", "--steps", "--events") and i + 1 < len(argv):
            out[a[2:]] = argv[i + 1]
            i += 2
        else:
            raise ValueError("unknown or incomplete argument: %s" % a)
    for k in ("function", "pack", "steps"):
        if k not in out:
            raise ValueError("missing --%s" % k)
    return out


def main(argv, functions):
    """The runner. `functions` maps a function name to its entry point
    (goat_core.FUNCTIONS). Returns the exit status."""
    try:
        args = _args(argv)
    except ValueError as e:
        sys.stderr.write("run: %s\n" % e)
        return 2
    fn = functions.get(args["function"])
    if fn is None:
        sys.stderr.write("run: unknown function %s\n" % args["function"])
        return 2

    t0 = time.monotonic_ns()
    try:
        steps = read_steps(args["steps"])
    except StepsError as e:
        sys.stderr.write("run: steps file does not parse: %s\n" % e)
        return 1
    t1 = time.monotonic_ns()
    try:
        engine = fn.open(args["pack"])
    except Exception as e:  # PackError, or no pack.def
        sys.stderr.write("run: pack does not load: %s\n" % e)
        return 1
    t2 = time.monotonic_ns()
    outputs, snapshot = run_steps(engine, steps)
    t3 = time.monotonic_ns()

    if args["events"] is not None:
        write_events(args["events"], outputs, snapshot, args["trace"])
    n_ingest = sum(1 for s in steps if "ingest" in s)
    sys.stdout.write(json.dumps({
        "engine": "python", "function": args["function"],
        "pack": os.path.basename(os.path.normpath(args["pack"])),
        "steps": len(steps), "ingest": n_ingest, "tick": len(steps) - n_ingest,
        "events": sum(len(e) for e, _ in outputs),
        "trace_records": sum(len(t) for _, t in outputs),
        "parse_ns": t1 - t0, "load_ns": t2 - t1, "run_ns": t3 - t2,
    }) + "\n")
    return 0
