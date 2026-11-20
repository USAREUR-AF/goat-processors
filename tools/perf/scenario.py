"""The large generated input: one seeded scenario, the same report stream for every function.

Built with the bench's scenario model (tools/bench/scenarios.py): truth motion,
sensors with noise, detection, latency, jitter, false tracks, track-number
swaps and drops, and the time-quality keys. Deterministic: the same seed gives
the same bytes in every Python version (no float formatting depends on the
platform; the generator draws only from its own splitmix64).

| Function | What each report carries in addition |
|---|---|
| correlate, filter, quality | the bench report keys (`track.source_id`, `uid`, `time_ms`, `lat`, `lon`, `ce`, `hae`, `course`, `speed_ms`, `type`, `time_state`, `time_error_ms`) |
| fuse | also `fuse.group`: the truth object the track reports (false tracks have none) |
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools", "bench"))
import scenarios as S  # noqa: E402

SEED = 20261120

# Name -> (objects, duration in s). "large" is the baseline input; "smoke" is
# the short one CI runs.
SIZES = {"large": (12, 600), "smoke": (3, 60)}


def build(size="large", seed=SEED):
    """(steps, labels, description) of the generated scenario."""
    n_obj, duration = SIZES[size]
    r = S.Rng(seed)
    objs = []
    for j in range(n_obj):
        kind = r.choice(["straight", "straight", "turn", "turn", "accel", "still"])
        speed = 0.0 if kind == "still" else r.uniform(80, 280)
        moves = []
        if kind == "turn":
            for t0 in range(int(r.uniform(10, 60)), duration - 40, 120):
                moves.append((t0, t0 + 30, r.choice([3.0, -3.0, 6.0, -6.0]), 0.0))
        elif kind == "accel":
            t0 = r.uniform(10, 60)
            moves = [(t0, t0 + 15, 0.0, r.choice([5.0, 10.0, -5.0]))]
        objs.append(S.Obj("o%d" % (j + 1), east=r.uniform(-40000, 40000), north=r.uniform(-40000, 40000),
                          speed=speed, heading=r.uniform(0, 360),
                          alt=r.choice([1000.0, 3000.0, 6000.0, 9000.0]), moves=moves))
    swap = [(duration * 0.4, "o1", "o2")]
    drop = [(duration * 0.6, "o3", 8.0)]
    sensors = [
        S.radar(time_state="coherent", swaps=swap, false_tracks=max(2, n_obj // 4)),
        S.beacon(time_state="coherent", drops=drop),
        S.beacon(source="beacon2", clock_offset_ms=200, time_state="coherent"),
        S.passive(time_state="drifting", clock_drift_ms_min=10.0, ce="understated", ce_factor=2.0),
    ]
    sc = S.Scenario("perf-" + size, "perf", "generated load", objs, sensors, duration_s=duration, seed=seed)
    vector, truth = sc.build()
    n_rep = sum(1 for s in vector["steps"] if "ingest" in s)
    desc = ("%d objects for %d s; sensors radar (4 s), beacon (1 s), beacon2 (1 s, clock +200 ms), "
            "passive (2 s, clock drift 10 ms/min); %d reports and %d ticks; seed %d"
            % (n_obj, duration, n_rep, len(vector["steps"]) - n_rep, seed))
    return vector["steps"], truth["labels"], desc


def steps_for(function, size="large", seed=SEED):
    """The steps file object (vector format, steps only) for one function."""
    steps, labels, desc = build(size, seed)
    out = []
    for st, lab in zip(steps, labels):
        if "ingest" in st:
            rep = dict(st["ingest"])
            if function == "fuse" and lab is not None:
                rep["fuse.group"] = "g-" + lab
            out.append({"ingest": rep})
        else:
            out.append({"tick": st["tick"]})
    return {"name": "perf-%s-%s" % (size, function), "description": desc, "steps": out}
