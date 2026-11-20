# The Python engine refactor (round-refactor)

What changed in `engines/python`, and how each row of the round's "What
done means" table was measured. Branch `refactor/python`, from main at
407a295; one signed commit per step.

| Step | Commit |
|---|---|
| 1. runner (`runner/build`, `runner/run`), golden output recorded | `refactor(python): command-line runner` |
| 2. layout (`src/goat_core`), one entry point, README section map | `refactor(python): one module layout` |
| 3. pure functions for the math | `refactor(python): pure functions for the math` |
| 4. one registration table per extension kind, no-op test proof | `refactor(python): one registration table` |
| 5. unit, property and fuzz tests; coverage floor in CI | `test(python): unit tests per module` |
| 5b. mutation testing | `test(python): mutation testing` |
| 6. the three hot spots | `perf(python): the three hot spots` |
| 6. start-up and per-call costs | `perf(python): start-up and per-call costs` |
| 5b. tests for the final code's real-fault mutants | `test(python): tests for the real-fault mutants of the final code` |
| this report | `docs(python): REFACTOR.md` |

## Behavior: byte-identical

Before the first change, the runner (step 1, original engine) wrote the
golden files into a directory outside the repository:

- every scenario vector of every function (121 files: `packs/*/vectors/*.json`,
  each run with `--pack` of its own pack, `--steps` the vector, `--events`
  and `--trace`);
- the large scenario (`perf.py generate --size large`), each pack the
  harness names: `correlate-gnn-imm`, `correlate-assign-time` (both
  `large-correlate.json`), `filter-thin`, `fuse-independent`,
  `quality-time` (5 files, 18,571 reports and 600 ticks each, 1,074,287
  trace records for `correlate-assign-time` alone);
- every load vector's result, per function (4 files: 225 load vectors, each
  "ok" or the exception class).

After every step all 130 files were recorded again and compared with `cmp`:
**130 of 130 identical, after every commit that touched the engine.** The
conformance vectors pass after every step, and `python3 -I
tools/bench/bench.py check` passes (108 runs re-checked, scores identical)
after steps 2 and 5b and at the end.

One change of exception type, no change of output: an integer of more than
4300 digits in a filter, fuse or quality `pack.def` raised `ValueError`;
it now raises `PackError` (found by fuzzing; DISAGREEMENTS.md 3). The pack
loaded neither before nor after.

## Layout

`src/goat_core/`, one module per concern, the same names as the other
engines' modules: `model` (reports, frame), `estimate` (the track filter),
`correlate` (the method table and entry point), `tracks` (what both
correlate methods share), `gate` (the correlate tests), `confirm` (method
confirm, moved unchanged), `assign` (method assign), `ranking` (exact
assignment and Murty's ranking), `bias` (sensor bias and time offset),
`filter`, `fuse`, `quality`, `trace` (every trace record shape),
`snapshot` (every snapshot, and restore), `io` (pack directory, steps and
events files, the runner), `packdef` (`PackError`). `README.md` maps every
section of every spec to its file. The old packages `goat_correlator`,
`goat_filter`, `goat_fuse`, `goat_quality` only re-export their old names
(`tests/test_compat.py` checks every one), so the tools that import them
are unchanged.

**One entry point.** `goat_core.FUNCTIONS[name]` is a `Function`:
`load_pack(dir)` / `parse_pack(text)`, `make_engine(pack)`, `open(dir)`,
`restore(pack, snapshot)`; every engine has `ingest(report)` and
`tick(now_ms)`, each returning `(events, trace)`, and `snapshot()`. The
runner is `goat_core.io.main` behind `runner/run`.

**Pure functions, state in the engine.** The math is in module functions
that take values and return values: `estimate` (predict, updates, two-model
filter, inverse variance), `gate` (d², distance, course and speed
differences), `ranking`, `bias`, `assign.assignment_cost`,
`fuse.kinematics`, `fuse.attribute_winner`, `filter.evaluate`,
`quality.entity_measures`, `quality.source_measures`, `quality.rule_step`,
`quality.input_clock`. An engine's state is its object's attributes and
nothing else; every module-level table is read-only (`MappingProxyType`,
tuples). Two per-engine memos (assign's per-tick prediction cache, quality's
window measures) are derived from the state, never in `snapshot()`, and
reset or checked so they cannot go stale.

## Registration point

One table per extension kind; adding a built-in is one entry, and the pack
parser, the engine, the trace and the snapshot find it there.

| Kind | Table | Entry |
|---|---|---|
| correlate method | `correlate.METHODS` | `Method(engine, required, refused)` |
| correlate test | `gate.TESTS` | `TestKind(params, evaluate, text=False)` |
| quality measure | `quality.MEASURES` | `Measure(aggregate, compute, uses_age=False)` |
| filter condition | `filter.CONDITIONS` | `ConditionKind(params, evaluate)` |
| fuse method, attribute rule | `fuse.KINEMATICS`, `fuse.ATTRIBUTE_RULES` | a function; `AttributeRule(winner, numbers_only)` |

An extension for one use is one call that returns a new table
(`gate.extend`, `correlate.extend_methods`, `quality.extend_measures`,
`filter.extend_conditions`), given to the parser; only packs parsed with
it know the new name. **Proof:** `tests/registration.py` registers a no-op
test kind, `noop`, with one `gate.extend` call, in test code only.
`tests/test_registration.py` shows that every correlate vector parsed with
that table gives exactly its expected output (invisible), that the
engine's own table refuses `gate noop`, and runs its own vector
(`tests/fixtures/correlate-noop/`: a test-only pack, `packs/correlate-assign`
with `gate noop` first, not under `packs/` and not in the spec), in which the
fixture's events, and its trace without the `noop` records, equal the same
pack without the line. The same file extends a method, a quality measure
and a filter condition the same way.

## Tests and coverage

`cd engines/python && PYTHONPATH=src python3 -m unittest discover -s tests`

| Kind | Where |
|---|---|
| vectors (scenario and load) | `test_vectors.py`, `test_filter_vectors.py`, `test_fuse_vectors.py`, `test_quality_vectors.py` |
| unit, one file per module | `test_model`, `test_estimate`, `test_gate`, `test_ranking` (against brute force), `test_bias`, `test_assign` (also `tracks`), `test_correlate_pack`, `test_filter_unit`, `test_fuse_unit`, `test_quality_unit`, `test_trace_snapshot`, `test_io` |
| property | `test_properties.py`: determinism (twice, and with a fresh pack and steps, byte for byte); order independence where the spec allows it (pack lines that appear once, in any place; the interleaving of different entities' reports between ticks for method assign, fuse, and filter without `near`); snapshot, JSON round trip, restore, continue: the same output, at every step of every filter, fuse and quality vector. Correlate has no restore: its snapshot, as the spec defines it, omits each entity's last report and measurement variance |
| fuzzing | `test_fuzz.py`: seeded generator; the four pack.def parsers (shipped packs and load vectors mutated, numbers made odd, random text), the steps JSON reader, and the engines' report intake; bounded by `GOAT_FUZZ_CASES` (1500) and `GOAT_FUZZ_SECONDS` (4 s); run locally at 60,000 cases per parser |
| registration | `test_registration.py` |
| mutants | `test_mutants.py` (below) |

**Coverage** (`tests/coverage_check.py`: the standard library's
`sys.monitoring`, Python 3.12 and later; `sys.settrace` before):

| | Lines | Covered |
|---|---|---|
| baseline: 407a295, its four vector test files | 2421 | 98.6 % |
| floor (max of baseline and 80 %) | | 98.6 % |
| measured, final | 3018 | 99.8 % |

CI: the `python` job of `.github/workflows/conformance.yml` (the only job
changed) runs the whole suite through `coverage_check.py --floor 98.6`. The
same numbers on Python 3.11, 3.12 (CI's) and 3.14.

**Fuzzing found** (DISAGREEMENTS.md): the int-digits `ValueError` above
(fixed, exception type only); a report that makes the frame's wrap loop for
ever (a huge longitude, a huge predicted move, east motion at a pole); and
a `ce` whose square overflows, after which the two-model filter raises.
The last two are spec gaps; behavior unchanged.

## Mutation testing

`tests/mutate.py` (standard library: `ast`, `subprocess`, threads). One
mutant changes one comparison (`<`/`<=`, `>`/`>=`, `==`/`!=`, `in`/`not in`,
`is`/`is not`), one arithmetic operator (`+`/`-`, `*`/`/`, `//`, `%`, `**`,
also augmented), one `and`/`or`, drops one `not` or unary `-`, or changes one
constant (n to n+1, x to 2x or 1.0, True/False) in `src/goat_core`, not in
docstrings, strings or `raise` statements. Killed: the suite fails or
times out.

    python3 tests/mutate.py --jobs 12 --out vectors.json                 # the vectors
    python3 tests/mutate.py --suite all --only-survivors vectors.json    # then every test

| Final code | Mutants | Killed | Kill rate |
|---|---|---|---|
| the vectors only (scenario and load) | 1984 | 1691 | 85.2 % |
| the whole suite | 1984 | 1919 | 96.7 % |

By file, the vectors alone: estimate 98.8 %, bias 97.8 %, confirm 95.0 %,
assign 91.4 %, correlate_pack 88.2 %, tracks 85.7 %, snapshot 86.2 %,
quality 85.1 %, fuse 83.0 %, gate 81.9 %, filter 81.2 %, model 76.4 %,
ranking 75.0 % (most of its survivors are in the performance code: the
cache and the bound, which change no output by design), io 0 % (the
runner, which no vector runs; `test_io.py` and `test_mutants.py` kill all
43).

**Survivors that were real faults** got a test in `tests/test_mutants.py`
(or a unit test file), each naming its mutant: integer boundaries
(staleness at exactly `stale_ms` in confirm, assign and fuse, with
epoch-sized times; a report's own `stale_ms`), float boundaries tested
exactly (window and mahalanobis `<`, speed `<=`, restart `<`, bias gate
`<`, margin `<=`: the limit is set to exactly the computed value), the rank
tie between two candidates at equal d², `priority` 100 for an unlisted
source, every term of the two-model likelihood, a model whose probability
is 0, the timing variance on both axes and with no velocity, pack values at
their bounds (each function), `name=a=b` values, the affiliation of a
two-element type, inclusive radii, a moving `near` reference, polygon edges
and vertices away from the origin, boolean majority, covariance
intersection clamps and its velocity fold, `max` ties, an odd-count median,
`time_error_ms` 0, a `ce` below 1, the runner's flags and counters, a course
that rounds to 360. A first pass (before step 6) found 139 survivors after
the vectors and the unit tests; these tests took them to 42, and the same
work on the final code took 70 to 65.

**The 65 survivors.**

| Kind | Count | Mutants (file: line) | Why no output can change |
|---|---|---|---|
| error message only | 9 | correlate_pack 80, 81; filter 163, 164; fuse 43, 46; quality 96, 101 (`enumerate(.., 1)`, `split("#", 1)` to 2) | the line number in an error text (never compared), or the same first part of a split |
| loops that undo each other | 7 | model 85, 86, 111; filter 227, 228; fuse 148, 150 | the wrap's second loop (or the course's second step, or the clamp) gives the same value; at most a last-bit difference, within the vectors' tolerance |
| cannot happen | 10 | assign 133, 373; tracks 83 (sources or keys never equal there); bias 62, ranking 90, 172, 174 (ties give the same value); quality 224, 470 (equal times give the same value); filter 488 (equal times: the same assignment) |
| the same edges | 1 | filter 251 (`(i + 1) % n` to `(i - 1) % n`) | the polygon's edges walked backwards are the same edges |
| a value always overwritten | 4 | quality 472, tracks 30, filter 261 (`px <= xc` on an edge, which the boundary test has already returned), fuse 133 (a string never equals a number either way) |
| equal by construction | 2 | snapshot 50, trace 23 (`var` of north for east: the bias variance is the same on both axes) |
| the Hungarian's internals | 9 | ranking 26 (×2), 27 (×2), 29 (×2), 34, 47, 97 | unused array slots, a uniform shift of the potentials, a different optimum among equal ones: the row-by-row fixing still returns the spec's first assignment |
| caches (step 6) | 8 | assign 334 (×2), quality 201, 278, 545, 642, 646, tracks 42 | a cache key or flag that only makes the engine compute a value again (or keep one it never reads) |
| the ranking bound (step 6) | 14 | ranking 134, 135 (×5), 168 (×2), 170, 207, 213 (×4) | a weaker bound, a larger margin, or a check that only sends a candidate to the exact solver: less pruning, the same result. Two (`135 + -> -`, `213 + -> -`) make the margin negative: they could prune a candidate whose total is below the best by less than about 1e-9 of the largest entry, a near tie the spec's Floats rule keeps out of every vector |
| real, not reached | 1 | assign 299 | the tie order between candidate histories (`(total, history, rank)` to `(total, rank, rank)`): it needs one history's second-best extension to tie exactly with another's best. No vector or test builds that; listed for proc-coord |


## Hot spots

Profiled with cProfile on the large scenario (18,571 reports, 600 ticks)
through the runner's engine calls, every function. The engine's time is
overwhelmingly in correlate method assign (`correlate-assign-time`: about
40 times any other function); the three largest hot spots:

| # | Hot spot (profile, before) | Fix | Before | After |
|---|---|---|---|---|
| 1 | `ranking.min_cost_assignment`, the exact assignment inside Murty's ranking: 828,150 calls, 167 s of 314 s profiled | each subproblem (the cost matrix under a set of fixed and a set of forbidden entries) solved once per ranking; a candidate whose lower bound (its fixed entries plus each free row's least allowed entry) exceeds the best total by more than any rounding can is not solved (the spec's comparison is strict, so it could not win); the scan visits only the columns outside the tree, ascending, with the same binary64 operations | 828,150 solves | 312,407 solves |
| 2 | `ranking._constrained`, a full copy of the matrix per subproblem: 826,202 calls, 45 s profiled | built only when a subproblem is not already solved; rows copied by slice; a fixed row made in one step | 826,202 matrices | 312,407 matrices |
| 3 | `quality` entity measures at every tick: 29,954 windows of up to 60 samples, 14 s of 20 s profiled | one column per sample field, counts by `list.count`, the mean by `reduce(add)` (the same left-to-right additions as the loop: the builtin `sum` compensates since Python 3.12, so it would change the last bits), expired samples dropped as a prefix (a window's `wt` never decreases), and the measures that do not read the age reused while the window is unchanged | 29,954 window computations | 21,614 (28 % reused) |

Also, with the same care for the last bit: assign computes each prediction
and each pair's d² and distance once per tick (they cannot change until
the bias update, after which only predictions are kept); fuse looks up
source ranks in a dict (it searched the source list per member); report
validation calls one checker per kind.

The engine-call CPU time of the functions these hot spots live in
(interleaved runs, best of 2 to 5): `correlate-assign-time` 54.7 s to
23.9 s (0.44), `quality-time` 1.95 s to 1.76 s (0.90). Every equality was
checked: the 130 golden files are byte-identical after each change.

Not fixed, with the reason: the Hungarian itself is still pure Python
(about a third of the remaining assign time). A faster exact solver that
returns the same optimum among equal ones would need the same tie
behavior, which only this algorithm's own loop order gives; and the
standard library has no vector arithmetic. The per-report filter
arithmetic (`estimate`) is a few dozen float operations in the order the
spec writes them; `predict_axis`, its largest part, is about 8 % of
`correlate-gnn-imm` and less elsewhere, and has nothing to remove.

## Performance, before and after

**Before**: commit cdfc2a8 (the original engine with step 1's runner; its
vector commands are those of main 407a295). **After**: the final commit.
Same machine (16 cores, Linux, Python 3.14.4), which other sessions'
builds kept at a load average of 30 to 100 for most of the day.

**CPU time of the engine calls** (`time.process_time` around exactly the
runner's ingest/tick/snapshot calls, before and after run alternately,
best of n): this is the comparison that load does not distort.

| Function, pack (large scenario) | Before | After | After/before |
|---|---|---|---|
| correlate, `correlate-assign-time` (n=2) | 54.73 s | 23.94 s | 0.44 |
| correlate, `correlate-gnn-imm` (n=5) | 0.57 s | 0.55 s | 0.97 |
| filter, `filter-thin` (n=5) | 0.24 s | 0.21 s | 0.86 |
| fuse, `fuse-independent` (n=15) | 0.26 s (median 0.271) | 0.25 s (median 0.276) | 0.98 (median 1.02) |
| quality, `quality-time` (n=5) | 1.95 s | 1.76 s | 0.90 |

| Vector command (CPU of the whole process, n=11; min / median) | Before | After | After/before |
|---|---|---|---|
| `python3 -m unittest test_vectors` (correlate) | 0.104 / 0.116 s | 0.109 / 0.115 s | 1.05 / 0.99 |
| `test_filter_vectors` | 0.067 / 0.071 s | 0.063 / 0.073 s | 0.94 / 1.03 |
| `test_fuse_vectors` | 0.062 / 0.070 s | 0.063 / 0.076 s | 1.02 / 1.09 |
| `test_quality_vectors` | 0.083 / 0.092 s | 0.081 / 0.096 s | 0.98 / 1.04 |

The vector commands are about 0.1 s processes, mostly interpreter start and
the imports of `json` and `unittest`; their before/after differences are
within the ±5 % that repeated runs of one tree show. They were 4 to 18 %
slower at step 6's first commit (the new layout imported every module and
`typing`); the last perf commit removed that (lazy `FUNCTIONS`, no
`typing`, no `json` in the engines). Fuse on the large scenario is equal
within measurement (one run in fifteen sets each minimum); it is the one
function the refactor did not make faster.

**The harness** (`python3 -I tools/perf/perf.py baseline --engines python`,
wall time, medians of 10 vector runs and 3 large runs; its own
`results.json` files are in /tmp, not committed: `docs/performance.md` is
proc-bench's). The before run had a load average near 100, the after run
near 20, so these ratios overstate the gain; they are given as measured.

| Measure | Before (median, min-max) | After (median, min-max) | After/before (median) |
|---|---|---|---|
| vectors, correlate (wall) | 0.398 s (0.273-0.921) | 0.423 s (0.244-0.878) | 1.06 |
| vectors, filter (wall) | 0.307 s (0.184-0.464) | 0.219 s (0.130-0.293) | 0.71 |
| vectors, fuse (wall) | 0.331 s (0.185-0.555) | 0.172 s (0.134-0.402) | 0.52 |
| vectors, quality (wall) | 0.353 s (0.273-0.485) | 0.204 s (0.189-0.262) | 0.58 |
| large vector, correlate (wall) | 199.311 s (188.274-236.494) | 72.502 s (71.822-87.894) | 0.36 |
| large vector, filter (wall) | 7.602 s (5.931-13.021) | 3.820 s (3.550-6.919) | 0.50 |
| large vector, fuse (wall) | 2.830 s (2.450-2.887) | 1.976 s (1.704-2.895) | 0.70 |
| large vector, quality (wall) | 11.392 s (11.288-13.816) | 8.933 s (8.904-9.410) | 0.78 |
| runner correlate-assign-time (engine calls) | 153.283 s (133.575-176.826) | 39.003 s (38.933-42.281) | 0.25 |
| runner correlate-gnn-imm (engine calls) | 3.262 s (2.910-6.294) | 1.111 s (1.109-1.128) | 0.34 |
| runner filter-thin (engine calls) | 1.082 s (0.811-1.351) | 0.610 s (0.594-0.659) | 0.56 |
| runner fuse-independent (engine calls) | 0.892 s (0.833-1.334) | 0.718 s (0.624-1.254) | 0.81 |
| runner quality-time (engine calls) | 8.606 s (7.107-8.971) | 5.001 s (4.677-5.453) | 0.58 |

Peak memory (resident set of the runner) is unchanged: within 2 % on every
pack.
