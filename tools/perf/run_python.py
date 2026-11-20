#!/usr/bin/env python3
"""The perf runner contract (README.md, "Runner contract"), for the Python engine.

    python3 -I tools/perf/run_python.py --function F --pack DIR --steps FILE
                                        [--events FILE] [--trace]

It imports the engine and calls it; it does not change it. The run clock
covers the engine calls only: from before the first `ingest`/`tick` to after
the last, plus `snapshot()`. Reading and parsing the steps file is timed
apart (`parse_ns`). Peak memory is measured by the harness from the OS.
"""

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "engines", "python", "src"))

MODULES = {"correlate": "goat_correlator", "filter": "goat_filter", "fuse": "goat_fuse",
           "quality": "goat_quality"}


def engine_for(function, pack_dir):
    mod = __import__(MODULES[function])
    make = getattr(mod, "make_engine", None) or mod.Engine   # correlate, filter: make_engine; fuse, quality: Engine
    return make(mod.load_pack(pack_dir))


def vector(function, pack_dir, steps, name, pack):
    """A scenario vector (spec/vector-format.md) of `steps` on one pack: the expected events,
    trace and snapshot are what the Python engine returns, as tools/make-vectors.py records."""
    eng = engine_for(function, pack_dir)
    out = []
    for st in steps:
        if "ingest" in st:
            events, trace = eng.ingest(st["ingest"])
            out.append({"ingest": st["ingest"], "expect": events, "trace": trace})
        else:
            events, trace = eng.tick(st["tick"])
            out.append({"tick": st["tick"], "expect": events, "trace": trace})
    return {"name": name, "pack": pack, "steps": out, "snapshot": eng.snapshot()}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--function", required=True, choices=sorted(MODULES))
    ap.add_argument("--pack", required=True)
    ap.add_argument("--steps", required=True)
    ap.add_argument("--events")
    ap.add_argument("--trace", action="store_true")
    a = ap.parse_args(argv)

    t0 = time.perf_counter_ns()
    with open(a.steps, encoding="utf-8") as f:
        doc = json.load(f)
    steps = doc["steps"]
    t1 = time.perf_counter_ns()
    eng = engine_for(a.function, a.pack)
    t2 = time.perf_counter_ns()

    n_ing = n_tick = n_ev = n_tr = 0
    outs = [] if a.events else None
    r0 = time.perf_counter_ns()
    for st in steps:
        if "ingest" in st:
            events, trace = eng.ingest(st["ingest"])
            n_ing += 1
        else:
            events, trace = eng.tick(st["tick"])
            n_tick += 1
        n_ev += len(events)
        n_tr += len(trace)
        if outs is not None:
            outs.append((events, trace))
    snap = eng.snapshot()
    r1 = time.perf_counter_ns()

    if a.events:
        with open(a.events, "w", encoding="utf-8") as f:
            for i, (events, trace) in enumerate(outs):
                rec = {"step": i, "events": events}
                if a.trace:
                    rec["trace"] = trace
                f.write(json.dumps(rec, separators=(",", ":")) + "\n")
            f.write(json.dumps({"snapshot": snap}, separators=(",", ":")) + "\n")
    print(json.dumps({"engine": "python", "function": a.function, "pack": os.path.basename(a.pack.rstrip("/")),
                      "steps": len(steps), "ingest": n_ing, "tick": n_tick, "events": n_ev,
                      "trace_records": n_tr, "parse_ns": t1 - t0, "load_ns": t2 - t1,
                      "run_ns": r1 - r0}, separators=(",", ":")))


if __name__ == "__main__":
    main()
