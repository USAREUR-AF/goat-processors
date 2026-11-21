# goat-processors, zig engine

An implementation of `spec/correlate.md` (version 1.0, method `confirm`, with
the two-model filter, the filter restart, the time quality of a report, the
`state` test, confirmation by sequential test (`sprt`), staleness from each
source's update interval (`stale_rate`) and the `fused` output),
`spec/correlate-assign.md` (version 0.7, method `assign`, with the multi-frame
window and its margin, the filter restart, the sensor bias and its clock
offset, the `state` test and `stale_rate`), `spec/filter.md` (version 0.1), `spec/fuse.md` (version 0.2) and
`spec/quality.md` (version 0.2, with time quality) in Zig 0.13.0, standard
library only. It was written from the specifications and the vectors, not
from another engine. Points the specifications leave open, and how this
engine decides them, are in `DISAGREEMENTS.md`. How the engine was
restructured, and how its output was kept byte for byte, is in `REFACTOR.md`.

## Layout

The modules are the same in every engine: model, filter, correlate, assign,
fuse, quality, trace, snapshot, IO. Each is a directory of `src/`.

| Module | Holds |
|---|---|
| `src/model/` | what more than one function shares: the Frame, the track estimate (one filter and the two-model filter), the report key readers, the shared pack parameter types |
| `src/correlate/` | the function correlate: its pack, its entity, the test registry, the engine (`ingest`, `tick`, `snapshot`, the stale time of a source), the method registry and method `confirm` (with its sequential test, `sprt.zig`) |
| `src/assign/` | correlate's method `assign` (`correlate-assign.md`): ranking, window and sensor bias |
| `src/filter/` | the function filter (`filter.md`) |
| `src/fuse/` | the function fuse (`fuse.md`) |
| `src/quality/` | the function quality (`quality.md`), with the measure registry |
| `src/trace/` | the `Result` of an operation (events, then trace records) and the record builders |
| `src/snapshot/` | every function's `snapshot()` |
| `src/io/` | reading and writing JSON, steps files, the runner, the vector tests' reader and comparison |
| `src/api.zig` | the one entry point, below |

### The entry point

Every function module (`api.Module(.correlate)`, `.filter`, `.fuse`,
`.quality`) has the same shape, checked at compile time by `src/api.zig`:

```
Pack                                 the parsed pack.def
load_pack(alloc, dir) !Pack          spec operation load_pack(dir)
Engine.create(backing, pack) !*Engine
engine.ingest(report) !Result        one input entity
engine.tick(now_ms) !Result          one tick
engine.snapshot() !json.Value        the spec's Snapshot
engine.destroy()
```

`Result` (`src/trace/record.zig`) holds the operation's events and trace
records. The state lives only in the engine object; `snapshot()` writes it.
There are no globals.

### Extending

| To add | Change one place |
|---|---|
| a correlate method | one entry in `table` of `src/correlate/methods.zig` |
| a correlate test | one entry in `builtin` of `src/correlate/tests.zig` (a name, its parameters and a pure `run`); a test-only kind is registered with `tests.Registry` and `pack.parseWith` (see `src/correlate/noop_test.zig`, with its fixture pack and vector in `src/correlate/testdata/noop/`) |
| a quality measure | one entry in `table` of `src/quality/measures.zig` (name, scope, entity measure, source aggregate) |

## Where each spec section lives

### `spec/correlate.md`

| Section | File |
|---|---|
| What the correlator does | `src/correlate/engine.zig` |
| Reports (and Time quality) | `src/model/report.zig` |
| Frame | `src/model/frame.zig` |
| Track estimate | `src/model/kalman.zig` (the measurement variance and the timing variance: `src/correlate/estimate.zig`) |
| Two-model filter | `src/model/imm.zig` |
| Restart | `src/correlate/estimate.zig` |
| Tests (the `state` test and its chi-square table included) | `src/correlate/tests.zig` |
| Association | `src/correlate/confirm.zig`; the evidence of Sequential test in `src/correlate/sprt.zig`; Stale time of a source in `src/correlate/engine.zig` |
| Events | `src/correlate/confirm.zig` (method confirm), `src/assign/assign.zig` (method assign) |
| Trace | `src/trace/record.zig` |
| Snapshot | `src/snapshot/correlate.zig` |
| Pack | `src/correlate/pack.zig` |
| Floats | this README, "Floats" |

### `spec/correlate-assign.md`

| Section | File |
|---|---|
| What this method does | `src/correlate/methods.zig` (its registration), `src/assign/assign.zig` |
| Shared with `correlate.md` | `src/correlate/engine.zig` |
| Memberships | `src/assign/membership.zig` |
| Assignment of one source | `src/assign/assign.zig` |
| Sensor bias | `src/assign/bias.zig` |
| Ranking | `src/assign/ranking.zig` |
| Window | `src/assign/assign.zig` |
| Events | `src/assign/assign.zig` |
| Trace | `src/trace/record.zig` |
| Snapshot | `src/snapshot/assign.zig` |
| Pack | `src/correlate/pack.zig` |

### `spec/filter.md`

| Section | File |
|---|---|
| What the filter does, Reports, Rules, Tick, Events | `src/filter/engine.zig` |
| Geometry | `src/filter/geo.zig` |
| Conditions | `src/filter/conditions.zig` |
| Trace | `src/trace/record.zig` |
| Snapshot | `src/snapshot/filter.zig` |
| Pack | `src/filter/pack.zig` |

### `spec/fuse.md`

| Section | File |
|---|---|
| What fuse does, Reports, Groups, On each tick, Fused event, Events | `src/fuse/engine.zig` |
| Shared with `correlate.md` | `src/model/` |
| Kinematics | `src/fuse/kinematics.zig` |
| Attributes | `src/fuse/attributes.zig` |
| Trace | `src/trace/record.zig` |
| Snapshot | `src/snapshot/fuse.zig` |
| Pack | `src/fuse/pack.zig` |

### `spec/quality.md`

| Section | File |
|---|---|
| What quality does, Order, Frame and filter, Input clock, Samples, Forwarding, Tick, Ingest, Events | `src/quality/engine.zig` |
| Reports (Time quality) | `src/model/report.zig` |
| Window, Entity measures, Source measures | `src/quality/measures.zig` |
| Rules | `src/quality/rules.zig` |
| Trace | `src/trace/record.zig` |
| Snapshot | `src/snapshot/quality.zig` |
| Pack, Packs | `src/quality/pack.zig` |
| Vectors | `src/quality_vectors_test.zig` |

### `spec/vector-format.md`

| Section | File |
|---|---|
| Scenario vectors, Load vectors | `src/io/vectors.zig` |
| What the engine checks | `src/io/compare.zig` |

### `tools/perf/README.md` "Runner contract"

`runner/build`, `runner/run`, `src/main.zig` and `src/io/runner.zig`.

## Floats

Zig's default float mode is strict: no fused multiply-add contraction and no
extended precision (binary64 on SSE2), as `correlate.md` "Floats" requires.
No file sets `@setFloatMode(.optimized)`.

## Build and run the vectors

```
cd engines/zig
zig build test
```

This runs the unit tests of every module (`src/unit_test.zig`) and every
load vector and scenario vector of the four functions: each step's events
and trace, then the final snapshot. It prints a count per kind and, for a
vector that fails, the path of the first mismatch, for example
`01-two-sources-one-object.steps[1].trace[0].value`. Vector files of any
size are read.

The directories default to `../../packs`, `../../spec/correlate-load-vectors`,
`../../spec/fuse-load-vectors`, `../../spec/filter-load-vectors` and
`../../spec/quality-load-vectors` relative to this directory. Override them with
`zig build test -Dpacks=<dir> -Dload-vectors=<dir> -Dfuse-load-vectors=<dir> -Dfilter-load-vectors=<dir> -Dquality-load-vectors=<dir>`.

## Tests

`zig build test` runs, besides the vectors:

| Root | What |
|---|---|
| `src/unit_test.zig` | the unit tests of every module (each file's `unit_tests` struct, kept out of the vector test binaries), the registries and the no-op test kind (`src/correlate/noop_test.zig`) |
| `src/property_test.zig` | property tests over every scenario vector: determinism (twice, the same bytes); order independence where the specifications say order does not matter: the key order of a report, the order of `name=value` parameters on a pack line, and in a filter pack the other directives after the rules |
| `src/fuzz_test.zig` | seeded fuzzing (seed `0x60a7`, `FUZZ_SEED` and `FUZZ_ITERATIONS` override): mutated pack.def texts through all four parsers, mutated vector files through the JSON and steps readers, generated reports through the engine of every pack; bounded to seconds |

Snapshot then restore: the engine has no restore operation (no specification
defines one), so that property is not tested.

## Coverage

Zig 0.13 has no coverage instrumentation of its own (no `-fprofile`, no
sanitizer coverage; kcov would be a third-party package). `coverage/run.sh`
measures line coverage with gdb and objdump instead: a one-shot breakpoint on
the first statement address of every line of the DWARF line table, the test
binaries and a Debug runner run under gdb, a line covered when its breakpoint
was hit. Test code (the test roots, `*_test.zig`, `engine_test_util.zig`,
each file's `unit_tests` struct) is left out. `coverage/run.sh --check` fails below
`coverage/floor`, and CI runs it in this engine's job.

| | Lines | Coverage |
|---|---|---|
| Baseline (commit a2b8791, before the refactor: vectors and runner) | 3,025 of 3,077 | 98.3 % |
| Floor, max(baseline, 80 %) | | 98.3 % |
| Now (correlate 1.0, assign 0.7) | 3,468 of 3,502 | 99.0 % |

## The runner

```
runner/build      # zig build-exe -O ReleaseFast src/main.zig
runner/run --function <correlate|filter|fuse|quality> --pack <dir> --steps <file> [--events <file>] [--trace]
```

as `tools/perf/README.md` "Runner contract" states.
