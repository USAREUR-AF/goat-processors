# goat-correlator: Go engine

An implementation of `spec/correlate.md` (version 0.4, method `confirm`) and
`spec/correlate-assign.md` (version 0.2, method `assign`) in Go, standard library only.
The pack's `method` line selects which runs.
It was written from the specification and the vectors alone, without
reference to any other engine.

| File | Contents |
|---|---|
| `pack.go` | `LoadPack(dir)` / `ParsePack(text)`: the `pack.def` reader (spec: Pack) |
| `engine.go` | `New(pack)`, `Ingest(report)`, `Tick(now_ms)`, `Snapshot()`: frame, filter, tests, association, events and trace |
| `assign.go` | method `assign`: system tracks, per-source exact least-cost assignment (shortest augmenting paths with potentials), inverse-variance fused estimate, its events, trace and snapshot |
| `assign_test.go` | checks the assignment solver against brute force |
| `DISAGREEMENTS.md` | vectors that contradict the specification (none), and the points it leaves open |
| `vectors_test.go` | runs every scenario vector and every load vector with the structural comparison of `spec/vector-format.md` |

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

`TestScenarioVectors` loads each `packs/<pack>/vectors/*.json`, runs its steps
on one engine, compares each step's events and trace, then compares the final
snapshot. `TestLoadVectors` parses each `spec/correlate-load-vectors/*.json` and checks
that it fails or succeeds as `expect_error` says. A failure prints the path of
the first mismatch, for example `steps[2].trace[0].value: got ..., want ...`.
