# Erlang engine: the refactor

The round brief is `~/inbox/proc/round-refactor.md`. This page reports
what this engine did for each row of its "What done means" table, with the
numbers measured on this machine (16 cores, OTP 27.3.4.6).

## Behavior unchanged: byte-identical output

Before the first change, the runner (`runner/run`, commit 1) recorded every
output of the engine into a directory outside the repository:

| Files | What |
|---|---|
| 121 | every scenario vector of `packs/*/vectors/`, run with its own pack: the events file with `--trace` (each step's events and trace, then the snapshot) |
| 5 | the large scenario (`perf.py generate --size large`) of each pack the harness names: `correlate-gnn-imm`, `correlate-assign-time`, `filter-thin`, `fuse-independent`, `quality-time`, with `--trace` (135 MB for `correlate-assign-time`) |
| 4 | the result (loads or does not) of each of the 218 load vectors, one file per function |

After each step (layout, pure functions, tests, hot spots) every one of
the 130 files was recorded again and compared with `cmp`: **130 of 130
identical at every step**, and on the final tree. All 339 vectors pass
after every step.

One change does alter behavior, where no output existed before: a pack
number beyond binary64's range made three pack parsers raise instead of
returning a load error. It is its own commit (`fix(erlang)`) and is in
`DISAGREEMENTS.md` for proc-coord.

The benchmark (`tools/bench`) scores events; the events are byte-identical,
so its scores are too. It was not run separately for this engine.

## Layout

One directory per area, the same areas as every engine; `README.md` maps
every spec section to its file.

| Directory | Modules |
|---|---|
| `src/model/` | `model_report` (reports, time keys), `model_frame` (frame), `model_kalman` (track estimate), `model_imm` (two-model filter) |
| `src/correlate/` | `correlate` (entry point, reports, accepting a report), `correlate_methods` (method table and behaviour), `correlate_test_kinds` (tests table and runner), `correlate_gating`, `correlate_track` (measurement variance, restart), `correlate_pack`, `correlate_confirm` (the confirm method, moved unchanged in logic) |
| `src/assign/` | `assign` (the method: window, commit, output), `assign_membership`, `assign_cost`, `assign_rank`, `assign_bias` |
| `src/filter/` | `filter`, `filter_conditions` (conditions table), `filter_geometry`, `filter_pack` |
| `src/fuse/` | `fuse`, `fuse_kinematics` (methods table), `fuse_attributes` (rules table), `fuse_pack` |
| `src/quality/` | `quality`, `quality_samples`, `quality_measures` (measures table), `quality_rules`, `quality_pack` |
| `src/trace/` | `trace_log` (the output of one call), and each function's events and records: `trace_correlate`, `trace_assign`, `trace_filter`, `trace_fuse`, `trace_quality` |
| `src/snapshot/` | `snapshot_json` and each function's `snapshot()`: `snapshot_correlate`, `snapshot_assign`, `snapshot_filter`, `snapshot_fuse`, `snapshot_quality` |
| `src/io/` | `io_engine` (the function table and the entry point behaviour), `io_pack` (pack.def text), `io_runner` (the runner), `io_vectors` and the four `*_vectors` entry modules |

OTP already has modules named `io` and `trace`, so those areas' modules are
`io_*` and `trace_*`.

**One entry point shape** (`io_engine`'s behaviour), for all four functions:
`load_pack(Dir)`, `new(Pack)`, `ingest(Report, State) -> {Events, Trace,
State}`, `tick(NowMs, State) -> {Events, Trace, State}`, `snapshot(State)`.

**Pure functions, no hidden globals.** The state is the value `ingest` and
`tick` return; there is no process dictionary, ETS table or registered
process. The math takes its inputs as arguments: `model_kalman`,
`model_imm`, `correlate_gating`, `correlate_track`, `assign_cost:cost/3`
and `fused/1`, `assign_rank`, `assign_bias:move/4` and `observe/5`,
`fuse_kinematics`, `quality_measures`, `quality_samples:nis_value/5`,
`quality_rules:step/4`.

## Registration point

| Kind | One entry in | Or, per pack |
|---|---|---|
| correlate method | `correlate_methods:builtin/0` | `correlate:load_pack(Dir, #{methods => #{Name => Module}})` |
| correlate test | `correlate_test_kinds:builtin/0` | `correlate:load_pack(Dir, #{tests => #{Name => Kind}})` |
| quality measure | `quality_measures:builtin/0` | `quality:load_pack(Dir, #{measures => [Measure]})` |

The pack parser reads a test's parameters and a measure's name from the same
table the engine runs, so nothing else changes. Proof
(`test/registration_tests.erl`): a no-op test kind `noop` registered only in
the test. Registered, every correlate vector gives the same output as
without it. Its own test: the test-only fixture pack
`test/fixtures/correlate-noop` (correlate-gnn with `gate noop` first, not
under `packs/`, not in the spec) gives correlate-gnn's events and snapshots
on correlate-gnn's vectors, with one passing `noop` record before each gate
run. Unregistered, the fixture does not load.

## Tests and coverage

`engines/erlang/run_tests` runs the 339 vectors, then 549 EUnit tests:

| Tests | Module |
|---|---|
| unit, per module | `model_tests`, `correlate_unit_tests`, `assign_unit_tests`, `filter_unit_tests`, `fuse_unit_tests`, `quality_unit_tests`, `io_tests` (runner, vector comparison, pack text, trace, snapshot) |
| property: determinism | `property_tests`: every scenario vector twice, same output |
| property: order independence | `property_tests`: a report's keys in shuffled order (through JSON text); a pack's non-repeating lines reversed and shuffled (the specs check ranges once the file is read) |
| property: restore | `property_tests`: the state stored (`term_to_binary`) at the middle step and restored gives the same continued output and snapshot. The engine has no restore from `snapshot()`: that JSON does not hold the whole state (correlate's holds no last report) |
| property: ranking | `assign_unit_tests`: the branch-and-bound ranking against every assignment, 3000 seeded random cases |
| fuzzing | `fuzz_tests`: the steps-file JSON reader, the four pack.def parsers, the four ingest functions; a seeded generator in the test; `GOAT_FUZZ_ITERATIONS` inputs per target (1500 in `run_tests`, 300 in the coverage run), about 35 s at 5000 |
| registration | `registration_tests` |

**Coverage**, with OTP's own `cover` (the `tools` application), as line
coverage over every module of `src/`, while the vectors and the tests run
(`engines/erlang/coverage`):

| | Lines covered | Line coverage |
|---|---|---|
| Baseline: the pre-refactor engine (`883c42f`), its 11 engine modules, the vectors (its only tests) | 1,646 of 1,677 | 98.2 % |
| Floor, max(baseline, 80 %), enforced by the erlang job of `.github/workflows/conformance.yml` (`engines/erlang/coverage 98.2`) | | 98.2 % |
| Measured, the final tree, 49 modules | 1,890 of 1,905 | 99.2 % |

The 15 lines not covered are listed by the coverage run; 9 of them are the
VM entry points (`io_runner:main/0` and the four `*_vectors:main/1`, a
`halt` over a function the tests call).

On this machine the Ubuntu OTP has neither EUnit's code nor `tools`; the
same version's `erlang-eunit` and `erlang-tools` packages were unpacked
outside the repository and put on `ERL_LIBS`. CI's `setup-beam` OTP has
both.

## Hot spots

Profiled with `eprof` on the large scenario (the first 120 ticks for the
profile) through the runner, and on the vector commands. The three largest:

| # | Hot spot (profile share) | Fix | Before | After |
|---|---|---|---|---|
| 1 | `assign_rank:ranked/3` enumerated every assignment of a source's rows, then sorted them all to keep the first K: about 95 % of `correlate-assign-time` | a depth-first search, each row's options cheapest first, that keeps the K smallest totals found and leaves out a branch whose least possible total exceeds the K-th by more than a slack (1e-9 of the entries' magnitudes, far above any rounding); the result is the spec's first K, checked against the full enumeration (`every/3`) on 3000 seeded random cases | large scenario, engine calls (harness runner, median of 3): 537.19 s, 34.6 reports/s; peak 1,607 MB | 24.26 s, 765 reports/s (22x); peak 944 MB |
| 2 | `quality_measures`: each entity's window was walked once per measure that needs a sample (14 passes per entity per tick), about 40 % of `quality-time` | one recursive pass reads every sample's values and every count; the window drop removes its prefix (an entity's wt never decreases in arrival order) | 20,000 evaluations of a 60-record window: 2,050 ms CPU; large scenario, engine calls: 13.11 s, 1,417 reports/s | 650 ms CPU (3.2x); 6.93 s, 2,679 reports/s (1.9x) |
| 3 | `io_vectors:compare/3` (the vector command) formatted a path string (`io_lib:format`) for every element it compared: 15.7 s of the 23 s of the large filter vector | the path is built only on a mismatch, with the same text | large filter vector compare: 15.7 s; vector command, large filter: 919 reports/s, fuse 1,876, quality 696 | 3.0 s; 1,202, 2,856, 858 reports/s |

Also profiled, not changed: in method assign, after fix 1, predictions
(`model_kalman`, `model_imm`) are about 20 % of the time, repeated for each
history. Memoizing a source's entries per membership was tried and
measured: no gain (1.12 s and 1.12 s CPU on the 120-tick input), as the
histories rarely share their newest membership, so it was reverted. The
confirm method (`correlate-gnn-imm`) spends its time in its own pipeline
(`count/3`, `members/2`), which this round leaves to correlate 1.0.

The new layout has 49 modules where there were 16. Loading each on its
first call cost the small conformance-vector commands about 50 ms of
processor time; the entry points now load the function's modules in one
batch before their clocks start (`io_engine:preload/1`), which costs about
half as much.

## Performance, before and after

`python3 -I tools/perf/perf.py baseline --engines erlang` on this machine,
before the first change (commit `883c42f`, the runner only) and after the
last (`4405d02`). Each cell is the median (range slowest to fastest).
Other engines' refactor sessions ran on the machine meanwhile (load average
during the runs: before 18 to 87, after 6 to 53).

Conformance vectors, vector command, reports per second:

| Function | Before | After |
|---|---|---|
| correlate | 41.8 (19.1 to 103) | 43.3 (25.2 to 70.9) |
| filter | 18.9 (8.57 to 28.6) | 19.6 (12.3 to 28.9) |
| fuse | 11.4 (5.48 to 26.0) | 6.89 (2.12 to 12.1) |
| quality | 31.0 (9.61 to 40.5) | 32.9 (11.5 to 53.4) |

Large scenario, vector command, reports per second:

| Function | Before | After |
|---|---|---|
| correlate (2 packs) | 61.7 (61.6 to 67.6) | 731 (619 to 878) |
| filter | 919 (815 to 1,456) | 1,202 (1,087 to 2,364) |
| fuse | 1,876 (1,686 to 2,018) | 2,856 (1,147 to 2,965) |
| quality | 696 (584 to 841) | 858 (737 to 912) |

Large scenario, engine calls only (the runner), reports per second and run
time:

| Pack | Before | After |
|---|---|---|
| correlate-gnn-imm | 4,432 (3,514 to 4,652), 4.19 s | 5,077 (2,676 to 5,727), 3.66 s |
| correlate-assign-time | 34.6 (31.5 to 35.1), 537.19 s | 765 (570 to 897), 24.26 s |
| filter-thin | 9,500 (6,805 to 10,102), 1.95 s | 8,852 (8,421 to 10,114), 2.10 s |
| fuse-independent | 5,353 (5,321 to 9,031), 3.47 s | 8,981 (6,240 to 9,639), 2.07 s |
| quality-time | 1,417 (1,320 to 1,542), 13.11 s | 2,679 (1,683 to 3,076), 6.93 s |

Two medians read lower after: fuse's conformance vectors and filter-thin's
runner. Both were measured again, interleaving the before and after builds
run by run, by processor time (wall time on a loaded machine mostly
measures waiting):

| Cell | Before | After |
|---|---|---|
| fuse conformance vectors, 15 runs each, CPU of the command | 0.42 s | 0.40 s (wall 7.18 s, 5.44 s) |
| filter-thin, engine only, CPU per run inside one VM, 15 runs each | 587 to 629 ms | 571 to 597 ms |

So no function is slower; both are within the noise of the harness's
medians on this machine. Peak memory: correlate's large vector command
3,176 MB before, 3,397 MB after (ranges 2,960 to 3,271 and 2,317 to 3,482);
`correlate-assign-time`'s runner 1,607 MB before, 944 MB after; the others
within 6 %.
