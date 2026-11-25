#!/usr/bin/env python3
"""Outside baseline: a Stone Soup tracker run on the benchmark's report stream.

Stone Soup is the open tracking framework of the UK Defence Science and
Technology Laboratory (https://github.com/dstl/Stone-Soup). This adapter
builds the textbook tracker from its components and writes one events file
per scenario, scored by the same scorer as every pack (tools/bench/README.md,
"Events file"):

| Part | Stone Soup component | Setting |
|---|---|---|
| motion | two `ConstantVelocity` models (east, north) | acceleration noise 50 m²/s³ (below) |
| measurement | `LinearGaussian`, position only | each report's own `ce` as its standard deviation (50 m when absent, as the packs' `default_ce_m`) |
| filter | `KalmanPredictor`, `KalmanUpdater` | |
| gate | `DistanceHypothesiser` with `Mahalanobis` | 99.9 % for two dimensions (distance 3.717) (below) |
| association | `GNNWith2DAssignment` | |
| new track | from an unassociated report | velocity from the report's course and speed (standard deviation 5 m/s), else 0 with 100 m/s |
| deletion | after 20 s without a report, as `correlate-assign-time` | |

It sees every report of every sensor as one detection, in arrival order (a
report older than the last one processed is processed at that time), so it
is a central measurement-level tracker: the classic alternative to
correlating the sensors' tracks. A sensor track is a member of the Stone Soup
track that absorbed its latest report; that grouping is what pairwise F1
scores. Where a pack has bias, clock-offset or two-model options, this
baseline has none; it is the reference a correlator must beat.

The acceleration noise and the gate were chosen as the packs' settings were:
on the public tuning set only. Of acceleration noise 1, 10, 50 and 200 m²/s³
and gates of 99 % and 99.9 %, on 60 random scenarios and every fourth
crossing, maneuver and formation scenario, 50 with 99.9 % gave the highest
pairwise F1 (0.793; 0.681 with 1 and 99 %).

    python3 tools/baselines/stonesoup_gnn.py --scenarios DIR --out DIR

Needs `pip install -r tools/baselines/requirements.txt` (Stone Soup pinned).
"""

import argparse
import datetime
import json
import math
import os
import sys

import numpy as np
from stonesoup.dataassociator.neighbour import GNNWith2DAssignment
from stonesoup.hypothesiser.distance import DistanceHypothesiser
from stonesoup.measures import Mahalanobis
from stonesoup.models.measurement.linear import LinearGaussian
from stonesoup.models.transition.linear import CombinedLinearGaussianTransitionModel, ConstantVelocity
from stonesoup.predictor.kalman import KalmanPredictor
from stonesoup.types.detection import Detection
from stonesoup.types.state import GaussianState
from stonesoup.types.track import Track
from stonesoup.updater.kalman import KalmanUpdater

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "bench"))
from scenarios import to_deg, to_plane  # noqa: E402

NAME = "stonesoup-gnn"
ACCEL_VAR = 50.0
DEFAULT_CE_M = 50.0
VEL_SIGMA_MS = 5.0
UNKNOWN_VEL_MS = 100.0
GATE = math.sqrt(13.82)       # chi-square, 2 degrees of freedom, 99.9 %
STALE_S = 20.0
EPOCH = datetime.datetime(2026, 1, 1)


def _time(ms):
    return EPOCH + datetime.timedelta(milliseconds=ms)


def run(vector):
    """Run the tracker over one scenario; return its events file object."""
    transition = CombinedLinearGaussianTransitionModel([ConstantVelocity(ACCEL_VAR), ConstantVelocity(ACCEL_VAR)])
    predictor = KalmanPredictor(transition)
    updater = KalmanUpdater(measurement_model=None)
    hypothesiser = DistanceHypothesiser(predictor, updater, measure=Mahalanobis(), missed_distance=GATE)
    associator = GNNWith2DAssignment(hypothesiser)

    tracks = set()
    last = {}          # track -> ms of its latest report
    label = {}         # track -> "T<n>" in creation order (Stone Soup's own ids are random)
    owner = {}          # sensor track key -> the Stone Soup track holding its latest report
    clock = None        # ms of the last report processed
    ticks = []
    for step in vector["steps"]:
        if "tick" in step:
            now = step["tick"]
            tracks = {tr for tr in tracks if now - last[tr] <= STALE_S * 1000.0}
            members = {}
            for key, tr in owner.items():
                if tr in tracks:
                    members.setdefault(label[tr], []).append(key)
            out = []
            for tr in sorted(tracks, key=lambda t: int(label[t][1:])):
                st = tr.state
                dt = (now - (st.timestamp - EPOCH).total_seconds() * 1000.0) / 1000.0
                east = float(st.state_vector[0]) + float(st.state_vector[1]) * dt
                north = float(st.state_vector[2]) + float(st.state_vector[3]) * dt
                lat, lon = to_deg(east, north)
                out.append({"system": label[tr], "members": sorted(members.get(label[tr], [])),
                            "lat": round(lat, 9), "lon": round(lon, 9)})
            ticks.append({"now_ms": now, "tracks": out})
            continue
        r = step["ingest"]
        key = "%s/%s" % (r["track.source_id"], r["uid"])
        clock = r["time_ms"] if clock is None else max(clock, r["time_ms"])
        t = _time(clock)
        east, north = to_plane(r["lat"], r["lon"])
        ce = r.get("ce") if isinstance(r.get("ce"), (int, float)) and r.get("ce") > 0 else DEFAULT_CE_M
        model = LinearGaussian(ndim_state=4, mapping=(0, 2), noise_covar=np.diag([ce * ce, ce * ce]))
        det = Detection(np.array([[east], [north]]), timestamp=t, measurement_model=model)
        hyps = associator.associate(tracks, {det}, t) if tracks else {}
        taken = None
        for tr, hyp in hyps.items():
            if hyp:                                   # a hypothesis with the detection
                tr.append(updater.update(hyp))
                taken = tr
        if taken is None:
            if isinstance(r.get("course"), (int, float)) and isinstance(r.get("speed_ms"), (int, float)):
                ve = r["speed_ms"] * math.sin(math.radians(r["course"]))
                vn = r["speed_ms"] * math.cos(math.radians(r["course"]))
                vs = VEL_SIGMA_MS
            else:
                ve = vn = 0.0
                vs = UNKNOWN_VEL_MS
            prior = GaussianState(np.array([[east], [ve], [north], [vn]]),
                                  np.diag([ce * ce, vs * vs, ce * ce, vs * vs]), timestamp=t)
            taken = Track([prior])
            label[taken] = "T%d" % (len(label) + 1)
            tracks.add(taken)
        owner[key] = taken
        last[taken] = clock
    return {"engine": NAME, "scenario": vector["name"], "ticks": ticks}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenarios", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    n = 0
    for f in sorted(os.listdir(a.scenarios)):
        if f.endswith(".json") and not f.endswith(".truth.json"):
            with open(os.path.join(a.scenarios, f), encoding="utf-8") as fh:
                vector = json.load(fh)
            with open(os.path.join(a.out, vector["name"] + ".events.json"), "w", encoding="utf-8") as fh:
                json.dump(run(vector), fh)
                fh.write("\n")
            n += 1
    print("wrote %d events files to %s" % (n, a.out))


if __name__ == "__main__":
    main()
