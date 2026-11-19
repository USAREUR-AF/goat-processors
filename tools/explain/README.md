# explain: replay a vector and see every decision

Status: Built. `explain.py` reads a vector file, or a bench run in vector-format
input, and writes one HTML page. The page makes no network request, so it opens
from disk and can be sent as a single file.

```sh
python3 -I tools/explain/explain.py packs/correlate-gnn/vectors/06-third-source-joins.json
# writes 06-third-source-joins.html in the current directory

python3 -I tools/explain/explain.py --all /tmp/vectors
# one page per vector under packs/, and /tmp/vectors/index.html listing them
```

## What the page shows

| Part | Shows |
|---|---|
| Plan view | every report as a dot with its trail; every entity's filter estimate as a cross with its one-sigma ellipse and velocity direction; each group or system track as an arc or band joining its members; each fused output as a diamond. Drag to pan, scroll to zoom, "Fit this step" to zoom on the selected step |
| Step slider and strip | one cell per step, with a dot per event (colored by kind), a bar whose height is the number of trace records, and a red mark on a step whose replay differs from the vector |
| Input | the report or tick of the selected step, and the report's position in the plan |
| Events | the events the step returned |
| Trace | every trace record of the step in engine order, one column per key the records carry (for correlate: stage, `a`, `b`, test, value, limit, result). Clicking a row marks its entity, pair or group on the plan |
| Snapshot | the engine's whole state after the step, as an expandable tree |
| Rules | the pack's `pack.def` |

The plan is in meters east and north of the first accepted report, the plane
`spec/correlate.md` defines. A filter estimate is drawn at the time of its
entity's last report.

## How it gets the state after each step

When `engines/python` has an engine for the vector's function (the `ENGINES`
table in `explain.py`: correlate, filter, fuse, quality), the tool replays the steps through it and takes
`snapshot()` after every step. It then compares each step with the vector
under the rules of `spec/vector-format.md`:

| Outcome | Page | Exit code |
|---|---|---|
| every step and the final snapshot match | green badges | 0 |
| a step differs | a red mark on the step, the first differing path and the vector's records | 1 |
| no engine for the function | the file's own events and trace; the final snapshot on the last step | 0 |

## Options

| Option | Use |
|---|---|
| `-o FILE` | output path |
| `--all DIR` | a page for every vector under `packs/` and an index page; exit 1 if any replay differs |
| `--truth FILE` | draw ground truth as dashed lines. Accepted shapes: `{"objects": {id: [{time_ms, lat, lon}, ...]}}`, `{"objects": [{"id", "states": [...]}]}`, or a list of `{id, time_ms, lat, lon}` |
| `--events FILE` | show events from another engine instead of the replay: a list with one entry per step, each a list of events or `{"events": [...]}` |

## Tests

```sh
python3 -I tools/explain/test_explain.py
```

Every vector in `packs/*/vectors/` replays with no difference; the page holds
no external reference; a changed vector is marked at the changed step; input
without expectations is replayed; a function with no engine shows the file.
