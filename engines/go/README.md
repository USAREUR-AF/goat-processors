# goat-correlator: Go engine

The Go engine of every function, standard library only:

- `spec/correlate.md` version 0.8 (method `confirm`, the optional two-model filter, filter restart and time quality);
- `spec/correlate-assign.md` version 0.6 (method `assign`, with the multi-frame window, its margin, sensor bias and the clock offset);
- `spec/filter.md` version 0.1;
- `spec/fuse.md` version 0.2;
- `spec/quality.md` version 0.2.

It was written from the specification and the vectors alone, without
reference to any other engine. `REFACTOR.md` records the refactor that gave
it this layout.

## Layout

One Go package per module. Every function has the same entry-point shape,
`model.Engine`: `Load(dir)` (or `LoadPack` then `New`), then `Ingest(report)`
and `Tick(now_ms)`, each returning its events and trace records, and
`Snapshot()`.

| Package | Holds |
|---|---|
| `model/` | what every function shares, all of it pure: `Obj`, `Engine`, the frame, the constant-velocity filter, the two-model math, the report rules, time quality |
| `correlate/` | `correlate.md`: the engine (reports, filter state, restart, tests), the method table, method `confirm` |
| `assign/` | `correlate-assign.md`: method `assign`, which reads the correlate engine's entities only through `assign.Core` |
| `filter/` | `filter.md` |
| `fuse/` | `fuse.md` |
| `quality/` | `quality.md` |
| `trace/` | every trace record shape, one constructor each |
| `snapshot/` | the snapshot value encoders, and the decoders a restore reads with |
| `io/` | JSON input, steps files, the runner's events file, the `pack.def` file and parameter helpers, the vector comparison of `vector-format.md` |
| `runner/` | the command-line runner of `tools/perf/README.md` (`runner/build`, `runner/run`) |
| `.` (root) | no code; its test runs the correlate vectors (the perf harness times that binary here) |

## Extension points

Each kind of extension is one row in one table:

| Kind | Table | Registration |
|---|---|---|
| a correlate test | `correlate.DefaultTests()` (`correlate/tests.go`) | a `TestKind` (parameters, pure `Run(Test, Pair) Outcome`) in a `correlate.Registry`, read with `ParsePackWith` / `LoadPackWith` |
| a correlate method | `methods` (`correlate/methods.go`) | its directives, checks and constructor of the `method` interface |
| a quality measure | `quality.DefaultMeasures()` (`quality/measures.go`) | a `Measure` (entity value from a `Window`, source `Aggregate`) in a `quality.Registry`, read with `ParsePackWith` / `LoadPackWith` |
| a filter condition | `conditions` (`filter/conditions.go`) | its parameter sets and evaluation |
| a fuse kinematics method, attribute rule | `kinematicsMethods` (`fuse/kinematics.go`), `attributeRules` (`fuse/attributes.go`) | one function, one rule |

The default tables are built by a function at each pack load, so a test can
register a kind in its own copy without touching any other pack: the test
kind `noop` exists only in `correlate/noop_test.go` (with its fixture packs
in `correlate/testdata/`), and the measure `always_one` only in
`quality/registry_test.go`.

## Where each spec section lives

### `spec/correlate.md`

| Section | File |
|---|---|
| What the correlator does | `correlate/engine.go` |
| Reports | `model/reports.go` (rules), `correlate/reports.go` (the measurement of one report) |
| Reports, Time quality | `model/timequality.go` (reading, `time_default`, measurement variance), `correlate/reports.go` (per-key resolution, `time` record) |
| Frame | `model/frame.go` |
| Track estimate | `model/kalman.go` (the steps), `correlate/track.go` (the entity's filter) |
| Two-model filter | `model/imm.go` (the math), `correlate/track.go` (the entity's models) |
| Restart | `correlate/restart.go` |
| Tests | `correlate/tests.go` |
| Association | `correlate/confirm.go` |
| Events | `correlate/engine.go` (`new`, `reject`), `correlate/confirm.go` (the rest) |
| Trace | `trace/correlate.go` |
| Snapshot | `correlate/confirm.go` (`snapshotConfirm`), `correlate/track.go` (`filterSnapshot`) |
| Pack | `correlate/pack.go`, with each method's directives in `correlate/methods.go` |
| Floats | this README, Floats |

### `spec/correlate-assign.md`

| Section | File |
|---|---|
| What this method does | `assign/assign.go` |
| Shared with `correlate.md` | `correlate/assign.go` (the method table row and `assign.Core`) |
| Memberships | `assign/membership.go` |
| Assignment of one source | `assign/table.go` |
| Sensor bias (and Time offset) | `assign/bias.go` |
| Ranking | `assign/ranking.go` |
| Window | `assign/window.go` |
| Events | `assign/window.go`, `assign/membership.go` |
| Trace | `trace/correlate.go` |
| Snapshot | `assign/snapshot.go` |
| Pack | `correlate/pack.go`, `correlate/methods.go` (row `assign`) |

### `spec/filter.md`

| Section | File |
|---|---|
| What the filter does | `filter/engine.go` |
| Reports | `filter/reports.go` (rules in `model/reports.go`) |
| Geometry | `filter/geometry.go` |
| Conditions | `filter/conditions.go` |
| Rules | `filter/rules.go` |
| Tick | `filter/tick.go` |
| Events | `filter/rules.go`, `filter/tick.go` |
| Trace | `trace/filter.go` |
| Snapshot | `filter/snapshot.go` |
| Pack | `filter/pack.go` |

### `spec/fuse.md`

| Section | File |
|---|---|
| What fuse does | `fuse/engine.go` |
| Shared with `correlate.md` | `model/frame.go`, `model/kalman.go`, `model/reports.go` |
| Reports | `fuse/reports.go` |
| Groups | `fuse/groups.go` |
| On each tick, Fused event | `fuse/tick.go` |
| Kinematics | `fuse/kinematics.go` |
| Attributes | `fuse/attributes.go` |
| Events | `fuse/reports.go`, `fuse/tick.go` |
| Trace | `trace/fuse.go` |
| Snapshot | `fuse/snapshot.go` |
| Pack | `fuse/pack.go` |

### `spec/quality.md`

| Section | File |
|---|---|
| What quality does | `quality/engine.go` |
| Reports | `quality/reports.go` |
| Reports, Time quality | `quality/time.go` (validity in `model/timequality.go`) |
| Order | `quality/ingest.go` |
| Frame and filter | `quality/ingest.go` (the frame and filter of `model`) |
| Input clock | `quality/time.go` |
| Samples, Ingest | `quality/ingest.go` |
| Window, Entity measures, Source measures | `quality/measures.go` |
| Rules | `quality/rules.go` |
| Forwarding | `quality/forwarding.go` |
| Tick | `quality/tick.go` |
| Events | `quality/ingest.go`, `quality/forwarding.go`, `quality/tick.go`, `quality/rules.go` |
| Trace | `trace/quality.go` |
| Snapshot | `quality/snapshot.go` |
| Pack | `quality/pack.go` |

### `spec/vector-format.md`

| Section | File |
|---|---|
| Scenario vectors | `io/io.go` (`ParseSteps`), `io/compare.go` (`CheckVector`) |
| What the engine checks | `io/compare.go` (`Mismatch`) |
| Load vectors | `io/loadvectors.go` |

Ranked assignments are found by brute force: every assignment of a source's
tracks is enumerated, which is exact and fine at vector sizes but grows
factorially with the number of tracks one source reports at once.

## Build

Requires Go 1.26.

```
cd engines/go
go build ./...
runner/build        # the perf harness's runner, into runner/bin/
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
go test -count=1 ./...
```

`TestScenarioVectors` (in `.` for correlate, and in `filter/` and `quality/`;
`TestFuseScenarioVectors` in `fuse/`) loads each `packs/<function>-*/vectors/*.json`,
runs its steps on one engine, compares each step's events and trace, then
the final snapshot. `TestLoadVectors` (`TestFuseLoadVectors`) parses each
`spec/<function>-load-vectors/*.json` and checks that it fails or succeeds as
`expect_error` says. A failure prints the path of the first mismatch, for
example `steps[2].trace[0].value: got ..., want ...`.

## Tests and coverage

`go test ./...` runs, besides the vectors: unit tests in every package;
`proptest/` (determinism, order independence where the specifications say
order does not matter, snapshot then restore for filter, fuse and quality,
and seeded fuzzing of every pack.def parser, the JSON reader and the
engines on arbitrary report values). Coverage is go's own:

```
go test -coverpkg=./... -coverprofile=cover.out ./...
go tool cover -func=cover.out | tail -1
```

CI fails below 97.7 % of statements (`REFACTOR.md`).

## Run the runner

```
runner/build
runner/run --function correlate --pack ../../packs/correlate-gnn --steps ../../packs/correlate-gnn/vectors/01-two-sources-one-object.json --events /tmp/out.jsonl --trace
```

It prints one line of counters; `--events` writes one line per step and the
snapshot (`tools/perf/README.md`, Runner contract).
