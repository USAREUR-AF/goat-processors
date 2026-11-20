"""Command-line runner of the Python engine: tools/perf/README.md, "Runner contract"."""

import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))


def _engine_factory(function):
    if function == "correlate":
        from goat_correlator import load_pack, make_engine
        return load_pack, make_engine
    if function == "filter":
        from goat_filter import load_pack, make_engine
        return load_pack, make_engine
    if function == "fuse":
        from goat_fuse import Engine, load_pack
        return load_pack, Engine
    if function == "quality":
        from goat_quality import Engine, load_pack
        return load_pack, Engine
    return None


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


def main(argv):
    try:
        args = _args(argv)
    except ValueError as e:
        sys.stderr.write("run: %s\n" % e)
        return 2
    factory = _engine_factory(args["function"])
    if factory is None:
        sys.stderr.write("run: unknown function %s\n" % args["function"])
        return 2
    load_pack, make_engine = factory

    t0 = time.monotonic_ns()
    try:
        with open(args["steps"], encoding="utf-8") as f:
            doc = json.load(f)
        steps = doc["steps"]
        if not isinstance(steps, list) or not all(
                isinstance(s, dict) and ("ingest" in s or "tick" in s) for s in steps):
            raise ValueError("steps is not a list of ingest or tick steps")
    except (OSError, ValueError, KeyError, TypeError) as e:
        sys.stderr.write("run: steps file does not parse: %s\n" % e)
        return 1
    t1 = time.monotonic_ns()
    try:
        engine = make_engine(load_pack(args["pack"]))
    except Exception as e:  # PackError or a missing file
        sys.stderr.write("run: pack does not load: %s\n" % e)
        return 1
    t2 = time.monotonic_ns()

    outputs = []
    n_ingest = n_tick = n_events = n_trace = 0
    for s in steps:
        if "ingest" in s:
            events, trace = engine.ingest(s["ingest"])
            n_ingest += 1
        else:
            events, trace = engine.tick(s["tick"])
            n_tick += 1
        n_events += len(events)
        n_trace += len(trace)
        outputs.append((events, trace))
    snapshot = engine.snapshot()
    t3 = time.monotonic_ns()

    if args["events"] is not None:
        with open(args["events"], "w", encoding="utf-8") as f:
            for i, (events, trace) in enumerate(outputs):
                line = {"step": i, "events": events}
                if args["trace"]:
                    line["trace"] = trace
                f.write(json.dumps(line) + "\n")
            f.write(json.dumps({"snapshot": snapshot}) + "\n")

    sys.stdout.write(json.dumps({
        "engine": "python", "function": args["function"],
        "pack": os.path.basename(os.path.normpath(args["pack"])),
        "steps": len(steps), "ingest": n_ingest, "tick": n_tick,
        "events": n_events, "trace_records": n_trace,
        "parse_ns": t1 - t0, "load_ns": t2 - t1, "run_ns": t3 - t2,
    }) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
