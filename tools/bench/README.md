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
| `python3 -I tools/bench/bench.py generate [--set tuning\|evaluation] [--out DIR] [--only NAME ...]` | write the scenario files of a set (default the tuning set, `build/bench/scenarios/`); the evaluation set needs the private seeds |
| `python3 -I tools/bench/bench.py run [--scenarios DIR] [--out DIR]` | run every pack and write its events files (default `build/bench/events/<pack>/`) |
| `python3 -I tools/bench/bench.py score --events DIR [--scenarios DIR]` | score the events files of any engine; prints JSON |
| `python3 -I tools/bench/bench.py report [--jobs N] [--timeout S] [--no-eval]` | run every pack on the tuning set and, with the private seeds, the evaluation set, in parallel; write the results, this page's document and the charts |
| `python3 -I tools/bench/bench.py diff OLD.json NEW.json [--set tuning\|evaluation] [--group G]` | every pooled measure that changed beyond its 95 % interval between two results files |

| File | What |
|---|---|
| `scenarios.py` | the random number generator, truth motion (including formation members and recorded tracks), sensor models, the named scenarios and the random generator |
| `dataset.py` | the two sets and every family generator |
| `stats.py` | the bootstrap intervals and the comparison rule |
| `recorded.py`, `data/recorded-ships.json` | the AIS conversion and its output |
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
| clock offset, clock drift | the sensor's clock is wrong: a report made at true time `t` is stamped `time_ms = t + offset + drift * t / 60 s`. The position is measured at `t`, so truth stays exact. A report stamped before 0 is not sent |
| delivery spread | an extra delay after `latency`, a uniform integer in `[0, spread]` ms per report, so reports arrive out of order |
| time quality | on every report of a described sensor: `time_state` (`coherent`, `drifting`, `free-running`) and `time_error_ms`, the clock's error at that report rounded up, at least 1 ms, twice that when free-running (such a clock knows only a loose bound). Keys as in `spec/correlate.md`, "Time quality". A sensor that is not described sends neither key |

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

**Time family.** One object at 300 m/s, turning 90 degrees every 100 s
(3 deg/s for 30 s, from 40 s), seen by a radar and two beacons; the second
beacon (`beacon2`) carries the fault. The turns change the direction of the
along-track error, so a fixed position bias cannot stand in for a clock
error.

| Scenario | beacon2 | Length |
|---|---|---|
| `clock-offset-200ms` | clock 200 ms ahead | 120 s |
| `clock-drift-10ms-min` | clock drifts 10 ms per minute, 0 to 200 ms | 1200 s |
| `clock-free-running` | clock 1.5 s behind, drifting 30 ms per minute further | 300 s |
| `out-of-order` | delivery 0.3 to 2.8 s after the report's time, clock exact | 120 s |

In each `clock-` scenario every sensor reports its time quality (the
radar and the first beacon: `coherent`, 1 ms). Each has an `-undescribed`
twin with the same seed: the same reports without `time_state` and
`time_error_ms`. The time family is pooled as its own set, like the random
set; "named" in the pooled tables means the other named scenarios.

## The two sets

| Set | Content | Seeds | Use |
|---|---|---|---|
| tuning | the 21 named and 7 time scenarios; 500 random scenarios (the first 50 are the earlier random set); the tuning half of every family | `TUNING_ROOT` in `dataset.py`, public | developing and tuning packs; CI re-runs a subset (`QUICK` in `bench.py`) |
| evaluation | 500 random scenarios; the evaluation half of every family; names start `eval-` | `eval_root` in `~/re/bench-eval-seeds` (mode 600), held by the benchmark maintainer; published after each release, then replaced | every reported number; never used to tune |

A scenario's seed is drawn from its set's root, its family and its index, so a
family's two halves are the same generator on unrelated seeds. The evaluation
set's per-scenario results stay with the maintainer
(`~/re/bench-eval-results/`); the repository gets its pooled measures and
intervals only.

**Families.** Each is a generator in `dataset.py` with its truth stated by
construction; 20 scenarios per set (scale: 3).

| Family | What it generates |
|---|---|
| formation | 2 to 8 aircraft 200 to 1,000 m apart behind a leader that turns; each member holds its slot, splits away (3 to 8 km over 40 s) or joins from 4 to 9 km out (formation members fly at an offset in the leader's frame) |
| crossing | 2 to 4 objects whose paths meet at 3 to 25 degrees at one time and point; half then turn onto one heading and fly together (merging) |
| maneuver | level turns at 3 to 9 g; climbs and dives at 50 to 150 m/s with turns; or surface traffic that stops and starts |
| sensor problems | two or three of: a 10 to 30 s dropout, intermittent updates, 5 to 15 s latency, out-of-order delivery over 2 to 6 s, error stated 2 to 4 times too small or 2 to 4 times too large, biases on several sensors, clock drift |
| scale | 50, 200 and 1,000 objects (15 % surface) over a box that grows with the count, 3 to 8 sensors, 120 s (50) or 60 s |
| clutter | false tracks on the radar at 0, 5, 10, 20 and 40 per scenario, half as many on the passive sensor |
| mixed domains | surface vessels, a slow helicopter at 100 to 300 m near them, land vehicles (environment `G`) and an aircraft |
| track management | drops with and without track-number reuse (a dropped number given to the next new track), number swaps between objects, sensors joining late |
| recorded ships | 30-minute windows of real ship motion from public AIS (below), with simulated sensors on top |

**Recorded ships.** `recorded.py convert AIS_2023_01_01.zip` reads the daily
file of MarineCadastre.gov "Vessel Traffic (AIS)" (U.S. Government material,
not subject to copyright protection within the United States; 17 U.S.C. 403
notice in NOTICE). It keeps reports in open water of the Gulf of Mexico about
100 km or more offshore, cuts them into 30-minute windows of 0.4-degree cells
with 3 to 15 moving vessels, drops every identifier (vessels become v1, v2, ...),
and keeps time and position as meters from the cell's center; scenarios place
them at the notional reference point. Windows alternate between the tuning
and the evaluation set. The output records the input's SHA-256.

**Time limit.** `report` runs each pack on each scenario in a worker process
with a limit (`--timeout`, default 300 s). A run past it is reported as not
finished and left out of its group's pooled measures; the cell says how many.

## Detection-level family

`detections.py` generates synthetic moving-target radar dwells with ground
truth, for the `track` function (detections in, local tracks out) and then
track plus correlate end to end. It is not run by `report` until `track`
exists.

| Command | What it does |
|---|---|
| `python3 -I tools/bench/detections.py generate [--set tuning\|evaluation] [--out DIR]` | write the 20 detection-level scenarios of a set |
| `python3 -I tools/bench/detections.py score --scenarios DIR --tracks DIR` | score a track output per scenario |

| Part | Model |
|---|---|
| Truth | 4 to 30 ground movers (vehicles, environment G; some vessels, S) on straight legs with turns and stops, 0 to 30 m/s |
| Platform | an airborne radar on a racetrack 40 to 90 km from the area, 8 to 10 km high |
| Dwell | every 8 to 20 s a scan of a 15 to 25 km circle, stated with its coverage (WKT) and revisit |
| Detection | a mover in the circle is detected with probability Pd (0.7 to 0.95) when its radial speed is above the minimum detectable velocity (1 to 3 m/s) |
| Errors | range 10 to 30 m along the line of sight, cross-range = range times 1 to 3 mrad, radial velocity 0.3 to 1 m/s; each stated per detection |
| Clutter | false detections in the circle, Poisson with mean 0 to 8 per dwell |
| Order | the detections of a dwell are shuffled; `item_id` is their index |

A `dwell` step holds the dwell in the shared model's `detection` module keys:
`detection.dwell_id`, `detection.time_ms`, `detection.sensor_id`,
`detection.sensor_lat`, `detection.sensor_lon`, `detection.sensor_hae`,
`detection.revisit_ms`, `detection.coverage_wkt`, and `detection.items`, a
list of detections with `item_id`, `lat`, `lon`, `hae`, `range_error_m`,
`cross_range_error_m`, `radial_velocity_ms` (positive away from the sensor),
`radial_velocity_error_ms` and `snr_db`. The truth file gives, per dwell
step, the truth object of each detection (null for clutter).

**Scoring a track output.** One events file per scenario with `ticks` of
`{"now_ms", "tracks": [{"track", "lat", "lon"}]}`. Per tick: GOSPA (c = 500 m,
p = 2) between the tracks and the movers in the coverage; tracks matched to
movers by minimum total distance under 500 m. An identity swap is a mover
whose matched track changes while the old one still exists; a track break a
mover that loses its match and is matched again; false and missed track
ticks are unmatched tracks and movers. A perfect output scores 0 on all.

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
a group (a set's random scenarios, a family, the named set), TP, FP, FN, false merges, missed
merges, swaps, the episodes' times to associate, the squared errors and the
per-tick GOSPA values are summed over the runs, and the scores computed from
the sums: precision, recall and F1 are pooled over every pair-tick, RMS over
every object-tick, GOSPA is the mean over every tick.

A false track that no engine could tell from a real one still counts in X, so
a scenario with false tracks has a GOSPA floor shared by every engine.

**Intervals.** Each pooled measure has a 95 % bootstrap interval
(`stats.py`): draw as many scenarios as the group holds, with replacement,
sum their counts, compute the measure; repeat 1,000 times; take the 2.5th and
97.5th percentiles. The resampling uses the bench's splitmix64 with a fixed
seed, so the same results give the same intervals. A difference between two
packs, or two versions of one, is better or worse only when their intervals
do not overlap; otherwise no difference is shown.

## Adding an engine

| Engine | How |
|---|---|
| a pack of the Python engine | add its directory name to `PACKS` in `adapters.py`, run `report`. The charts have eight color slots; past eight packs, name one in `CHART_OMIT` in `report.py` with the reason (it stays in every table) |
| any other engine | run it on `build/bench/scenarios/*.json` (each `ingest` in order; at each `tick`, its picture), write `<scenario>.events.json` per scenario into one directory, run `score --events <dir>` |
