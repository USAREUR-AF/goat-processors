# goat-processors: Erlang engine

Four functions, from their specifications in `spec/`: correlate
(`correlate.md` 0.8, method `confirm`, and `correlate-assign.md` 0.6, method
`assign`), filter (`filter.md` 0.1), fuse (`fuse.md` 0.2) and quality
(`quality.md` 0.2). Erlang/OTP 27, standard library only; JSON is read with
OTP 27's `json` module.

## Layout

One directory per area, the same areas as the other engines: model, filter,
correlate, assign, fuse, quality, trace, snapshot, IO. Erlang has one flat
module namespace, so each module's name starts with its area (`model_kalman`,
`trace_fuse`); the four entry modules are `correlate`, `filter`, `fuse` and
`quality`. OTP already has modules named `io` and `trace`, so those areas'
modules are `io_*` and `trace_*`.

| Directory | Holds |
|---|---|
| `src/model/` | what every function shares: reports, frame, the Kalman filter, the two-model filter |
| `src/correlate/` | the correlator's entry point, its methods table, tests table, pack, and the confirm method |
| `src/assign/` | method assign: memberships, costs, ranking, sensor bias |
| `src/filter/` | the filter: entry point, conditions, geometry, pack |
| `src/fuse/` | fuse: entry point, kinematics, attributes, pack |
| `src/quality/` | quality: entry point, samples, measures, rules and forwarding, pack |
| `src/trace/` | each function's events and trace records, and the output of one call (`trace_log`) |
| `src/snapshot/` | each function's `snapshot()` |
| `src/io/` | pack.def text, the function table, the runner, the vector runner |
| `test/` | EUnit tests and test-only fixture packs |

## Entry point

Every function module has the same shape (`io_engine`'s behaviour):

```
load_pack(Dir)            -> {ok, Pack} | {error, Why}
new(Pack)                 -> State
ingest(Report, State)     -> {Events, Trace, State}
tick(NowMs, State)        -> {Events, Trace, State}
snapshot(State)           -> map()
```

The state is a value. Nothing is kept anywhere else: no process
dictionary, no ETS table, no registered process. The math (filter predict
and update, the two-model filter, gating, costs, ranking, sensor bias,
kinematics, measures) is in pure functions of their arguments.

## Extension points

Adding a kind is one entry in one table:

| Kind | Table | Also per pack |
|---|---|---|
| correlate method | `correlate_methods:builtin/0` (name => module with the `correlate_methods` behaviour) | `correlate:load_pack(Dir, #{methods => #{Name => Module}})` |
| correlate test | `correlate_test_kinds:builtin/0` (name => parameters, value grammar, function) | `correlate:load_pack(Dir, #{tests => #{Name => Kind}})` |
| quality measure | `quality_measures:builtin/0` (name, entity function, source aggregation) | `quality:load_pack(Dir, #{measures => [Measure]})` |
| filter condition | `filter_conditions:table/0` | |
| fuse kinematics method, attribute rule | `fuse_kinematics:methods/0`, `fuse_attributes:rules/0` | |

`test/registration_tests.erl` proves it for a test kind: a no-op test,
`noop`, registered only in that test by one entry passed to
`correlate:load_pack/2`, with its own fixture pack
(`test/fixtures/correlate-noop`, not under `packs/`). Registered, it changes
no output of any correlate vector; in the fixture pack it adds one passing
record before each gate run and nothing else; unregistered, the fixture
does not load.

## Where each spec section lives

### correlate.md

| Section | File |
|---|---|
| Reports (checks, order of rejects) | `src/correlate/correlate.erl`; the key tables `src/model/model_report.erl` |
| Reports, Time quality | `src/model/model_report.erl` (steps 1, 2), `src/correlate/correlate_track.erl` (step 3) |
| Frame | `src/model/model_frame.erl` |
| Track estimate | `src/model/model_kalman.erl`; Measurement variance `src/correlate/correlate_track.erl` |
| Two-model filter | `src/model/model_imm.erl` |
| Restart | `src/correlate/correlate_track.erl` |
| Tests | `src/correlate/correlate_test_kinds.erl`; distance and d² `src/correlate/correlate_gating.erl` |
| Association | `src/correlate/correlate_confirm.erl` |
| Events, Trace | `src/trace/trace_correlate.erl` |
| Snapshot | `src/snapshot/snapshot_correlate.erl` |
| Pack | `src/correlate/correlate_pack.erl`; text `src/io/io_pack.erl`; methods `src/correlate/correlate_methods.erl` |
| Floats | every module: formulas in the order written, no contraction (BEAM floats are binary64) |

### correlate-assign.md

| Section | File |
|---|---|
| Shared with correlate.md | `src/correlate/correlate.erl` |
| Memberships | `src/assign/assign_membership.erl` |
| Assignment of one source | `src/assign/assign_cost.erl` |
| Sensor bias | `src/assign/assign_bias.erl` |
| Ranking | `src/assign/assign_rank.erl` |
| Window | `src/assign/assign.erl` |
| Events, Trace | `src/trace/trace_assign.erl` |
| Snapshot | `src/snapshot/snapshot_assign.erl` |
| Pack | `src/assign/assign.erl` (its directives and ranges) |

### filter.md

| Section | File |
|---|---|
| Reports | `src/filter/filter.erl` with `src/model/model_report.erl` |
| Geometry | `src/filter/filter_geometry.erl` |
| Conditions | `src/filter/filter_conditions.erl` |
| Rules, Tick | `src/filter/filter.erl` |
| Events, Trace | `src/trace/trace_filter.erl` |
| Snapshot | `src/snapshot/snapshot_filter.erl` |
| Pack | `src/filter/filter_pack.erl` |

### fuse.md

| Section | File |
|---|---|
| Shared with correlate.md | `src/model/model_frame.erl`, `src/model/model_kalman.erl` |
| Reports, Groups, On each tick, Fused event | `src/fuse/fuse.erl` |
| Kinematics (five methods), Fused event height | `src/fuse/fuse_kinematics.erl` |
| Attributes | `src/fuse/fuse_attributes.erl` |
| Events, Trace | `src/trace/trace_fuse.erl` |
| Snapshot | `src/snapshot/snapshot_fuse.erl` |
| Pack | `src/fuse/fuse_pack.erl` |

### quality.md

| Section | File |
|---|---|
| Reports, Order, Window, Tick, Ingest | `src/quality/quality.erl` |
| Reports, Time quality | `src/model/model_report.erl` (`time_keys/2`) |
| Frame and filter | `src/model/model_frame.erl`, `src/model/model_kalman.erl` |
| Input clock, Samples | `src/quality/quality_samples.erl` |
| Entity measures, Source measures | `src/quality/quality_measures.erl` |
| Rules, Forwarding | `src/quality/quality_rules.erl` |
| Events, Trace | `src/trace/trace_quality.erl` |
| Snapshot | `src/snapshot/snapshot_quality.erl` |
| Pack | `src/quality/quality_pack.erl` (time_default from `src/correlate/correlate_pack.erl`) |

### vector-format.md and the runner

| Section | File |
|---|---|
| Scenario vectors, What the engine checks, Load vectors | `src/io/io_vectors.erl`; per function `src/io/correlator_vectors.erl`, `filter_vectors.erl`, `fuse_vectors.erl`, `quality_vectors.erl` |
| The function table and entry point shape | `src/io/io_engine.erl` |
| tools/perf "Runner contract" | `src/io/io_runner.erl`, `runner/build`, `runner/run` |

## Build

Requires OTP 27 (`erl`, `erlc`).

```
engines/erlang/build.sh
```

Compiles `src/*/*.erl` into `engines/erlang/ebin/`.

## Run the vectors

```
engines/erlang/run_tests
```

Builds, then runs the four vector runners: each reads only its own
function's `packs/<function>-*/vectors/` and `spec/<function>-load-vectors/`,
runs every scenario vector (each step's events and trace, then the final
snapshot) and every load vector with the structural comparison of
`spec/vector-format.md`, prints `PASS` or `FAIL` per vector (with the path
of the first mismatch) and a summary line, and exits non-zero if any vector
fails. Then it runs the unit, property and fuzz tests (`test/`).

## Runner

`runner/build` builds; `runner/run --function <f> --pack <dir> --steps <file>
[--events <file>] [--trace]` runs, as `tools/perf/README.md` "Runner
contract" states.

## Tests

`run_tests` runs every module of `test/` named `*_tests` with EUnit (OTP's
own; no third-party package):

| Module | Tests |
|---|---|
| `model_tests`, `correlate_unit_tests`, `assign_unit_tests`, `filter_unit_tests`, `fuse_unit_tests`, `quality_unit_tests`, `io_tests` | unit tests per module, including the runner and the vector comparison |
| `property_tests` | determinism; order independence (a report's key order, a pack's non-repeating lines); a state stored mid-run and restored continues with the same output |
| `fuzz_tests` | the JSON reader of a steps file, each pack.def parser, each function's ingest: a seeded generator in the test, `GOAT_FUZZ_ITERATIONS` inputs per target (1500 by default) |
| `registration_tests` | the no-op test kind (Extension points) |

Restore: the state is a value, so storing it (`term_to_binary`) and
restoring it continues identically; the engine has no restore from
`snapshot()`, whose JSON does not hold the whole state (correlate's snapshot
holds no last report, for one).

## Coverage

```
engines/erlang/coverage [FLOOR]
```

Line coverage with OTP's own `cover` module (the `tools` application) over
every module of `src/`, while the four vector runners and the tests run;
prints the percentage per module, the lines not covered and the total, and
exits non-zero below FLOOR. CI runs it with the floor 98.2 %, the
pre-refactor baseline (see `REFACTOR.md`).

Open points and any vector that disagrees with the specification are in
`DISAGREEMENTS.md`.

## Note on OTP 27.3

OTP 27.3.4.6's compiler drops the code that follows a `lists:mapfoldl/3` call
whose result is then matched in a `case`, returning the `mapfoldl` result
directly. The engine uses explicit recursion in those places instead.
