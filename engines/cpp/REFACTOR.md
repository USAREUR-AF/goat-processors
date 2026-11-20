# C++ engine refactor (round "refactor", 2026-11-20)

Branch `refactor/cpp`. Every step kept the conformance vectors passing and
the engine's output byte for byte (below, "Byte-identical check").

| Step | Commit |
|---|---|
| 1. Runner (`runner/build`, `runner/run`, tools/perf/README.md "Runner contract") | `644e8ac` |
| 2. Layout | `9597f00` |
| 3. Pure functions for the math | `66ba593` |
| 4. One registration point per extension kind | `f00d183` |
| 5. Tests, property tests, fuzzing, coverage floor | `a49acc7` |
| 6. Hot spots | `9d6f3f6` |

## Layout

One directory per module, the names every engine uses (README.md "Layout"
and "Where each section of the specifications lives", a file per section):

| Module | Holds |
|---|---|
| `src/model/` | JSON value (`JsonObject`: one sorted array per object), Reports, Frame, Track estimate, pack.def text helpers, `Output` |
| `src/filter/` | filter.md: pack, geometry, conditions, engine |
| `src/correlate/` | correlate.md: pack, engine, the shared `Core`, the method table, method `confirm`, the filter math (`motion.hpp`), the test kinds |
| `src/assign/` | correlate-assign.md: method `assign`, memberships, ranking, cost, sensor bias |
| `src/fuse/` | fuse.md: pack, kinematics, attributes, engine |
| `src/quality/` | quality.md: pack, input clock, measures, rules and forwarding, engine |
| `src/trace/`, `src/snapshot/` | builders of records and of snapshot parts |
| `src/io/` | `io::Function`: the one entry point (load the pack, ingest, tick, trace out, snapshot) for all four functions by name; file reading; the runner |

The math is pure functions (filter predict and update, two-model update,
measurement variance, d², fused estimate and cost, ranking, bias and time
offset, quality measures, rule steps, forwarding, filter geometry and
conditions, fuse kinematics and attributes). State lives only in the engine
objects (`correlate::Core` and its method, `filter::Engine`, `fuse::Engine`,
`quality::Engine`) and their `snapshot()`; there are no mutable globals (the
only statics are constant tables).

Left alone, as the round asks (correlate 1.0 replaces them): the confirm
method's pipeline (gate, confirm, `confirm_count`, hold and
`hold_failures`), the `window` and `same` tests, `output priority|latest` and
fixed staleness. They moved unchanged into `correlate/confirm.cpp`,
`correlate/tests.cpp` (as two kinds of the table) and `correlate/core.cpp`
(`is_stale`), and are called through the method table. The only edits in
them are mechanical: `std::move` of a finished event or record into the
output instead of a copy, and the new name of the d² helper.

## Registration points

| Kind | One place | Adding one |
|---|---|---|
| correlate method | `methods()`, `src/correlate/methods.cpp` | a `Method` subclass and one row (name, required and refused directives, factory) |
| correlate test | `builtin_tests()`, `src/correlate/tests.cpp` | one `TestRegistry::add` (name, parameters, pure function) |
| quality measure | `measures()`, `src/quality/measures.cpp` | one row (name, function of the window samples, source aggregate) |

Proof: `test/test_extension.cpp` registers a `noop` test kind in test code
only and runs the test-only fixture pack `test/fixtures/correlate-noop`
(packs/correlate-gnn plus `gate noop`) with its own vector
(`vectors/01-noop-passes.json`). It checks that the engine's own registry
refuses the pack (`unknown test: noop`), that the vector passes, and that
the noop gate changes nothing but its own trace records (same events, same
other records, same snapshot as packs/correlate-gnn). No pack, vector or
spec file of the program changed.

## Tests and coverage

`ctest`: the four vector runners, plus `unit_tests <module>` for model,
filter, correlate, assign, fuse, quality, io, extension, property, fuzz
(63 cases; README.md "Tests and coverage").

- Unit tests per module.
- Property tests: determinism (every scenario vector of every function, run
  twice; seeded random scenarios on 12 packs); order independence where the
  specs say order does not matter (report key order, filter directives
  against rules, reports of different entities between ticks for method
  assign and for fuse); the ranking against its definition, bit for bit, on
  400 seeded random matrices. Snapshot then restore: this engine does not
  restore a snapshot (no spec defines it), so there is no such test.
- Fuzzing: the JSON reader (6,000 mutations of every vector file, 3,000
  random values round-tripped, 3,000 random byte strings) and the four
  pack.def parsers (2,500 mutations each of every pack and load vector),
  seeded generator in `test/random.hpp`, fixed counts, about 1 s in Release.
- Coverage: gcc's own `--coverage` read with `gcov` (no third-party
  package), merged over `src/` by `coverage.py`.

| Line coverage of `engines/cpp/src` | |
|---|---|
| baseline (commit `644e8ac`, the vectors only) | 96.7 % (2679 of 2770 lines) |
| floor, max(baseline, 80 %) | 96.7 % |
| measured (final) | 98.5 % (3365 of 3417 lines) |

CI: the `cpp` job of `.github/workflows/conformance.yml` (the only job
changed) builds with `-DGOAT_COVERAGE=ON`, runs ctest and
`python3 -I engines/cpp/coverage.py ... --floor 96.7`.

## Hot spots

Profiled through the runner on the large scenario (an in-process SIGPROF
sampler linked into a profiling build of the runner; `perf` and `ptrace`
are not permitted on this machine). The three largest:

1. **Ranking of method assign** (correlate-assign-time: about 75 % of the
   run, and most of the 2.1 GB peak of the vector command). The brute force
   stored every assignment, each with a heap-allocated choice vector, then
   sorted them all. Fixed: keep the first k in a heap (Ranking order is a
   strict total order, so the result is the same), keep the chosen entries
   sorted down the search so a leaf's total needs no sort (the same float
   additions in the same order), and skip a subtree whose least possible sum
   exceeds the k-th total by more than 1e-9 of the magnitudes involved, far
   above the float error. Checked bit for bit against the definition on
   random matrices, and on the golden files.
2. **Allocation in JSON records** (filter, fuse, correlate-gnn-imm: about
   half of the run in malloc and free). A JSON object was a `std::map` (one
   node per key), and every event and trace record was deep-copied on
   `push`. Fixed: an object is one sorted array of members (same key order,
   so the same output), finished records and values are moved, and the
   reader appends string runs and converts numbers in place.
3. **Quality window samples** (quality-time: a third of the run in
   `entity_measures`). Each tick built vectors of full `Json` values for
   every entity's window. Fixed: a compact `Sample` (integer or binary64),
   with the same values and summation order.

Before and after, CPU seconds (user + sys) of the whole runner on the large
scenario, before = commit `644e8ac`, after = `9d6f3f6`, median of 3,
interleaved, same machine and hour:

| Hot spot | Run | Before | After |
|---|---|---|---|
| 1 | correlate-assign-time | 14.55 s | 1.69 s |
| 2 | filter-thin | 0.48 s | 0.36 s |
| 2 | fuse-independent | 0.38 s | 0.27 s |
| 2 | correlate-gnn-imm | 0.36 s | 0.29 s |
| 3 (with 2) | quality-time | 1.12 s | 0.62 s |

Peak memory of the runner: 105 to 113 MB before, 89 to 92 MB after; of the
correlate large vector command 2,142 MB before, 1,673 MB after.

### `perf.py baseline --engines cpp`

Run before the first change (`644e8ac`, finished 06:45), after the last
(`9d6f3f6`, finished 07:57), and once more on `644e8ac` right after that
(finished 08:15) so both sides saw the same load. The machine was shared: load
average 8 to 190 during these runs (`docs/performance.md` prints it), so
wall times vary by a factor of 2 to 3 between runs of the same binary.
Reports per second, medians:

| Function | Measure | Before (06:45) | Before (08:15) | After (07:57) |
|---|---|---|---|---|
| correlate | vectors | 4,619 | 3,800 | 3,967 |
| filter | vectors | 3,210 | 2,543 | 3,946 |
| fuse | vectors | 3,729 | 2,792 | 2,099 |
| quality | vectors | 1,874 | 2,306 | 2,695 |
| correlate | large (vector command) | 508 | 440 | 1,458 |
| filter | large (vector command) | 3,377 | 2,711 | 4,818 |
| fuse | large (vector command) | 6,586 | 8,432 | 10,675 |
| quality | large (vector command) | 1,920 | 1,207 | 2,027 |
| correlate | runner, correlate-gnn-imm | 25,952 | 20,203 | 26,599 |
| correlate | runner, correlate-assign-time | 490 | 365 | 2,331 |
| filter | runner, filter-thin | 11,083 | 21,678 | 26,983 |
| fuse | runner, fuse-independent | 30,232 | 33,878 | 58,802 |
| quality | runner, quality-time | 4,030 | 8,294 | 12,020 |

The conformance-vector commands run a few milliseconds each, and their
ranges overlap widely under this load (fuse: 921 to 5,978 before, 901 to
5,679 after). CPU time settles it: 5 blocks of 50 runs each, interleaved,
median CPU per run:

| Vector command | Before | After |
|---|---|---|
| `run_vectors` (correlate) | 26.8 ms | 23.8 ms |
| `run_filter_vectors` | 7.8 ms | 7.2 ms |
| `run_fuse_vectors` | 5.4 ms | 5.2 ms |
| `run_quality_vectors` | 18.0 ms | 16.0 ms |

No function got slower: every runner, every large-scenario command and every
vector command uses less CPU after than before.

## Byte-identical check

After step 1, the runner recorded the golden output outside the repository:
every scenario vector of every function (its own pack, `--events --trace`),
the large scenario (`perf.py generate --size large`) on the five packs the
harness names, and every load vector (its `pack_def` as a pack directory,
an empty steps file; exit status and message kept too). That is 344 runs and
510 files (344 status files, 166 events files). After every later step all
510 were reproduced and compared with `cmp`: **510 of 510 identical** after
steps 2, 3, 4, 5 and 6, and after every change within step 6.

One reading the spec leaves open was found and is in `DISAGREEMENTS.md` for
proc-coord, unchanged in behavior: a JSON number outside binary64 (`1e999`)
reads as infinity and is written as `inf`.
