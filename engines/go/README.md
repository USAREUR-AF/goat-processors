# goat-correlator: Go engine

An implementation of `spec/correlate.md` (version 0.8, method `confirm`, with
the optional two-model filter, filter restart and time quality) and
`spec/correlate-assign.md` (version 0.6, method `assign`, with the multi-frame
window, its margin, sensor bias and the clock offset) in Go, standard library
only.
The pack's `method` line selects which runs. The `fuse` package
(`engines/go/fuse/`) implements `spec/fuse.md` (version 0.2).

The package `filter/` implements `spec/filter.md` (version 0.1), the keep/drop
filter. It reads reports with the correlate engine's own reader
(`reports.go`, spec/correlate.md Reports), which `spec/filter.md` cites.

It was written from the specification and the vectors alone, without
reference to any other engine.

| File | Contents |
|---|---|
| `pack.go` | `LoadPack(dir)` / `ParsePack(text)`: the `pack.def` reader (spec: Pack) |
| `engine.go` | `New(pack)`, `Ingest(report)`, `Tick(now_ms)`, `Snapshot()`: frame, Kalman axis steps, tests, association, events and trace |
| `imm.go` | the per-entity filter: one model (Track estimate) or two (Two-model filter: switching, mixing, likelihood, mode probabilities, combination, prediction), and the restart test (Restart) |
| `bias.go` | method `assign`, Sensor bias: per-pair offset state, moving B into A's frame for tests and costs (after B's timing variance), the per-tick update and its `bias` trace, the clock offset fit of Time offset, the snapshot's `bias` |
| `time.go` | Time quality (`correlate.md` Reports, Track estimate "Measurement variance", Pack `time_default`): reading `time_error_ms` and `time_state`, the per-source defaults, the per-axis measurement and timing variance, the `time` trace record |
| `assign.go` | method `assign`: memberships and histories (Memberships), columns and entries of one source, ranked assignments by enumeration in choice-vector order (Ranking), the per-tick steps 1 to 6 (Window, with restart leaves and `margin`), fused estimate, snapshot |
| `assign_test.go` | checks the ranked assignments follow the Ranking order on random tables |
| `DISAGREEMENTS.md` | vectors that contradict the specification (none), and the points it leaves open |
| `vectors_test.go` | runs every `packs/correlate-*` scenario vector and every `spec/correlate-load-vectors` vector with the structural comparison of `spec/vector-format.md` |
| `reports.go` | `ReadReport`, `ToFloat`, `ToInt`, `IsInt`: the Reports rules of `spec/correlate.md`, exported for `filter/` |
| `filter/pack.go` | filter `LoadPack` / `ParsePack` (spec/filter.md: Pack) |
| `filter/geometry.go` | haversine distance, polygon test, reference prediction (spec/filter.md: Geometry) |
| `filter/conditions.go` | every condition, its `value`, `limit` and true/false/unknown result (spec/filter.md: Conditions) |
| `filter/engine.go` | `New`, `Ingest`, `Tick`, `Snapshot`: rules, decision, events, state, forgetting (spec/filter.md: Rules, Tick, Events, Trace, Snapshot) |
| `filter/vectors_test.go` | runs every `packs/filter-*` vector and every `spec/filter-load-vectors` vector |
| `shared.go` | the exported Frame, Track estimate filter and report checks the `fuse` package reuses (spec/fuse.md: Shared with correlate.md) |
| `fuse/pack.go` | fuse `LoadPack(dir)` / `ParsePack(text)` (spec/fuse.md: Pack) |
| `fuse/engine.go` | fuse `New`, `Ingest`, `Tick`, `Snapshot`: Reports, Groups, On each tick, Fused event, Height, Snapshot |
| `fuse/kinematics.go` | the five kinematics methods, the covariance-intersection weight and fold, and the kinematics and intersect trace (spec/fuse.md: Kinematics) |
| `fuse/attributes.go` | candidates, the five attribute rules, majority equality and the attribute trace (spec/fuse.md: Attributes) |
| `fuse/vectors_test.go` | runs every `packs/fuse-*` scenario vector and every `spec/fuse-load-vectors` load vector |
| `export.go` | the frame, filter and report checks exported for the quality module |
| `quality/` | package `quality`: `spec/quality.md` (version 0.2), see below |

Ranked assignments are found by brute force: every assignment of a source's
tracks is enumerated, which is exact and fine at vector sizes but grows
factorially with the number of tracks one source reports at once.

## Quality

`quality/` implements `spec/quality.md` 0.2, standard library only, reusing this
engine's frame (`ToPlane`), filter (`Axis.Predict`, `UpdatePos`, `UpdateVel`),
report type checks, and time quality reading (`ValidTimeError`,
`ValidTimeState`, `ParseTimeDefault` with quality's number grammar) where the
specification cites `correlate.md` 0.8.

| File | Spec sections |
|---|---|
| `quality/pack.go` | Pack (`LoadPack`, `ParsePack`) |
| `quality/engine.go` | Reports, Order, Frame and filter, Samples, Ingest, Forwarding |
| `quality/time.go` | Reports "Time quality" (the three steps, state codes), Input clock, source latest, lateness |
| `quality/measures.go` | Window, Entity measures, Source measures |
| `quality/tick.go` | Tick, Rules (evaluation, forgetting), rule trace |
| `quality/snapshot.go` | Snapshot |
| `quality/vectors_test.go` | runs every `packs/quality-*/vectors/*.json` and `spec/quality-load-vectors/*.json` |

## Build

Requires Go 1.26.

```
cd engines/go
go build ./...
```

## Floats

The spec forbids fused multiply-add and extended precision. Go's compiler may
fuse `x*y + z` on some targets (arm64, ppc64le, s390x, riscv64, and amd64 with
`GOAMD64=v3` or above); on amd64 with the default `GOAMD64=v1` it does not, and
SSE2 arithmetic has no extended precision. Build and test on amd64 with
`GOAMD64=v1` (the default) or `v2`.

## Run the vectors

```
cd engines/go
go test -count=1 -v ./...
```

`TestScenarioVectors` loads each `packs/correlate-*/vectors/*.json` (in `filter/`,
each `packs/filter-*/vectors/*.json`; in `quality/`, each `packs/quality-*/vectors/*.json`), runs its steps
on one engine, compares each step's events and trace, then compares the final
snapshot. `TestLoadVectors` parses each `spec/correlate-load-vectors/*.json` (in `filter/`,
`spec/filter-load-vectors/*.json`; in `quality/`, `spec/quality-load-vectors/*.json`) and checks
that it fails or succeeds as `expect_error` says. A failure prints the path of
the first mismatch, for example `steps[2].trace[0].value: got ..., want ...`.

`TestFuseScenarioVectors` and `TestFuseLoadVectors` (package `fuse`) do the same
for `packs/fuse-*/vectors/*.json` and `spec/fuse-load-vectors/*.json`.
