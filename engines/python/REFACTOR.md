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
**130 of 130 identical, after every one of the seven commits.** The
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
| measured, final | MEASURED_LINES | MEASURED_PCT |

CI: the `python` job of `.github/workflows/conformance.yml` (the only job
changed) runs the whole suite through `coverage_check.py --floor 98.6`. The
same numbers on Python 3.11, 3.12 (CI's) and 3.14.

**Fuzzing found** (DISAGREEMENTS.md): the int-digits `ValueError` above
(fixed, exception type only); a report that makes the frame's wrap loop for
ever (a huge longitude, a huge predicted move, east motion at a pole); and
a `ce` whose square overflows, after which the two-model filter raises.
The last two are spec gaps; behavior unchanged.

## Mutation testing

MUTATION_SECTION

## Hot spots

HOTSPOT_SECTION

## Performance, before and after

PERF_SECTION
