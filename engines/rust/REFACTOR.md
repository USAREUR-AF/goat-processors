# Rust engine refactor (round "refactor", 2026-11-20)

What changed in `engines/rust` in this round, and how each row of the round
brief's "What done means" table is met. Output did not change by one byte
(last section).

Commits, in order, each signed, each passing `cargo test` and the
byte-identical check:

| Commit | Step |
|---|---|
| `refactor(rust): command-line runner` | 1. the runner (`runner/build`, `runner/run`) |
| `refactor(rust): one module layout` | 2. the layout and the `Function` entry point |
| `refactor(rust): pure functions for the math` | 3. pure functions |
| `refactor(rust): one registration point per extension kind` | 4. registration points and the no-op test kind |
| `test(rust): unit, property and fuzz tests; ...` | 5. tests and the coverage floor in CI |
| `perf(rust): exact branch-and-bound ranking of assignments` | 6. hot spot 1 |
| `perf(rust): JSON object keys without allocation; ...` | 6. hot spots 2 and 3 |

## Layout

```
src/
  lib.rs            module map
  function.rs       Function: NAME, parse_pack, load_pack, new, ingest, tick, snapshot
  model/            json (Json, Key, Map, reader), report, frame, track, two_model, pack (shared values)
  correlate/        mod (the engine both methods share), entity, restart, pair_tests,
                    method (BUILTIN_METHODS), registry, pack, confirm (the confirm method)
  assign/           membership, cost, ranking, bias, window, snapshot (correlate-assign.md)
  filter/           mod, conditions, geometry, pack
  fuse/             mod, report, kinematics, attributes, snapshot, pack
  quality/          mod, samples, measures (MEASURES), rules, forwarding, snapshot, pack
  trace.rs          StepResult, the shared trace record and event builders
  snapshot.rs       the JSON forms every snapshot shares
  io/               steps file, events file, the runner contract
  bin/runner.rs     the command-line runner
```

Every function has one entry-point shape, the trait `Function`: load the
pack, `ingest` one report, `tick`, read the events and trace records out of
each `StepResult`, `snapshot()`. The runner (`src/io`) and the vector tests
(`tests/common`) drive all four functions through it. `README.md` maps every
section of every spec to its file.

The math is pure functions of their inputs: the track estimate
(`model/track.rs`: prediction, updates, velocity, measurement variance,
`d²`), the two-model filter, an entity's first and later filter and the
restart test (`correlate/entity.rs`, `correlate/restart.rs`), every pair test
(`PairTest::evaluate` on a `Pair`), the bias frame move and pair update, the
fused estimate and the cost (`assign/bias.rs`, `assign/cost.rs`), the ranking
(`assign/ranking.rs`), a quality rule's evaluation step, `nis`, `speed_err`,
the input clock and the measures (`quality/`), the fuse kinematics and
attribute rules. State lives only in each `Engine` and is read out by
`snapshot()`; there are no globals (the registries are constant tables).

Left as they were, as the brief asks (correlate 1.0 replaces them): the
`confirm` method's pipeline (`correlate/confirm.rs`, moved unchanged and
called through `BUILTIN_METHODS`), the `window` and `same` tests (moved
unchanged into `PairTest` kinds), `output priority|latest` and fixed
staleness.

## The registration points

| Kind | Where | Adding one |
|---|---|---|
| correlate test | `BUILTIN_TESTS`, `src/correlate/pair_tests.rs` | one `TestKind` entry (name, parameters, builder of a `PairTest`); from outside the crate `Registry::register_test` and `parse_pack_with` |
| correlate method | `BUILTIN_METHODS`, `src/correlate/method.rs` | one `MethodKind` entry (name, refused directives, pack check, three hooks) |
| quality measure | `MEASURES`, `src/quality/measures.rs` | one `Measure` entry (name, entity function over the window, source aggregate) |

The proof is `tests/registry.rs`. It registers a no-op test kind, one
`TestKind` value that exists only in that test, and loads the test-only
fixture pack `tests/fixtures/correlate-noop/pack.def` (`packs/correlate-gnn`
plus `gate noop` and `confirm noop`; not under `packs/`, not in the spec). The
spec's registry refuses the pack (unknown test). With the kind registered,
every `correlate-gnn` vector gives the same events and snapshot, and the trace
gains only passing `noop` records. Every correlate vector also passes with
packs parsed by the extended registry, so the kind is invisible to every
existing vector.

## Tests and coverage

`cd engines/rust && cargo test` runs 110 tests (11 test binaries):

| Kind | Where |
|---|---|
| the conformance vectors (scenario, load, shipped packs) of the four functions | `tests/vectors.rs`, `filter_vectors.rs`, `fuse_vectors.rs`, `quality_vectors.rs` |
| unit tests, every module | `#[cfg(test)] mod tests` in each file of `src/` |
| registration point | `tests/registry.rs` |
| properties | `tests/properties.rs`: determinism on every scenario vector and on generated report streams for every shipped pack; order independence where the specs say order does not matter (the key order of a report, comment and blank lines in `pack.def`, filter directives against the rules, `time_default` lines of different sources); snapshot. `src/assign/ranking.rs`: the total does not depend on the arrangement of the values, and the ranked assignments equal the first `k` of a full enumeration |
| fuzzing | `tests/fuzz.rs`: the JSON reader (mutated corpus and generated values: no panic, print and read back the same), the four `pack.def` readers (mutated packs and load vectors: no panic, deterministic), and the four engines on malformed reports (no panic). Seeded; each target stops at `GOAT_FUZZ_CASES` (4000) cases or `GOAT_FUZZ_SECONDS` (5 s) |
| the runner binary | `tests/runner_cli.rs`, `src/io` |

**Restore.** The engines do not support restore: a snapshot is never read
back. The snapshot property tested instead is the one restore would rest on:
taking a snapshot after every step changes no output, and a copy of an engine
(`Clone`) taken half way continues exactly as the original.

**Fuzzing found three limits** on extreme values, all present before the
refactor and unchanged by it (changing them would change output). They are in
`DISAGREEMENTS.md`, "Limits found by fuzzing", for proc-coord: `wrap180` never
ends for an enormous or infinite longitude; millisecond integers near the
64-bit limits overflow; an infinite `ce` makes a NaN cost that the assignment
sort cannot order. The engine fuzz targets keep numbers within 1e6.

**Coverage.** Measured with the toolchain's own support: rustc
`-C instrument-coverage`, with `llvm-profdata` and `llvm-cov` from the rustup
component `llvm-tools` (no third-party crate), by `coverage.sh`. Line
coverage of `src/` under `cargo test`:

| | Line coverage |
|---|---|
| baseline: the tree before the refactor (runner commit), same script | 94.01 % |
| after steps 2 to 4, before the new tests | 93.81 % |
| final (after the last commit) | 99.05 % |
| floor, `max(baseline, 80 %)` | 94.01 % |

CI enforces the floor in the rust job of `.github/workflows/conformance.yml`
(the only job changed): `rustup component add llvm-tools`, then
`./coverage.sh 94.01`, which exits 1 below it.

## Hot spots

**How it was profiled.** `perf` is not allowed on this machine
(`kernel.perf_event_paranoid` is 4), ptrace is restricted (no gdb or
eu-stack sampling) and valgrind is not installed. The profile therefore comes
from the toolchain itself: the runner built with `-C instrument-coverage` in
the release profile, run on the large scenario (`perf.py generate --size
large`, every pack the harness names), gives every function's and region's
execution count (`llvm-cov export`); phase timers in a scratch copy of the
crate (never committed) attribute time within a function. The machine was
shared with the other engines' sessions (load average 30 to 115), so wall
times vary by up to 2x between runs; the before and after numbers below are
user CPU seconds of the whole runner process (`/usr/bin/time %U`, reading and
parsing the steps file included), median of 5 runs (3 for the slow one),
which varied by under 10 %.

| # | Hot spot | Profile | Fix |
|---|---|---|---|
| 1 | `assign::ranking::ranked_assignments` (correlate-assign-time) | 32.5 million assignments enumerated and 1.15 billion total comparisons: almost all of that run | Exact branch and bound: entities in key order, cheapest choice first, the best `k` kept by (total, choice vector), a partial assignment dropped only when its lower bound exceeds the `k`-th total by more than float rounding can account for. Same assignments, totals and order; checked against a full enumeration on random entries |
| 2 | JSON objects (every function): `json::obj` and object copies | the most-called functions in every function's profile (`obj` 7.9 million calls on correlate-assign-time, 1.5 million on filter-thin); a `String` per key per trace record and event, and per key of every copied report | `json::Key`: a literal for keys the engine writes, a shared `Arc<str>` for keys it reads; the reader keeps report and step keys as literals and borrows strings without escapes |
| 3 | quality's per-tick entity measures | the largest phase of quality's tick (about half of it); 2.1 million sample-to-JSON conversions and 3.2 million comparisons for `lateness_max/min` and `time_error_max` | the samples are compared as they are and the means are added in place. What is left is the recomputation of every measure over each entity's 60 s window at every tick, which is what the spec defines; an incremental (sliding) sum would round differently when a record leaves the window, so it would change output, and it is not done |

User CPU seconds, large scenario, before (the runner of commit 1, the engine
as it was) and after:

| Pack | Before | After | Change |
|---|---|---|---|
| correlate-assign-time | 18.22 | 1.50 | -92 % |
| correlate-gnn-imm | 0.28 | 0.21 | -25 % |
| filter-thin | 0.36 | 0.27 | -25 % |
| fuse-independent | 0.23 | 0.19 | -17 % |
| quality-time | 0.75 | 0.57 | -24 % |

`python3 -I tools/perf/perf.py baseline --engines rust` before the first
change and after the last, on this machine (reports per second, median):

| Command | Before | After |
|---|---|---|
| correlate vectors (`vectors`) | 4,009 (2,087 to 7,859) | 2,251 (1,455 to 3,305) |
| filter vectors | 4,021 (1,400 to 6,387) | 1,822 (1,216 to 4,309) |
| fuse vectors | 2,848 (851 to 5,816) | 2,092 (791 to 7,100) |
| quality vectors | 2,424 (1,778 to 8,143) | 2,702 (1,880 to 5,492) |
| correlate, large (2 packs) | 431 (364 to 447) | 1,031 (933 to 1,198) |
| filter, large | 4,690 (4,367 to 6,121) | 4,542 (2,699 to 7,152) |
| fuse, large | 8,864 (8,481 to 10,410) | 7,742 (4,216 to 12,242) |
| quality, large | 2,948 (2,475 to 3,214) | 3,668 (1,820 to 4,226) |

The after run also fills the runner rows (engine calls only, wall): 21,825
reports/s on correlate-gnn-imm, 3,418 on correlate-assign-time, 28,021 on
filter-thin, 24,447 on fuse-independent, 6,382 on quality-time. The before
run had no rust runner.

These are wall-clock medians, and on this machine they do not measure the
engine: the machine was shared with six other engine sessions (load average
30 to 115 on 16 cores), so a command waited for a CPU most of the time (its
wall time was about three times its CPU time) and one median swings by 2x
between runs (the ranges overlap in every row). The lower medians of four
rows (filter, fuse and correlate vectors; filter and fuse large) are that
noise, not a slowdown. Each pair was measured again, interleaved (before,
after, after, before, ...) on the very binaries the harness built and timed
(its `tree` and `tree-large` work directories), by the CPU time the command
used (`getrusage` of the child, user plus system):

| Command (as the harness runs it) | Runs | CPU before, ms | CPU after, ms | Change |
|---|---|---|---|---|
| `vectors` (correlate) | 31 | 25.9 | 23.8 | -8 % |
| `filter_vectors` | 31 | 7.4 | 7.2 | -3 % |
| `fuse_vectors` | 31 | 5.0 | 4.8 | -4 % |
| `quality_vectors` | 31 | 17.0 | 16.0 | -6 % |
| `vectors`, large (both correlate packs) | 3 | 24,176 | 7,463 | -69 % |
| `filter_vectors`, large | 5 | 1,437 | 1,284 | -11 % |
| `fuse_vectors`, large | 5 | 689 | 624 | -9 % |
| `quality_vectors`, large | 5 | 2,358 | 2,077 | -12 % |

And the runner, before (the runner of commit 1 on the engine as it was)
against after, interleaved, large scenario, medians (7 runs; 3 for
correlate-assign-time); reports per second over the engine calls only:

| Pack | Before | After |
|---|---|---|
| correlate-gnn-imm | 17,590 | 21,688 |
| correlate-assign-time | 304 | 3,191 |
| filter-thin | 14,515 | 16,363 |
| fuse-independent | 24,278 | 33,022 |
| quality-time | 7,643 | 9,275 |

No function got slower: every command uses less CPU after the refactor than
before. The harness's page (`docs/performance.md`) is left as proc-bench
generates it; this round does not commit it.

## Byte-identical check

Before any change (commit 1, the runner alone) the runner recorded every
output into a directory outside the repository; after every later step the
current runner recorded them again and every file was compared with `cmp`:

| Files | What |
|---|---|
| 121 | every scenario vector of every function (`packs/*/vectors/*.json`), run with its own pack, `--events` and `--trace`: each step's events and trace and the final snapshot |
| 218 | every load vector (`spec/*-load-vectors/*.json`): the runner's exit status with the vector's `pack_def` as the pack |
| 40 | the events file (the snapshot) of each load vector that loads |
| 5 | the large scenario of every pack the harness names (`correlate-gnn-imm`, `correlate-assign-time`, `filter-thin`, `fuse-independent`, `quality-time`), 230 MB |

384 files; after the last commit all 384 are byte-identical. The golden events
files also match every vector's expectations (events, trace and snapshot, as
`spec/vector-format.md` compares them).
