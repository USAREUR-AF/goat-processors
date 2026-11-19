# goat-correlator: Go engine

An implementation of `spec/correlate.md` (version 0.4, method `confirm`) and
`spec/correlate-assign.md` (version 0.2, method `assign`) in Go, standard library only.
The pack's `method` line selects which runs. The `fuse` package
(`engines/go/fuse/`) implements `spec/fuse.md` (version 0.1).
It was written from the specification and the vectors alone, without
reference to any other engine.

| File | Contents |
|---|---|
| `pack.go` | `LoadPack(dir)` / `ParsePack(text)`: the `pack.def` reader (spec: Pack) |
| `engine.go` | `New(pack)`, `Ingest(report)`, `Tick(now_ms)`, `Snapshot()`: frame, filter, tests, association, events and trace |
| `assign.go` | method `assign`: system tracks, per-source exact least-cost assignment (shortest augmenting paths with potentials), inverse-variance fused estimate, its events, trace and snapshot |
| `assign_test.go` | checks the assignment solver against brute force |
| `DISAGREEMENTS.md` | vectors that contradict the specification (none), and the points it leaves open |
| `shared.go` | the exported Frame, Track estimate filter and report checks the `fuse` package reuses (spec/fuse.md: Shared with correlate.md) |
| `fuse/pack.go` | fuse `LoadPack(dir)` / `ParsePack(text)` (spec/fuse.md: Pack) |
| `fuse/engine.go` | fuse `New`, `Ingest`, `Tick`, `Snapshot`: Reports, Groups, On each tick, Fused event, Height, Snapshot |
| `fuse/kinematics.go` | the five kinematics methods, the covariance-intersection weight and fold, and the kinematics and intersect trace (spec/fuse.md: Kinematics) |
| `fuse/attributes.go` | candidates, the five attribute rules, majority equality and the attribute trace (spec/fuse.md: Attributes) |
| `fuse/vectors_test.go` | runs every `packs/fuse-*` scenario vector and every `spec/fuse-load-vectors` load vector |
| `vectors_test.go` | runs every correlate scenario vector and every load vector with the structural comparison of `spec/vector-format.md` |

## Build

Requires Go 1.26.

```
cd engines/go
go build ./...
```

## Run the vectors

```
cd engines/go
go test -count=1 -v ./...
```

`TestScenarioVectors` loads each `packs/correlate-*/vectors/*.json`, runs its steps
on one engine, compares each step's events and trace, then compares the final
snapshot. `TestLoadVectors` parses each `spec/correlate-load-vectors/*.json` and checks
that it fails or succeeds as `expect_error` says. A failure prints the path of
the first mismatch, for example `steps[2].trace[0].value: got ..., want ...`.

`TestFuseScenarioVectors` and `TestFuseLoadVectors` (package `fuse`) do the same
for `packs/fuse-*/vectors/*.json` and `spec/fuse-load-vectors/*.json`.
