#!/usr/bin/env python3
"""How far do two correlators agree on a real recording, where no truth exists?

    python3 -I tools/feeds/agree.py RECORD [RECORD ...] --with A --with B [--with C ...] [--json]

Each A, B, ... is a correlate pack (`correlate-gnn`), run here in the Python
engine, or an events file another tracker wrote for the same recording
(format: tools/bench/README.md, "Events file"; one tick entry per tick of the
recording). For every pair of outputs, at every tick and for every pair of
live reported tracks: are the two tracks together in both outputs, in one only,
or in neither? Agreement is the pairwise F1 of one output against the other,
which is the same either way round: 1 when they group every pair alike.

Agreement is not accuracy: two outputs can agree and both be wrong. A pair the
outputs disagree on is where to look, and `--worst N` lists the N ticks with
the most disagreement, by tick time relative to the start and the source of
each track, so they can be found in the recording. The output holds no
position and no track identifier.
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools", "bench"))
sys.path.insert(0, HERE)

import adapters  # noqa: E402
import feedcheck  # noqa: E402

LIVE_MS = feedcheck.LIVE_MS


def as_vector(reports, ticks):
    good = [r for r in reports if feedcheck.required(r)]
    if not ticks:
        ticks = list(range(good[0]["time_ms"] // 1000 * 1000 + 1000, good[-1]["time_ms"] + 1001, 1000))
    steps, i = [], 0
    for t in ticks:
        while i < len(good) and good[i]["time_ms"] <= t:
            steps.append({"ingest": good[i]})
            i += 1
        steps.append({"tick": t})
    return {"name": "recording", "pack": None, "steps": steps}


def output(spec, vector):
    """{tick: {track: group}} for a pack name or an events file."""
    if os.path.isfile(spec):
        _, ticks = adapters.read_events(spec)
    elif spec.startswith("correlate-") and os.path.isdir(os.path.join(ROOT, "packs", spec)):
        doc = adapters.run_pack(spec, vector)
        ticks = {t["now_ms"]: t["tracks"] for t in doc["ticks"]}
    else:
        raise SystemExit("%s: neither a correlate pack nor an events file" % spec)
    out = {}
    for t, tracks in ticks.items():
        g = {}
        for tr in tracks:
            for m in tr["members"]:
                g.setdefault(m, tr["system"])
        out[t] = g
    return out


def agreement(vector, a, b, worst=0):
    last, t0 = {}, None
    both = only_a = only_b = 0
    per_tick = []
    for st in vector["steps"]:
        if "ingest" in st:
            r = st["ingest"]
            last[r["track.source_id"] + "/" + r["uid"]] = r["time_ms"]
            continue
        t = st["tick"]
        t0 = t if t0 is None else t0
        live = sorted(k for k, v in last.items() if t - v <= LIVE_MS)
        ga, gb = a.get(t, {}), b.get(t, {})
        dis = []
        for i, x in enumerate(live):
            for y in live[i + 1:]:
                ina = x in ga and ga.get(x) == ga.get(y)
                inb = x in gb and gb.get(x) == gb.get(y)
                if ina and inb:
                    both += 1
                elif ina or inb:
                    only_a += ina
                    only_b += inb
                    dis.append((x.split("/")[0], y.split("/")[0], "A" if ina else "B"))
        if dis:
            per_tick.append(((t - t0) // 1000, dis))
    f1 = 2 * both / (2 * both + only_a + only_b) if both + only_a + only_b else None
    res = {"agreement_f1": f1, "together_in_both": both, "together_in_a_only": only_a, "together_in_b_only": only_b}
    if worst:
        res["worst_ticks"] = [{"second": s, "pairs": [{"sources": [p[0], p[1]], "together_in": p[2]} for p in d]}
                              for s, d in sorted(per_tick, key=lambda x: -len(x[1]))[:worst]]
    return res


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("records", nargs="+")
    ap.add_argument("--with", dest="outputs", action="append", required=True)
    ap.add_argument("--worst", type=int, default=0)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    if len(a.outputs) < 2:
        ap.error("give at least two --with")
    vector = as_vector(*feedcheck.read(a.records))
    outs = {s: output(s, vector) for s in a.outputs}
    res = {}
    for i, x in enumerate(a.outputs):
        for y in a.outputs[i + 1:]:
            res["%s | %s" % (os.path.basename(x), os.path.basename(y))] = agreement(vector, outs[x], outs[y], a.worst)
    if a.json:
        print(json.dumps(res, indent=1))
    else:
        for k, v in res.items():
            f = v["agreement_f1"]
            print("%s: agreement %s; pairs together in both %d, in the first only %d, in the second only %d"
                  % (k, "–" if f is None else "%.3f" % f, v["together_in_both"], v["together_in_a_only"],
                     v["together_in_b_only"]))
            for w in v.get("worst_ticks", []):
                print("  second %d: %d pairs differ" % (w["second"], len(w["pairs"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
