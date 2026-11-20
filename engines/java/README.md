# goat-processors: java engine

Java 17, standard library only. Implements

- correlate: `spec/correlate.md` (0.8) and `spec/correlate-assign.md` (0.6);
- filter: `spec/filter.md` (0.1);
- fuse: `spec/fuse.md` (0.2);
- quality: `spec/quality.md` (0.2).

All were written from the specifications and the vectors, without reading any other engine.

## Layout

One package per module, the same modules as every engine: `src/goat/<module>/`.

| Module | Holds |
|---|---|
| `model` | what every function shares about a report and a track: the report rules, the frame, the constant-velocity filter, the two-model filter, the inverse-variance estimate, key order |
| `filter` | the filter function (filter.md) |
| `correlate` | the correlate function (correlate.md): the shared report path, the tests, the method table, and method `confirm` |
| `assign` | correlate method `assign` (correlate-assign.md) |
| `fuse` | the fuse function (fuse.md) |
| `quality` | the quality function (quality.md) |
| `trace` | the result of a call (events, then trace) and the record builders |
| `snapshot` | the pieces every snapshot shares |
| `io` | the JSON reader and writer, pack files, the entry-point shape (`Processor`), the function table (`Functions`), the runner and the vector runner |

"Filter" names two things in the specifications: the filter *function* (filter.md) is the module
`filter`; the track *filter* (correlate.md, Track estimate) is part of `model`.

**Entry point.** Every function has the one shape of `goat.io.Processor`: `load_pack` makes a
processor (`Functions.load(function, dir)`, or `Correlator.load`, `FilterProcessor.load`,
`Fuse.load`, `Quality.load`), then `ingest(report)` and `tick(now_ms)` each return a `Result`
(its `events`, then its `trace` records), and `snapshot()` gives the state. The runner and the
vector runner call nothing else.

The four classes `correlator.VectorTest`, `filter.VectorTest`, `fuse.FuseVectorTest` and
`quality.VectorTest` only call `goat.io.Vectors`: they keep the names the perf harness runs.

## Where each spec section lives

### correlate.md

| Section | File |
|---|---|
| What the correlator does | `correlate/Correlator.java` |
| Reports | `model/Report.java` |
| Reports, Time quality | `model/Report.java` |
| Frame | `model/Frame.java` |
| Track estimate | `model/TrackEstimate.java` (one axis: `model/Axis.java`; measurement variance: `correlate/Correlator.java`) |
| Two-model filter | `model/TrackEstimate.java` |
| Restart | `correlate/Correlator.java` |
| Tests | `correlate/Tests.java` |
| Association | `correlate/Confirm.java` |
| Events | `correlate/Confirm.java` |
| Trace | `correlate/Tests.java` |
| Snapshot | `correlate/Confirm.java` |
| Pack | `correlate/CorrelatePack.java` |
| Floats | `model/Axis.java` |

### correlate-assign.md

| Section | File |
|---|---|
| What this method does | `assign/Assign.java` |
| Shared with `correlate.md` | `correlate/Correlator.java` |
| Memberships | `assign/Membership.java` |
| Assignment of one source | `assign/Assign.java` |
| Sensor bias | `assign/Bias.java` |
| Ranking | `assign/Assign.java` |
| Window | `assign/History.java` (records: `assign/Record.java`; the tick: `assign/Assign.java`) |
| Events | `assign/Membership.java` |
| Trace | `assign/Assign.java` |
| Snapshot | `assign/Assign.java` |
| Pack | `correlate/CorrelatePack.java` |

### filter.md

| Section | File |
|---|---|
| What the filter does | `filter/FilterProcessor.java` |
| Reports | `model/Report.java` |
| Geometry | `filter/Geometry.java` |
| Conditions | `filter/Condition.java` (evaluation: `filter/FilterProcessor.java`) |
| Rules | `filter/FilterProcessor.java` |
| Tick | `filter/FilterProcessor.java` |
| Events | `filter/FilterProcessor.java` |
| Trace | `filter/FilterProcessor.java` |
| Snapshot | `filter/FilterProcessor.java` |
| Pack | `filter/FilterPack.java` |

### fuse.md

| Section | File |
|---|---|
| What fuse does | `fuse/Fuse.java` |
| Shared with `correlate.md` | `model/` |
| Reports | `fuse/Fuse.java` |
| Groups | `fuse/Fuse.java` |
| On each tick, Fused event | `fuse/Fuse.java` |
| Kinematics | `fuse/Fuse.java` |
| Attributes | `fuse/Fuse.java` |
| Events, Trace, Snapshot | `fuse/Fuse.java` |
| Pack | `fuse/FusePack.java` |

### quality.md

| Section | File |
|---|---|
| What quality does | `quality/Quality.java` |
| Reports, Time quality | `model/Report.java` |
| Order, Frame and filter, Input clock, Samples, Ingest, Forwarding | `quality/Quality.java` |
| Window, Entity measures, Source measures, Rules, Tick | `quality/Quality.java` |
| Events, Trace, Snapshot | `quality/Quality.java` |
| Pack | `quality/QualityPack.java` |

### vector-format.md

| Section | File |
|---|---|
| Scenario vectors, What the engine checks, Load vectors | `io/Vectors.java` |

## Open points

No vector contradicts any specification, so there is no `DISAGREEMENTS.md`. On the open points:
a report integer outside the signed 64-bit range is read as a binary64 (so it is not an
integer); integers above 2^53 compare as their nearest binary64, except that fuse compares two
integer attribute values exactly; near a pole the filter's reference prediction divides by
`cos(rad(lat))` as written.

Floats: Java evaluates every `double` operation as one correctly rounded binary64 operation
(strict semantics since Java 17) and never contracts into a fused multiply-add; the code calls no
`Math.fma`.

## Build, test, run

```
engines/java/build.sh          # compile, then every conformance vector
engines/java/runner/build      # the perf runner (tools/perf/README.md, Runner contract)
engines/java/runner/run --function correlate --pack packs/correlate-gnn --steps <file> [--events <file>] [--trace]
```
