# goat-processors, C++ engine

Four functions: correlate, filter, fuse and quality. C++17, standard library
only, with its own small JSON reader. Written from the specifications and the
vectors:

| Function | Specification |
|---|---|
| correlate | `spec/correlate.md` 0.8 (method `confirm`, the two-model filter, the filter restart, time quality) and `spec/correlate-assign.md` 0.6 (method `assign`: window, margin, sensor bias, time offset) |
| filter | `spec/filter.md` 0.1 |
| fuse | `spec/fuse.md` 0.2 |
| quality | `spec/quality.md` 0.2 (with time quality per source) |

Where a specification leaves room for more than one reading, the reading this
engine takes is in `DISAGREEMENTS.md`.

## Layout

One directory per module, the same module names in every engine: `model`,
`filter`, `correlate`, `assign`, `fuse`, `quality`, `trace`, `snapshot`, `io`.

| Module | Holds |
|---|---|
| `src/model/` | what every function reads: the JSON value, reports, the frame, the track estimate, the pack.def text helpers, `Output` |
| `src/filter/` | the filter function |
| `src/correlate/` | the correlate function: its pack, the shared engine and method `confirm` |
| `src/assign/` | correlate's method `assign` |
| `src/fuse/` | the fuse function |
| `src/quality/` | the quality function |
| `src/trace/` | the builders of events and trace records |
| `src/snapshot/` | the snapshot parts more than one function writes |
| `src/io/` | the one entry point (`io::Function`), file reading, the runner |
| `test/` | the vector runners and the unit, property and fuzz tests |
| `runner/` | `build` and `run`, the runner contract of `tools/perf/README.md` |

### Files

| Module | Files (`.hpp` declares, `.cpp` implements) |
|---|---|
| `model` | `json` (the JSON value, reader, writer; `JsonObject`), `report` (Reports, Time quality), `frame` (Frame), `estimate` (Track estimate), `pack_text` (PackError, pack.def reading, `time_default`), `output.hpp` (`Output`) |
| `filter` | `pack`, `geometry`, `conditions`, `engine` |
| `correlate` | `pack`, `engine` (ingest, tick, snapshot), `core` (what the methods share), `method.hpp` and `methods.cpp` (the method table), `confirm` (method confirm), `entity.hpp`, `motion.hpp` with `two_model.cpp` and `measurement.cpp` (the filter math), `tests` (the test kinds), `common.hpp` (internal helpers) |
| `assign` | `assign` (method assign: Window, Assignment of one source, Snapshot), `membership`, `ranking`, `cost`, `bias` |
| `fuse` | `pack`, `entity.hpp`, `kinematics`, `attributes`, `engine` |
| `quality` | `pack`, `entity.hpp`, `input_clock`, `measures` (the measure table), `rules` (Rules, Forwarding), `engine`, `common.hpp` (internal helpers) |
| `trace` | `trace.hpp` |
| `snapshot` | `snapshot` |
| `io` | `function` (the entry point by function name), `files`, `runner.cpp` (the runner's `main`) |

### Entry point

Every function has the same shape: load the pack, then ingest one report at a
time and tick, each returning its events and trace records (`corr::Output`),
and snapshot.

```cpp
#include "io/function.hpp"
auto fn = corr::io::load("correlate", "packs/correlate-gnn");   // throws corr::PackError
corr::Output out = fn->ingest(report);                         // out.events, out.trace
out = fn->tick(now_ms);
corr::Json state = fn->snapshot();
```

Each module also offers the same calls on its own types: `<fn>::load_pack(dir)`,
`<fn>::parse_pack(text)`, `<fn>::Engine e(pack)`, `e.ingest`, `e.tick`,
`e.snapshot`, with `<fn>` one of `correlate`, `filter`, `fuse`, `quality`.

## Where each section of the specifications lives

### spec/correlate.md

| Section | File |
|---|---|
| What the correlator does | `src/correlate/engine.cpp` (ingest, tick, snapshot), `src/correlate/core.cpp` (what the methods share), `src/correlate/method.hpp` and `src/correlate/methods.cpp` (the methods) |
| Reports (with Time quality) | `src/model/report.cpp`; its use in `src/correlate/engine.cpp` (`ingest`) |
| Frame | `src/model/frame.cpp` |
| Track estimate | `src/model/estimate.cpp` (steps 1 to 3); `src/correlate/measurement.cpp` (Measurement variance, prediction for comparison, d²) |
| Two-model filter | `src/correlate/two_model.cpp` |
| Restart | `src/correlate/core.cpp` (`restart_test`), with d² of `src/correlate/measurement.cpp` |
| Tests | `src/correlate/tests.cpp` (the kinds and `builtin_tests()`), `src/correlate/core.cpp` (`run_stage`) |
| Association | `src/correlate/confirm.cpp` (method confirm) |
| Events, Trace | `src/trace/trace.hpp` (builders); each record where its step is |
| Snapshot | `src/correlate/confirm.cpp`, `src/correlate/core.cpp` (`filter_json`), `src/snapshot/snapshot.cpp` |
| Pack | `src/correlate/pack.cpp`; each method's directives in `src/correlate/methods.cpp`; `time_default` in `src/model/pack_text.cpp` |
| Floats | `CMakeLists.txt` (`GOAT_FLOAT_FLAGS`) |

### spec/correlate-assign.md

| Section | File |
|---|---|
| Memberships | `src/assign/membership.cpp` |
| Assignment of one source | `src/assign/assign.cpp` (`rank_source`, `apply_assignment`), `src/assign/cost.cpp` (Fused estimate, Cost) |
| Sensor bias (with Time offset) | `src/assign/bias.cpp` |
| Ranking | `src/assign/ranking.cpp` |
| Window | `src/assign/assign.cpp` (`AssignMethod::tick`) |
| Events, Trace | `src/assign/assign.cpp`, `src/assign/membership.cpp` |
| Snapshot | `src/assign/assign.cpp` (`AssignMethod::snapshot`) |
| Pack | `src/correlate/pack.cpp` |

### spec/filter.md

| Section | File |
|---|---|
| What the filter does | `src/filter/engine.cpp` |
| Reports | `src/model/report.cpp` |
| Geometry | `src/filter/geometry.cpp` |
| Conditions | `src/filter/conditions.cpp` |
| Rules, Tick, Events, Trace, Snapshot | `src/filter/engine.cpp` |
| Pack | `src/filter/pack.cpp` |

### spec/fuse.md

| Section | File |
|---|---|
| What fuse does, Reports, Groups, On each tick, Fused event | `src/fuse/engine.cpp` |
| Shared with correlate.md | `src/model/frame.cpp`, `src/model/estimate.cpp`, `src/model/report.cpp` |
| Kinematics (the five methods) | `src/fuse/kinematics.cpp` |
| Attributes (the five rules) | `src/fuse/attributes.cpp` |
| Events, Trace, Snapshot | `src/fuse/engine.cpp`, `src/fuse/kinematics.cpp`, `src/fuse/attributes.cpp` |
| Pack | `src/fuse/pack.cpp` |

### spec/quality.md

| Section | File |
|---|---|
| What quality does, Reports, Order, Samples, Window, Tick, Ingest, Snapshot | `src/quality/engine.cpp` |
| Reports, Time quality | `src/model/report.cpp` (steps 1 and 2); step 3 in `src/quality/engine.cpp` |
| Frame and filter | `src/model/frame.cpp`, `src/model/estimate.cpp` |
| Input clock | `src/quality/input_clock.cpp` |
| Samples | `src/quality/engine.cpp` (taken), `src/quality/measures.cpp` (`window_samples`) |
| Entity measures, Source measures | `src/quality/measures.cpp` (the table `measures()`) |
| Rules, Forwarding | `src/quality/rules.cpp` |
| Pack | `src/quality/pack.cpp` |

### spec/vector-format.md

| Section | File |
|---|---|
| What the engine checks | `test/vector_support.hpp`, `test/run_vectors.cpp` |

## Extending: one registration point per kind

| Kind | Where | Adding one |
|---|---|---|
| a correlate method | `methods()` in `src/correlate/methods.cpp` | a class deriving from `correlate::Method` (`src/correlate/method.hpp`) and one row: name, required and refused directives, factory |
| a correlate test | `builtin_tests()` in `src/correlate/tests.cpp` | one `TestRegistry::add`: name, parameters, a pure function of the pair |
| a quality measure | `measures()` in `src/quality/measures.cpp` | one row: name, a pure function of the window samples, the source aggregate |

`test/test_extension.cpp` proves the test registration with a `noop` kind
registered only there, on the test-only fixture pack
`test/fixtures/correlate-noop/` with its own vector.

## Build and run the vectors

From the repository root:

```sh
cmake -S engines/cpp -B build/cpp && cmake --build build/cpp && ctest --test-dir build/cpp --output-on-failure
```

The ctest tests `vectors`, `filter_vectors`, `fuse_vectors` and
`quality_vectors` run `run_vectors`, `run_filter_vectors`,
`run_fuse_vectors` and `run_quality_vectors` with the repository root: every
scenario vector under `packs/<function>-*/vectors/` (each step's events and
trace, then the final snapshot) and every load vector under
`spec/<function>-load-vectors/`. Each prints `PASS` or `FAIL` per vector, and
for a failure the path of the first mismatch, for example
`steps[1].trace[0].value: number differs (...)`.

## Tests and coverage

`ctest` runs, besides the four vector runners, `unit_tests <module>` for
each module (`test/unit_main.cpp`, cases in `test/test_*.cpp`, harness
`test/check.hpp`):

| ctest | File | Covers |
|---|---|---|
| `unit_model` | `test/test_model.cpp` | JSON reader and writer, reports, frame, track estimate, pack.def text |
| `unit_filter` | `test/test_filter.cpp` | geometry, every condition row, pack errors, the engine |
| `unit_correlate` | `test/test_correlate.cpp` | one- and two-model math, measurement variance, d², every test kind, the registries, pack errors, both methods |
| `unit_assign` | `test/test_assign.cpp` | ranking (order, ties, forbidden entries, the count), memberships, fused estimate and cost, sensor bias and time offset |
| `unit_fuse` | `test/test_fuse.cpp` | pack, the five kinematics methods, the five attribute rules, the engine |
| `unit_quality` | `test/test_quality.cpp` | the measure table, entity and source measures, input clock, rule steps, forwarding, pack errors, the engine |
| `unit_io` | `test/test_io.cpp` | the entry point for every function, file reading, the trace and snapshot builders |
| `unit_extension` | `test/test_extension.cpp` | the `noop` test kind (README "Extending") |
| `unit_property` | `test/test_properties.cpp` | determinism on every vector and on seeded random scenarios; order independence of report keys, of a filter pack's directives against its rules, and of reports between ticks for method assign and fuse |
| `unit_fuzz` | `test/test_fuzz.cpp` | the JSON reader and the four pack.def parsers, seeded mutations of every vector and pack, fixed case counts |

This engine does not restore a snapshot (no specification defines
restoring), so there is no snapshot-then-restore test.

Line coverage uses gcc's own support (`--coverage`, read with `gcov`), no
third-party package:

```sh
cmake -S engines/cpp -B build/cpp-cov -DGOAT_COVERAGE=ON && cmake --build build/cpp-cov
ctest --test-dir build/cpp-cov && python3 -I engines/cpp/coverage.py build/cpp-cov --floor 96.7
```

`coverage.py` merges gcov's JSON of every object over `src/` and fails below
the floor. CI (`.github/workflows/conformance.yml`, job `cpp`) runs it.

## Runner

`runner/build` builds `build/cpp-runner/goat_runner` (Release);
`runner/run` executes it with the arguments of `tools/perf/README.md`
"Runner contract":

```sh
engines/cpp/runner/build
engines/cpp/runner/run --function correlate --pack packs/correlate-gnn \
    --steps packs/correlate-gnn/vectors/01-two-sources-one-object.json --events out.jsonl --trace
```
