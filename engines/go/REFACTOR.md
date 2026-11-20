# Go engine: the refactor of 2026-11-20

The brief: `~/inbox/proc/round-refactor.md` ("What done means"). Written from
the specification, the vectors, `tools/perf/README.md` and this directory
only. Branch `refactor/go`, one signed commit per step:

| Step | Commit |
|---|---|
| 1. Runner (`runner/build`, `runner/run`), golden output recorded | `feat(go): runner for the perf harness` |
| 2. Layout, one entry-point shape, README spec map | `refactor(go): one module layout ...` |
| 3. Pure functions for the math | `refactor(go): pure functions for the math` |
| 4. One registration point per extension kind | `refactor(go): one registration point per extension kind` |
| 5. Tests, coverage floor in CI | `test(go): unit tests per module, property tests, fuzzing, coverage floor in CI` |
| 6. Hot spots | `perf(go): the three hot spots of the large scenario`, `perf(go): no function slower: ...` |
| This file | `docs(go): REFACTOR.md` |

Out of scope and left as they were (correlate 1.0 replaces them): the
confirm method's pipeline (gate, confirm and hold stages, `confirm_count`,
`hold_failures`), the `window` test, the `same` tests, `output
priority|latest` and fixed staleness. They are moved, unchanged in logic, to
`correlate/confirm.go` and `correlate/tests.go` and called through the new
entry point.

## Layout

One Go package per module, the names every engine uses:

| Package | Holds |
|---|---|
| `model/` | shared and pure: `Obj`, the `Engine` interface (the entry-point shape), frame, constant-velocity filter steps, two-model (IMM) math, report rules, time quality |
| `correlate/` | the correlate engine: reports, per-entity filter state, restart, the Tests table, the method table, method confirm |
| `assign/` | method assign: memberships, table and cost, Ranking, Window, sensor bias and clock offset, snapshot. It reads the correlate engine's entities only through the `assign.Core` interface, so it does not import `correlate` |
| `filter/`, `fuse/`, `quality/` | those functions, one file per spec section |
| `trace/` | every trace record shape of every function, one constructor each |
| `snapshot/` | snapshot value encoders and the `Decoder` that restores read with |
| `io/` | JSON reader, steps files, `Run`, the events file, `pack.def` file and `name=value` helpers, the `vector-format.md` comparison |
| `runner/` | the perf harness's runner (Runner contract) |
| `proptest/` | property tests and fuzzing (test files only) |
| `.` | no code; its test runs the correlate vectors, where the harness times it |

Every function's entry point has one shape, `model.Engine`: `Load(dir)`
(or `LoadPack` + `New`), then `Ingest(report)` and `Tick(now_ms)`, each
returning `(events, trace []Obj)`, and `Snapshot()`. `README.md` maps every
section of every specification to the file that implements it.

**Functional style.** The math is pure functions of values: `model.Axis`
steps, `FilterParams.First/Update/Step`, `IMM.Update/Predict`,
`Mahalanobis`, `MeasurementVariance`; correlate's tests are pure functions of
a `Pair` (A, and B predicted to A's time); assign's `ivSum` (fused
estimate), `costOf`, `table.ranked`, `BiasState.update/move/fitTimeOffset`;
fuse's kinematics methods (covariance intersection returns its fold
weights); quality's `nisOf`, `speedErrOf`, `median`, the measures over a
`Window`, `Rule.step`; filter's conditions read the state map and change
nothing. State lives only in each engine object (and its snapshot). There
are no mutable package-level variables: every one is a read-only table or a
compiled regular expression, and the extension tables a caller may change
(`DefaultTests`, `DefaultMeasures`) are built anew at each pack load.

## Registration points

| Kind | Where | Adding one |
|---|---|---|
| correlate test | `correlate.DefaultTests()` in `correlate/tests.go` | one `TestKind{Params, Text, Run}` entry; a caller registers its own in a `correlate.Registry` and reads packs with `ParsePackWith` / `LoadPackWith` |
| correlate method | `methods` in `correlate/methods.go` | one row: required and refused directives, value checks, constructor of the `method` interface |
| quality measure | `quality.DefaultMeasures()` in `quality/measures.go` | one `Measure{Name, Entity, Source}` row (entity value from a `Window`, source `Aggregate`); a caller registers its own in a `quality.Registry` |
| filter condition | `conditions` in `filter/conditions.go` | one row: parameter sets and evaluation |
| fuse kinematics method / attribute rule | `kinematicsMethods`, `attributeRules` | one row |

**The proof: the no-op test kind `noop`**, registered only in
`correlate/noop_test.go`, with test-only fixture packs
`correlate/testdata/noop-confirm/pack.def` and `noop-assign/pack.def`
(correlate-gnn and correlate-assign with `noop` first on each test line;
not under `packs/`, not in the spec):

- `TestNoopUnknownByDefault`: the default table does not know `noop`, so the fixtures do not load without it (no shipped pack can name it);
- `TestNoopInvisible`: every correlate vector passes with `noop` registered;
- `TestNoopVector`: the correlate-gnn and correlate-assign vectors run on the fixtures give every vector's events and snapshot, and its trace once the `noop` records (value and limit null, pass true) are taken out.

The measure registry has the same kind of test: `quality/registry_test.go`
registers `always_one` and runs a fixture pack's rules on it.

## Tests and coverage

`cd engines/go && go test ./...` runs:

- the conformance vectors (unchanged in what they check), now through `io.CheckVector`;
- unit tests in every package: `model`, `trace` (every record shape pinned as JSON), `snapshot`, `io`, `correlate` (pack errors, every test kind, rejects, restart, time quality, `assign.Core`), `assign` (memberships, fused estimate, cost, bias and clock-offset fit, a window commit; Ranking against its definition on random tables), `filter`, `fuse`, `quality` (small, since the harness times these binaries), `runner`;
- `proptest/`, property tests:
  - determinism: every vector of every shipped pack and three seeded scenarios per pack, four runs each, byte-identical (Go randomizes map order on every run);
  - order independence where the specifications say order does not matter: JSON object member order (every vector re-encoded with members shuffled); `filter.md` "Other directives may appear in any order relative to the rules" (directive lines moved at random); for method assign (rows in key order at the tick) and fuse (groups in output order at the tick), the reports of different entities between two ticks in any order;
  - snapshot then restore: filter, fuse and quality gain `Restore(pack, snapshot)`; on every vector and two seeded scenarios, a snapshot taken at about a dozen points, written as JSON, read back and restored continues with byte-identical output and final snapshot. **Correlate does not support restore**: its snapshot (spec-defined) holds neither an entity's last report, which the tests, staleness and output read, nor what a pending history needs, so an engine cannot be rebuilt from it;
- fuzzing, with seeded generators written in the tests (`math/rand/v2` PCG, fixed seeds, bounded: 1,500 mutated inputs per parser): every function's pack.def parser on mutations of the shipped packs and load vectors; the JSON reader on mutations of the vectors; every shipped pack on reports whose keys hold values of every JSON type. No input panics; a pack that loads loads the same twice and runs. `Fuzz*` targets take the same seeds for longer `go test -fuzz` runs.

The fuzzing found two points, both older than the refactor, written in
`DISAGREEMENTS.md` for proc-coord and not changed (a change would alter
output): a longitude of 1e17 degrees or more makes the frame's wrap loop
forever, and inputs extreme enough to make an output non-finite cannot be
written as JSON.

**Coverage**, measured with Go's own tool (statement coverage, the closest
Go has to line coverage), over every package from every test binary:
`go test -coverpkg=./... -coverprofile=cover.out ./...` then
`go tool cover -func=cover.out`.

| | Statements covered |
|---|---|
| Baseline: the pre-refactor engine (main, `407a295`) | 97.7 % |
| Floor: max(baseline, 80 %) | 97.7 % |
| Measured after the refactor | 99.7 % |

Per package from its own tests alone (`go test -cover`): model 100 %,
snapshot 100 %, trace 100 %, correlate 98.5 %, runner 98.2 %, io 98.1 %,
filter 97.5 %, fuse 95.8 %, quality 94.5 %, assign 85.7 %.

CI enforces the floor in the `go` job of `.github/workflows/conformance.yml`
only: it runs the tests with the coverage profile and fails when the total is
below 97.7 %.

## Hot spots

Profiled through the runner (`--cpuprofile`, added for diagnostics; the
contract's arguments are unchanged) on the large scenario of
`perf.py generate --size large`, every pack the harness names.

| # | Hot spot | Fix | Before | After |
|---|---|---|---|---|
| 1 | `assign` Ranking enumerated every assignment of a source, then stable-sorted the whole list (sort's memmove and reflection swaps: 64 % of the CPU) to keep k | keep the k best during the enumeration, inserting after equal totals, which is the stable-sort order; sum each total with a reused buffer | correlate-assign-time run 166 s (CPU 49.6 s) | 22 s (CPU 5.8 s) |
| 2 | the enumeration itself (`totalOf`, 50 % after fix 1) | skip a branch when a lower bound of its exact sum (rows so far plus each remaining row's smallest entry), less a margin above any rounding of a binary64 sum, is not below the k-th total: only assignments that would be refused are skipped | 22 s | 3.8 s |
| 3 | quality's tick: a map lookup per window record for the time state code, new slices per entity per tick (`windowOf` 38 % of the CPU) | the code is kept in the record at ingest; one scratch `Window` per engine is reused | quality-time CPU 1.23 s, tick 0.66 s | CPU 0.87 s, tick 0.26 s |

Fixes 1 and 2 are checked against the definition (enumerate all, stable
sort, first k) on 2,400 random tables with many equal totals and with
magnitudes whose sums round (`assign/ranking_test.go`). What remains in
every profile is allocating the events and trace records themselves (the
output) and the garbage collector; correlate-gnn-imm, filter-thin and
fuse-independent have no hot spot of the engine's own above that.

Interleaved checks with the pre-refactor engine then found
correlate-gnn-imm 2-4 % behind in CPU time. Trace records that gained keys
after a seven-key literal grew and rehashed their maps, and each two-model
update moved a step result to the heap. A fourth commit (`perf(go): no
function slower ...`) builds every record at its full size, updates the
IMM state in place and parses a report's course, speed and hae once when
first read. gnn-imm is now about 4 % ahead (CPU, 8 interleaved rounds of
15 runs: 0.218 s against 0.227 s).

## Before and after

`python3 -I tools/perf/perf.py baseline --engines go`, on this machine
(16 cores; `docs/performance.md` names it), committed tree only. **before**:
run at the start, on `8b6a49f` (the pre-refactor engine with the step-1
runner; main has no runner). **before2**: the same commit again, later.
**final**: the last commit. The machine was shared with other sessions
throughout, at load averages from 7 to above 100 (below), so one cell can
move by a factor of two between runs of the same code (before against
before2). Each cell is the harness's median (10 runs on the vectors, 3 on
the large scenario).

| Measure | before | before2 | final |
|---|---|---|---|
| vector tests correlate, wall s | 0.210 | 0.277 | 0.118 |
| vector tests filter, wall s | 0.078 | 0.087 | 0.031 |
| vector tests fuse, wall s | 0.057 | 0.019 | 0.028 |
| vector tests quality, wall s | 0.105 | 0.107 | 0.101 |
| large vector command correlate (2 packs), wall s | 161.46 | 171.84 | 21.97 |
| large vector command filter, wall s | 5.90 | 5.81 | 3.90 |
| large vector command fuse, wall s | 2.40 | 3.40 | 2.05 |
| large vector command quality, wall s | 9.01 | 13.86 | 6.70 |
| runner correlate-gnn-imm, reports/s (run s) | 29,389 (0.632) | 23,831 (0.779) | 36,013 (0.516) |
| runner correlate-assign-time, reports/s (run s) | 140 (133.1) | 120 (155.3) | 4,210 (4.41) |
| runner filter-thin, reports/s (run s) | 14,037 (1.323) | 23,111 (0.804) | 23,679 (0.784) |
| runner fuse-independent, reports/s (run s) | 26,485 (0.701) | 53,206 (0.349) | 74,743 (0.248) |
| runner quality-time, reports/s (run s) | 5,203 (3.569) | 6,767 (2.744) | 16,266 (1.142) |
| runner peak memory, MB: gnn-imm, assign-time, filter, fuse, quality | 92, 939, 132, 81, 223 | 92, 944, 131, 81, 230 | 95, 559, 131, 79, 188 |

Load averages (start, end): before 7 to 149, before2 106 to 25, final
6.5 to 67.

Because single runs are this noisy, every cell that ever read slower was
measured again interleaved: old and new binaries alternating, 21 or 31
times each, same input, medians compared (wall and user+sys CPU time):

| Command | before | final |
|---|---|---|
| vector test binary `.` (correlate), wall ms | 179 | 131 |
| vector test binary `filter`, wall ms (CPU s) | 101 (0.01) | 101 (0.00) |
| vector test binary `fuse`, wall ms | 27.4 | 27.9 |
| vector test binary `quality`, wall ms | 108 | 99 |
| runner gnn-imm, wall ms (CPU s) | 1,332 (0.40) | 1,284 (0.39) |
| runner filter-thin, wall ms (CPU s) | 1,681 (0.55) | 1,587 (0.54) |
| runner fuse-independent, wall ms | 923 | 808 |
| runner quality-time, wall ms | 4,276 | 2,691 |

No function is slower. The fuse vector binary is level (27.4 against 27.9
ms, within the spread of its runs). correlate-gnn-imm's runner uses 3 MB
more peak memory (95 against 92).

## Byte-identical check

Step 1 recorded the golden output outside the repository with the runner
(`--events --trace`): every scenario vector of every function run with its
own pack (121), the large scenario with every pack the harness names (5),
and every load vector (218, its exit status, and for the 40 that load, the
events file of an empty run). That is 344 runs and 510 files. After every
later step every run was repeated and every file compared with `cmp`:
**510 of 510 files identical** after each of steps 2 to 6 and at the end.
