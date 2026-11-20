# The zig engine refactor

The round brief is `~/inbox/proc/round-refactor.md`. This engine was
restructured, given registration points, tests, a coverage floor and a runner,
and its three largest hot spots were worked, without changing one byte of its
output. Commits, in order:

| Commit | Step |
|---|---|
| `feat(zig): runner per the tools/perf runner contract` | 1, the runner; then the golden output was recorded |
| `refactor(zig): one module layout and one entry point` | 2 |
| `refactor(zig): pure functions for the math` | 3 |
| `refactor(zig): one registration point per extension kind` | 4 |
| `test(zig): unit, property and fuzz tests; line coverage floor in CI` | 5 |
| `perf(zig): assign ranking keeps the best k while enumerating` | 6, hot spot 1 |
| `perf(zig): copy a report's map without rehashing its keys` | 6, hot spot 2 |
| `perf(zig): build records by appending entries with compile-time hashes` | 6, hot spot 2 |
| `test(zig): unit tests out of the vector test binaries` | 6, so the timed vector commands run vectors only |
| `perf(zig): one arena for the vector tests; window statistics once per entity` | 6, no function slower |

## Layout

One directory of `src/` per module, the names every engine uses. The full map
from each spec section to its file is in `README.md`.

| Module | Files |
|---|---|
| model | `frame.zig` (Frame), `kalman.zig` (one filter: first report, predict, update, the velocity measurement), `imm.zig` (two-model filter), `report.zig` (the Reports key readers, required keys, time quality, report copy), `params.zig` (pack parameter types more than one function uses) |
| correlate | `engine.zig` (`ingest`, `tick`, `snapshot`), `estimate.zig` (measurement variance, restart), `entity.zig`, `pack.zig`, `tests.zig` (the test registry), `methods.zig` (the method registry), `confirm.zig` (method confirm, moved unchanged) |
| assign | `assign.zig` (Assignment of one source, Window, Events), `ranking.zig`, `membership.zig`, `bias.zig` |
| filter | `engine.zig`, `conditions.zig`, `geo.zig`, `pack.zig` |
| fuse | `engine.zig`, `kinematics.zig`, `attributes.zig`, `pack.zig` |
| quality | `engine.zig`, `measures.zig` (the measure registry), `rules.zig`, `samples.zig`, `pack.zig` |
| trace | `record.zig`: `Result` (events, then trace records) and the record builders |
| snapshot | `common.zig` and one file per function (`correlate.zig`, `assign.zig`, `filter.zig`, `fuse.zig`, `quality.zig`) |
| io | `runner.zig` (the runner), `json_read.zig`, `json_write.zig`, `steps.zig`, `replay.zig`, `vectors.zig`, `vector_files.zig`, `compare.zig` |

**One entry point.** `src/api.zig`: every function module has `Pack`,
`load_pack(alloc, dir)`, `parse(alloc, text)`, and `Engine` with
`create(backing, pack)`, `ingest(report)`, `tick(now_ms)`, `snapshot()`,
`destroy()`; `ingest` and `tick` return a `trace.record.Result` (events, then
trace records). `api.Module(f)` checks that shape at compile time. The runner,
the vector tests, the property tests and the fuzzer all go through it.

**Pure functions, state in the engine.** The math is pure functions: the
filter (`Filter.first`, `predict`, `update`, `velocityOf`), the two-model
filter, the measurement variance and restart `d²` (`correlate/estimate.zig`),
the tests' `run`, the assign cost and fused estimate, the ranking, the bias
update (`bias.update` returns the new pair state, the caller stores it), the
fuse kinematics and attribute rules, the filter conditions (they read the
entities' state, change nothing), the quality samples, measures and rule
step. State lives only in each `Engine` (and, for a correlate method, in the
method state the engine holds); `snapshot()` writes it. No engine file has a
global variable. (`src/profile_main.zig`, the profiler, has the sample buffer
a signal handler writes; it is not engine code.)

**Left alone**, as the brief says (correlate 1.0 replaces them): the confirm
method's pipeline (`correlate/confirm.zig`: gate, confirm and hold stages,
`confirm_count`, the hold failures, fixed staleness, the `priority`/`latest`
output), the `window` and `same` tests. They were moved and reached through
the new entry point and registries; their logic is unchanged.

## The registration point

| Extension | One place |
|---|---|
| a correlate method | one entry in `table` of `src/correlate/methods.zig`: its name, the directives it requires and refuses, its ranges, its group-name prefix, its state, and its hooks (reject before out-of-order, at a restart, after an accepted report, B's prediction for a comparison, tick, snapshot). The engine has no `if method == ...` left |
| a correlate test | one entry in `builtin` of `src/correlate/tests.zig`: a name, its parameters (number or text, by name) and a pure `run`. Pack lines are parsed against a `Registry` |
| a quality measure | one entry in `table` of `src/quality/measures.zig`: name, source-only or not, its entity measure, its source aggregate. The `Measure` enum, the order of the `measures` object and the names a rule may use come from the table |

**The proof.** `src/correlate/noop_test.zig` registers a no-op test kind, in
test code only: `tests.Registry{ .kinds = &(tests.builtin ++ [_]tests.Kind{noop}) }`,
used by `pack.parseWith`. Its fixture pack and vector are in
`src/correlate/testdata/noop/` (not under `packs/`, not in the spec), behind
the pack lines `gate noop` and `hold noop`. Three tests: the pack does not
load without the registration (so no existing pack or vector can reach the
kind: it is invisible to them); the fixture vector's events, trace and
snapshot; and the same steps with and without the no-op lines give the same
events and snapshot, and the same trace less the no-op records.

## Tests and coverage

`cd engines/zig && zig build test` runs:

| Root | Tests |
|---|---|
| the four vector roots | every load vector and scenario vector (73 + 56 correlate, 50 + 27 filter, 33 + 16 fuse, 62 + 22 quality) |
| `src/unit_test.zig` | 53 unit tests: each file's `unit_tests` struct, every module of `src/`, the registries and the no-op kind |
| `src/property_test.zig` | determinism (every vector twice, the same bytes); order independence where the specs say order does not matter: a report's key order, `name=value` order on a pack line, a filter pack's other directives after its rules |
| `src/fuzz_test.zig` | seeded fuzzing (seed `0x60a7`): 3,000 mutated pack.def texts through the four parsers (each loads or gives a load error, the same both times), 1,500 mutated vector files through the JSON and steps readers, generated reports through the engine of every pack, twice, the same bytes. About 10 s of CPU in Debug |

**Snapshot then restore**: this engine has no restore operation (no spec
defines one), so that property is not tested.

The fuzzer found one thing: a report longitude far outside [-180, 180] makes
the Frame's "add or subtract 360" a loop as long as `|lon| / 360`, and 1e300
never ends. That is the spec's procedure as written; it is in
`DISAGREEMENTS.md` for proc-coord, and was not changed.

**Coverage.** Zig 0.13 has no coverage of its own (kcov would be a
third-party package), so `coverage/run.sh` measures line coverage with gdb and
objdump: a one-shot breakpoint on the first statement address of every line in
the DWARF line table, the Debug test binaries and the Debug runner (on one
vector per function) run under gdb, a line covered when its breakpoint was
hit. Test code is left out. CI: the zig job of
`.github/workflows/conformance.yml` (the only job changed) runs
`coverage/run.sh --check`, which fails below `coverage/floor`.

| | Lines covered | Coverage |
|---|---|---|
| Baseline: commit a2b8791 (the engine before the refactor, its vector tests and the runner) | 3,025 of 3,077 | 98.3 % |
| Floor: max(baseline, 80 %) | | 98.3 % |
| Measured now | 3,210 of 3,237 | 99.2 % |

## Hot spots

perf is not available on this machine (`perf_event_paranoid` 4), so
`profile/profile.sh` runs the runner under a small sampling profiler,
`src/profile_main.zig` (standard library only: a SIGPROF every millisecond of
CPU records the instruction pointer and the frame-pointer chain; addr2line
names the functions). Profiled on the large scenario through the runner, every
pack the harness names. The machine was shared and heavily loaded (load
average up to 57 on 16 cores), so wall times swing; the before and after
figures below are CPU seconds (user + system) of the runner on the large
scenario, median of 3 to 5 runs, the pre-refactor runner (commit a2b8791,
ReleaseFast) against this one.

**1. Assign ranking** (`assign/ranking.zig`). On `correlate-assign-time` about
75 % of the CPU: the brute-force ranking stored every assignment (a copy of
its choice vector, and a sort of its entries to add them in ascending order),
then sorted them all, to keep the first `k`; nothing was freed, so the run
peaked at 9.8 GB. Fixed: the enumeration keeps only the best `k` in ranking
order (the order is strict and total, since two assignments differ in their
choice vectors; with a NaN total it falls back to the full sort), and keeps
the chosen entries sorted as it descends, inserting each after the values it
is not below, which is the order the stable sort gave. A randomized unit test
checks it against the full sort.

| correlate-assign-time | Before | After |
|---|---|---|
| CPU | 13.81 s | 2.72 s |
| Peak memory | 9.8 GB | 1.2 GB |

**2. Building JSON objects** (hash-map inserts and new hash indexes). On the
other packs the largest share of the engine's own time: copying each accepted
report re-inserted every key (a hash, a probe, and above eight keys a new
index cleared with memset), and every event and trace record was built by a
`put` per field. Fixed: the report copy clones the map's arrays and index and
copies keys and values in place (`model/report.zig`); `record.object` appends
the fields with their hashes computed at compile time and builds the index
only above eight entries (`trace/record.zig`). Then the quality measure
registry took its shared window statistics once per entity, not once per
measure.

| CPU, large scenario | Before | After |
|---|---|---|
| correlate-gnn-imm | 0.26 s | 0.25 s |
| filter-thin | 0.29 s | 0.27 s |
| fuse-independent | 0.25 s | 0.24 s |
| quality-time | 0.59 s | 0.52 s |

(These include reading and parsing the 4 MB steps file, hot spot 3.)

**3. Parsing the JSON input** (`std.json`), 14 to 32 % of the runner's CPU
outside assign (`json.dynamic.Value.jsonParse`, its scanner and its object
inserts), and most of each vector test's time. Not fixed, and why: it is the
standard library's parser, and the runner's time it takes is outside
`run_ns` (the harness's "engine calls only"). A faster parser of our own
would have to give the same `json.Value` as `std.json` on every input: which
numbers become integers, floats or number strings, the escapes and surrogate
pairs, which bytes are valid UTF-8, duplicate keys (the last value at the
first position). Getting one of those different is a behavior change on
some input no vector holds; it is a project of its own, with differential
fuzzing against `std.json`, not a refactor step. The read itself was fixed:
files of any size (the vector readers had a 16 MiB limit, `FileTooBig` on the
large scenario).

**Vector test commands** (what the harness times per function), CPU per run,
median of 3 sets of 40 runs, before against after: correlate 0.0248 to
0.0220 s, filter 0.0077 to 0.0065 s, fuse 0.0047 to 0.0040 s, quality 0.0177
to 0.0143 s.

**The harness** (`python3 -I tools/perf/perf.py baseline --engines zig`), run
before the first change (at the runner commit) and after the last, on this
machine. Wall time, so loaded by the other sessions on the machine; median
and range of the harness's repeats.

Vector commands, conformance vectors (all four functions' load and scenario vectors), reports per second and peak memory:

| Function | Before | After | Peak MB before | after |
|---|---|---|---|---|
| correlate | 3,168 (1,550 to 8,227) | 5,962 (3,402 to 13,704) | 7 | 3 |
| filter | 3,942 (1,326 to 6,248) | 8,148 (1,749 to 11,130) | 2 | 1 |
| fuse | 2,221 (675 to 4,186) | 4,073 (1,082 to 6,148) | 1 | 1 |
| quality | 1,956 (1,643 to 4,592) | 8,588 (2,379 to 11,572) | 6 | 2 |

Vector commands, large scenario:

| Function | Before | After | Peak MB after |
|---|---|---|---|
| correlate (2 packs) | fails (`FileTooBig`) | 3,206 (3,019 to 3,222) | 2,723 |
| filter | fails (`FileTooBig`) | 9,928 (9,760 to 10,959) | 602 |
| fuse | 9,316 (9,121 to 12,599), 345 MB | 20,465 (19,080 to 22,491) | 341 |
| quality | fails (`FileTooBig`) | 6,016 (5,831 to 6,022) | 1,130 |

Runner, engine calls only (`run_ns`), large scenario, reports per second; run and parse seconds; peak memory:

| Pack | Before | After | Run s | Parse s | Peak MB |
|---|---|---|---|---|---|
| correlate-gnn-imm | 23,302 (20,480 to 38,204) | 70,949 (67,993 to 80,641) | 0.80 to 0.26 | 0.33 to 0.13 | 232 to 212 |
| correlate-assign-time | 425 (387 to 505) | 3,950 (3,888 to 4,026) | 43.70 to 4.70 | 0.41 to 0.13 | 9,563 to 1,149 |
| filter-thin | 30,065 (17,047 to 36,411) | 63,898 (62,490 to 72,100) | 0.62 to 0.29 | 0.40 to 0.17 | 281 to 281 |
| fuse-independent | 14,070 (13,560 to 47,255) | 71,942 (69,176 to 73,939) | 1.32 to 0.26 | 0.31 to 0.13 | 218 to 214 |
| quality-time | 11,748 (5,336 to 16,467) | 25,933 (23,073 to 26,020) | 1.58 to 0.72 | 0.33 to 0.13 | 533 to 510 |

No function is slower. The machine was less loaded during the after-run, so part of every wall-time gain is load, not code; the CPU figures above isolate the code. The harness's `docs/performance.md` and `results.json` were restored after each run (they belong to proc-bench).

## Byte-identical check

After step 1 the runner recorded the golden output into
`/tmp/zigref/golden` (outside the repository): for each of the 121 scenario
vectors, run with `--pack` of its own pack and `--steps` the vector file,
`--events` and `--trace`; the large scenario (`perf.py generate --size large`)
for each of the five packs the harness names; and each of the 218 load
vectors (its `pack_def` written as a pack directory, run on an empty steps
file). That is 344 runs: 344 exit-status files and 166 events files (the 121
scenario vectors, the 5 large runs, and the 40 load vectors that load), 510
files. After every step the runner was rebuilt, every run repeated and every
file compared with `cmp`: **510 of 510 identical** each time (after steps 2,
3, 4 and 5, after the ranking and report-copy changes together, after the
record builder, after the move of the unit tests, after the last change, and
again with this file committed). The conformance vectors passed after
every step (`zig build test`).
