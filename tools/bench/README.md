# Correlation benchmark

Status: Built. Measures how well each correlate pack groups the tracks of
several sensors into objects, against scenarios whose truth is known. The
results are in [docs/benchmark.md](../../docs/benchmark.md), written by this
tool.

Standard library only. Run every command with `python3 -I`.

| Command | What it does |
|---|---|
| `python3 -I tools/bench/bench.py report` | generate every scenario, run every pack, score, write `docs/benchmark.md` and `docs/figures/bench/` |
| `python3 -I tools/bench/bench.py check` | re-run a short subset and confirm the committed results and documents are what the tool writes (CI) |
| `python3 -I tools/bench/bench.py generate [--out DIR] [--only NAME ...]` | write the scenario files (default `build/bench/scenarios/`) |
| `python3 -I tools/bench/bench.py run [--scenarios DIR] [--out DIR]` | run every pack and write its events files (default `build/bench/events/<pack>/`) |
| `python3 -I tools/bench/bench.py score --events DIR [--scenarios DIR]` | score the events files of any engine; prints JSON |

| File | What |
|---|---|
| `scenarios.py` | the random number generator, truth motion, sensor models, the named scenarios and the random set |
| `adapters.py` | the in-process adapter for the Python engine (`PACKS` lists the packs scored) and the events file reader |
| `score.py` | every score below |
| `report.py` | `docs/benchmark.md` and the SVG charts |

## Scenarios

**Truth.** Each object starts at a position with a speed and heading and
follows a list of maneuvers: between two times, turn at a stated rate
(degrees per second) and change speed at a stated rate (m/s²). Motion is
integrated every 0.1 s with the midpoint heading and speed. A split is an
object that appears at its parent's position and velocity at a stated time
and then maneuvers on its own. Positions are in a local plane around
50 N 10 E and converted to degrees with the equirectangular formulas of
`spec/correlate.md` ("Frame").

**Sensors.** Each sensor reports every object it sees:

| Property | Effect |
|---|---|
| period, jitter | report times `phase + k * period`, each moved by a uniform integer in `[-jitter, +jitter]` ms; the phase is uniform in `[0, period)` |
| position noise `sigma` | each axis gets independent noise of standard deviation `sigma` |
| reported error | `honest`: `ce = sigma`; `understated`: `ce = sigma / factor`; `absent`: no `ce` key |
| detection probability `Pd` | each report is made with probability `Pd` |
| latency | the report arrives `latency` ms after its `time_ms` |
| bias | a fixed east and north offset added to every position |
| velocity noise | `course` and `speed_ms` from the true velocity plus noise per axis; some sensors report none |
| height noise | `hae` for air objects, true height plus noise |
| number swap | from a stated time, the sensor's track numbers of two objects trade places |
| drop | from a stated time, the sensor stops reporting an object; after a gap it starts a new track number |
| false tracks | tracks of no object: each lives 20 to 60 s on a straight line within 3 km of an object |

Every report carries `type` `a-u-A` (air) or `a-u-S` (surface).

**Random numbers.** `Rng` is splitmix64, written in `scenarios.py`. A normal
deviate is the sum of 12 uniforms minus 6, which needs only arithmetic. Each
sensor and each part of a scenario draws from its own stream (`Rng.fork`),
so adding a sensor does not change the others' reports.

**Files.** `generate` writes, per scenario:

| File | Content |
|---|---|
| `<name>.json` | the vector format of `spec/vector-format.md` with `steps` only (no `expect`, `trace` or `snapshot`) and `pack` null. Steps are in arrival order; one `tick` every 1000 ms of input time, after every report that arrived at or before it; reports arriving at the same time in source, then track number, order |
| `<name>.truth.json` | `labels`: for each step, the truth object the report describes (`null` for a false track or a tick); `ticks`: the tick times; `objects`: per object, its position `[lat, lon]` at each tick (`null` before it exists); `live_ms`; the scenario's family, purpose and sensor list |

The named scenarios each test one thing; the random set of 50 (seed
20261119) mixes 2 to 4 objects with 2 or 3 sensors and random errors, for
averages. The full list is in [docs/benchmark.md](../../docs/benchmark.md).

## Events file

Every engine is scored from one file per scenario, `<scenario>.events.json`.
The in-process adapter writes it for the Python engine; any other engine is
scored by writing the same file.

```
{"engine": "<name>", "scenario": "<scenario name>",
 "ticks": [ {"now_ms": <int>, "tracks": [ <output track>, ... ]}, ... ]}
```

| Field | Meaning |
|---|---|
| `ticks` | one entry per `tick` step, with its `now_ms`; a tick with no entry is an empty picture |
| output track | `{"system": <label>, "members": ["<source>/<uid>", ...], "lat": <deg>, "lon": <deg>}`; `group` is read when `system` is absent; other keys are ignored |
| `tracks` | the engine's whole picture at `now_ms`, including tracks with one member |
| label | the same output track keeps the same label from tick to tick |
| position | the engine's estimate at `now_ms`; a track without a finite `lat` and `lon` has no position |

A reported track that is in no output track counts as alone, with no position.

The Python adapter maps the engine's events this way:

| Method | Output tracks at a tick |
|---|---|
| `assign` | each `system` event |
| `confirm` | each `fused` event, labeled by its group, plus one track per ungrouped entity, labeled by its entity key, at its filter's position predicted to `now_ms` (`p + v * dt` per axis) |

## Scores

Definitions used by every score, at each tick `t`:

| Term | Definition |
|---|---|
| reported track | `<track.source_id>/<uid>` of the reports ingested before the tick |
| live | a reported track whose last ingested `time_ms >= t - live_ms`, with `live_ms = max over sensors of (2 * period + jitter + latency)` |
| truth of a track | the object of its last ingested report (`null` for a false track) |
| output group of a track | the label of the first output track listing it, else "alone" (a group of its own) |
| truth-same pair | two live tracks whose truth is the same object (never a false track) |
| output-same pair | two live tracks with the same output group |

| Score | Formula |
|---|---|
| TP, FP, FN | over every tick and every unordered pair of live tracks: TP when truth-same and output-same; FP when output-same only; FN when truth-same only |
| precision | `TP / (TP + FP)` |
| recall | `TP / (TP + FN)` |
| F1 | `2 * precision * recall / (precision + recall)`; 0 when TP is 0 and FP + FN is not |
| false merges | the number of times a pair becomes FP: FP at tick `t` and not FP at the tick before |
| episode | a maximal run of consecutive ticks over which a pair is truth-same |
| missed merges | episodes of at least 10 s in which the pair is never output-same |
| time to associate | over episodes in which the pair becomes output-same: the mean of (first output-same tick minus the episode's first tick), s |
| object's output track | the output group holding the most of the object's live tracks; on a tie, the one of the tick before if it is among the tied, else the least label |
| identity swaps | the number of times an object's output track changes from A to B while A is still in the picture (an output track's label, or a live track's "alone" group); a track that joins a group, or a group that dissolves, is not a swap |
| position error RMS | `sqrt(mean of d²)` over every tick and object whose output track has a position, `d` the distance from that position to the object's true position at `t`, in meters. The mean of squares weighs the largest errors most |
| GOSPA | per tick, between X, the positions of the output tracks with a live member, and Y, the true positions of the objects with a live track: `(min over assignments of (sum over assigned pairs of min(d, c)^p + (c^p / 2) * (unassigned in X + unassigned in Y)))^(1/p)`, with `c = 500` m, `p = 2`, `alpha = 2`. Reported as the mean over ticks. The assignment is exact (Hungarian method) |
| GOSPA localisation | the same sum over assigned pairs closer than `c` only, to the power `1/p`, mean over ticks |
| missed, false per tick | per tick, the objects of Y and the tracks of X left unassigned (or assigned at `c` or more), mean over ticks |

**Aggregation.** For one scenario the scores come from that run's counts. For
a set (the named set, the random set), TP, FP, FN, false merges, missed
merges, swaps, the episodes' times to associate, the squared errors and the
per-tick GOSPA values are summed over the runs, and the scores computed from
the sums: precision, recall and F1 are pooled over every pair-tick, RMS over
every object-tick, GOSPA is the mean over every tick.

A false track that no engine could tell from a real one still counts in X, so
a scenario with false tracks has a GOSPA floor shared by every engine.

## Adding an engine

| Engine | How |
|---|---|
| a pack of the Python engine | add its directory name to `PACKS` in `adapters.py`, run `report` |
| any other engine | run it on `build/bench/scenarios/*.json` (each `ingest` in order; at each `tick`, its picture), write `<scenario>.events.json` per scenario into one directory, run `score --events <dir>` |
