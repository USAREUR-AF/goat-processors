#!/usr/bin/env python3
"""Recorded ship trajectories from public AIS data, for the "recorded ships" family.

Source: NOAA Office for Coastal Management and BOEM, MarineCadastre.gov
"Vessel Traffic (AIS)", daily files (https://marinecadastre.gov/ais). U.S.
Government material, not subject to copyright protection within the United
States (17 U.S.C. 403 notice in NOTICE and docs/benchmark.md).

    python3 -I tools/bench/recorded.py convert AIS_2023_01_01.zip [--out tools/bench/data/recorded-ships.json]

What the conversion keeps and drops:

| Step | Rule |
|---|---|
| Area | only reports inside BOX: open water of the Gulf of Mexico, about 100 km or more offshore |
| Windows | the day is cut into WINDOW_S windows; the area into CELL_DEG cells. A window of a cell is kept when 3 to 15 vessels each have at least 6 reports in it and move (speed over ground above 1 kn) |
| Identity | MMSI, IMO, name, call sign and every other field but time and position are dropped; vessels are renamed v1, v2, ... in each window |
| Place | positions become east and north meters from the cell's center (equirectangular), rounded to 1 m; time becomes seconds from the window's start. The scenario places them at the benchmark's notional reference point, so no real location is published |
| Choice | windows ranked by vessel count, then by cell and time; the first WINDOWS_KEPT. Halves for the two sets alternate in that order |

The output records the input file's name and SHA-256, so the conversion can be
checked against the published daily file.
"""

import argparse
import csv
import hashlib
import io
import json
import math
import os
import zipfile
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "data", "recorded-ships.json")
BOX = (27.0, 28.5, -95.0, -92.0)        # lat min, lat max, lon min, lon max
CELL_DEG = 0.4
WINDOW_S = 1800
MIN_REPORTS = 6
MIN_VESSELS, MAX_VESSELS = 3, 15
WINDOWS_KEPT = 40
R = 6371008.8


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def rows(path):
    with zipfile.ZipFile(path) as z:
        name = [n for n in z.namelist() if n.endswith(".csv")][0]
        with z.open(name) as f:
            for row in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8", newline="")):
                yield row


def convert(path, out):
    la0, la1, lo0, lo1 = BOX
    pts = {}           # (cell, window) -> vessel -> [(t, lat, lon, sog)]
    day0 = None
    for row in rows(path):
        try:
            lat, lon = float(row["LAT"]), float(row["LON"])
        except (KeyError, ValueError):
            continue
        if not (la0 <= lat < la1 and lo0 <= lon < lo1):
            continue
        t = datetime.strptime(row["BaseDateTime"], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
        if day0 is None:
            day0 = t - t % 86400
        cell = (int((lat - la0) / CELL_DEG), int((lon - lo0) / CELL_DEG))
        win = int((t - day0) // WINDOW_S)
        sog = float(row.get("SOG") or 0.0)
        pts.setdefault((cell, win), {}).setdefault(row["MMSI"], []).append((t - day0 - win * WINDOW_S, lat, lon, sog))
    cands = []
    for (cell, win), vessels in pts.items():
        keep = {m: sorted(set(p)) for m, p in vessels.items()
                if len(set(p)) >= MIN_REPORTS and max(x[3] for x in p) > 1.0}
        if MIN_VESSELS <= len(keep) <= MAX_VESSELS:
            cands.append((-len(keep), cell, win, keep))
    cands.sort(key=lambda c: (c[0], c[1], c[2]))
    windows = []
    for k, (_, cell, win, keep) in enumerate(cands[:WINDOWS_KEPT]):
        clat = la0 + (cell[0] + 0.5) * CELL_DEG
        clon = lo0 + (cell[1] + 0.5) * CELL_DEG
        objs = []
        # Vessel order: by first report time, then by first position, so names carry nothing.
        for i, (m, p) in enumerate(sorted(keep.items(), key=lambda kv: (kv[1][0][0], kv[1][0][1], kv[1][0][2]))):
            samples = []
            last_t = None
            for (t, lat, lon, _) in p:
                if last_t is not None and t <= last_t:
                    continue
                e = R * math.radians(lon - clon) * math.cos(math.radians(clat))
                n = R * math.radians(lat - clat)
                samples.append([round(t, 1), round(e), round(n)])
                last_t = t
            objs.append({"oid": "v%d" % (i + 1), "samples": samples})
        windows.append({"window": k + 1, "objects": objs})
    doc = {"source": "NOAA Office for Coastal Management and BOEM, MarineCadastre.gov Vessel Traffic (AIS); "
                     "U.S. Government material, not subject to copyright protection within the United States",
           "input": os.path.basename(path), "input_sha256": sha256(path),
           "rules": {"box": BOX, "cell_deg": CELL_DEG, "window_s": WINDOW_S, "min_reports": MIN_REPORTS,
                     "vessels": [MIN_VESSELS, MAX_VESSELS], "windows_kept": WINDOWS_KEPT},
           "windows": windows}
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(doc, f, separators=(",", ":"))
        f.write("\n")
    print("wrote %d windows (%d vessels) to %s" % (len(windows), sum(len(w["objects"]) for w in windows), out))


def load(path=OUT):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("convert")
    c.add_argument("zip")
    c.add_argument("--out", default=OUT)
    a = ap.parse_args()
    convert(a.zip, a.out)


if __name__ == "__main__":
    main()
