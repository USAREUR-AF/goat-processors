"""The volume test's input: N objects seen by two sources, seeded.

Built with the bench's scenario model (tools/bench/scenarios.py), as the
perf harness's large scenario is: a radar (a report every 4 s, false tracks)
and a beacon (every 1 s), each with noise, detection, latency and jitter.
The objects are spread so their density stays the same at every N (the area
grows with N). Deterministic: the same N, duration and seed give the same
bytes.

  python3 -I runner/volume/scenario.py N DURATION_S OUT.json
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools", "bench"))
import scenarios as S  # noqa: E402

SEED = 20261124


def build(n_obj, duration, seed=SEED):
    r = S.Rng(seed)
    half = 40000.0 * math.sqrt(n_obj / 12.0)
    objs = []
    for j in range(n_obj):
        kind = r.choice(["straight", "straight", "turn", "still"])
        speed = 0.0 if kind == "still" else r.uniform(80, 280)
        moves = []
        if kind == "turn":
            for t0 in range(int(r.uniform(10, 60)), max(11, duration - 40), 120):
                moves.append((t0, t0 + 30, r.choice([3.0, -3.0]), 0.0))
        objs.append(S.Obj("o%d" % (j + 1), east=r.uniform(-half, half), north=r.uniform(-half, half),
                          speed=speed, heading=r.uniform(0, 360),
                          alt=r.choice([1000.0, 3000.0, 6000.0, 9000.0]), moves=moves))
    sensors = [S.radar(time_state="coherent", false_tracks=max(2, n_obj // 10)), S.beacon(time_state="coherent")]
    sc = S.Scenario("volume-%d" % n_obj, "volume", "volume test load", objs, sensors, duration_s=duration, seed=seed)
    vector, _truth = sc.build()
    # The model's own ticks are kept: a vector file is replayed exactly, so
    # its ticks are the only ones the runner makes.
    steps = [{"ingest": s["ingest"]} if "ingest" in s else {"tick": s["tick"]} for s in vector["steps"]]
    return {"name": "volume-%d" % n_obj, "description": "%d objects for %d s, radar and beacon; seed %d" % (n_obj, duration, seed), "steps": steps}


if __name__ == "__main__":
    n, dur, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    v = build(n, dur)
    with open(out, "w") as f:
        json.dump(v, f, separators=(",", ":"))
    n_rep = sum(1 for s in v["steps"] if "ingest" in s)
    print("%s: %d reports, %d ticks" % (out, n_rep, len(v["steps"]) - n_rep))
