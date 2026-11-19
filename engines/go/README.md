# goat-correlator: Go engine

An implementation of `spec/correlate.md` (version 0.5, method `confirm`, with
the optional two-model filter) and `spec/correlate-assign.md` (version 0.3,
method `assign`, with the multi-frame window) in Go, standard library only.
The pack's `method` line selects which runs.
It was written from the specification and the vectors alone, without
reference to any other engine.

| File | Contents |
|---|---|
| `pack.go` | `LoadPack(dir)` / `ParsePack(text)`: the `pack.def` reader (spec: Pack) |
| `engine.go` | `New(pack)`, `Ingest(report)`, `Tick(now_ms)`, `Snapshot()`: frame, Kalman axis steps, tests, association, events and trace |
| `imm.go` | the per-entity filter: one model (Track estimate) or two (Two-model filter: switching, mixing, likelihood, mode probabilities, combination, prediction) |
| `assign.go` | method `assign`: memberships and histories (Memberships), columns and entries of one source, ranked assignments by enumeration in choice-vector order (Ranking), the per-tick steps 1 to 5 (Window), fused estimate, snapshot |
| `assign_test.go` | checks the ranked assignments follow the Ranking order on random tables |
| `DISAGREEMENTS.md` | vectors that contradict the specification (none), and the points it leaves open |
| `vectors_test.go` | runs every `packs/correlate-*` scenario vector and every `spec/correlate-load-vectors` vector with the structural comparison of `spec/vector-format.md` |

Ranked assignments are found by brute force: every assignment of a source's
tracks is enumerated, which is exact and fine at vector sizes but grows
factorially with the number of tracks one source reports at once.

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

`TestScenarioVectors` loads each `packs/correlate-*/vectors/*.json`, runs its steps
on one engine, compares each step's events and trace, then compares the final
snapshot. `TestLoadVectors` parses each `spec/correlate-load-vectors/*.json` and checks
that it fails or succeeds as `expect_error` says. A failure prints the path of
the first mismatch, for example `steps[2].trace[0].value: got ..., want ...`.
