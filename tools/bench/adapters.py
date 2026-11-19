"""Engine adapters: run an engine on a scenario and write its events file.

Every engine is scored from an events file (format in README.md, "Events
file"). The in-process adapter below runs the Python correlate engine with
one pack and writes that file; any other engine is scored by writing the same
file and passing it to `bench.py score`.
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "engines", "python", "src"))
from goat_correlator import load_pack, make_engine  # noqa: E402

# The packs the benchmark scores, in report order. A pack added to packs/
# is scored once it is named here.
PACKS = ["correlate-gnn", "correlate-window", "correlate-distance", "correlate-assign",
         "correlate-gnn-imm", "correlate-assign-imm", "correlate-assign-window",
         "correlate-assign-bias", "correlate-assign-full", "correlate-gnn-restart",
         "correlate-assign-time", "correlate-gnn-time"]


def run_pack(pack_name, vector):
    """Run the Python engine with one pack over a scenario; return the events file object."""
    pack = load_pack(os.path.join(ROOT, "packs", pack_name))
    eng = make_engine(pack)
    method = getattr(pack, "method", "confirm")
    ticks = []
    for step in vector["steps"]:
        if "ingest" in step:
            eng.ingest(step["ingest"])
            continue
        now = step["tick"]
        events, _ = eng.tick(now)
        if method == "assign":
            tracks = [_track(ev["system"], ev) for ev in events if ev.get("ev") == "system"]
        else:
            tracks = [_track(ev["group"], ev) for ev in events if ev.get("ev") == "fused"]
            tracks.extend(_ungrouped(eng, now))
        ticks.append({"now_ms": now, "tracks": tracks})
    return {"engine": "python/" + pack_name, "scenario": vector["name"], "ticks": ticks}


def _track(label, ev):
    return {"system": label, "members": list(ev["members"]),
            "lat": round(ev["lat"], 9), "lon": round(ev["lon"], 9)}


def _ungrouped(eng, now):
    """Method confirm outputs only groups; an ungrouped track is its own output,
    its filter predicted to `now` (spec/correlate.md, Track estimate)."""
    out = []
    for key in sorted(eng.entities):
        ent = eng.entities[key]
        if ent.group is not None:
            continue
        dt = (now - ent.last_time_ms) / 1000.0
        east = ent.east[0] + ent.east[1] * dt
        north = ent.north[0] + ent.north[1] * dt
        lat, lon = eng._to_deg(east, north)
        out.append({"system": key, "members": [key], "lat": round(lat, 9), "lon": round(lon, 9)})
    return out


def read_events(path):
    """The generic adapter: an events file written by any engine."""
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    ticks = {}
    for t in doc.get("ticks", []):
        tracks = []
        for tr in t.get("tracks", []):
            label = tr.get("system", tr.get("group"))
            lat, lon = tr.get("lat"), tr.get("lon")
            ok = isinstance(lat, (int, float)) and isinstance(lon, (int, float)) \
                and math.isfinite(lat) and math.isfinite(lon)
            tracks.append({"system": str(label), "members": list(tr.get("members", [])),
                           "lat": lat if ok else None, "lon": lon if ok else None})
        ticks[int(t["now_ms"])] = tracks
    return doc.get("engine", os.path.basename(path)), ticks


def write_json(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=indent, sort_keys=False)
        f.write("\n")
