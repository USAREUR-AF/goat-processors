# The Python engine

One of the seven engines of goat-processors: correlate (methods `confirm` and
`assign`), filter, fuse and quality, written from `spec/` and the vectors.
Python 3.9 or later, standard library only.

```
cd engines/python && PYTHONPATH=src python3 -m unittest discover -s tests
engines/python/runner/run --function <correlate|filter|fuse|quality> --pack <dir> --steps <file> [--events <file>] [--trace]
```

## Layout

Everything is in `src/goat_core/`. The packages `goat_correlator`,
`goat_filter`, `goat_fuse` and `goat_quality` only re-export the names they
have always had, for the tools that import them.

| Module | Holds |
|---|---|
| `__init__.py` | `FUNCTIONS`: the one table of functions, each a `Function` entry point |
| `model.py` | the shared-model report (required and optional keys, normalization) and the local plane |
| `estimate.py` | the track estimate: one-model and two-model Kalman filter, pure functions |
| `correlate.py` | `METHODS`, the table of correlate methods; parse_pack, load_pack, make_engine |
| `tracks.py` | what both correlate methods share: the entities, their filters, time quality, restart |
| `correlate_pack.py` | the correlate `pack.def` (both methods) |
| `gate.py` | `TESTS`, the table of correlate tests |
| `confirm.py` | correlate method `confirm` (moved unchanged; correlate 1.0 replaces it) |
| `assign.py` | correlate method `assign`: memberships, the assignment of one source, window, output |
| `ranking.py` | the exact minimum-cost assignment and Murty's ranking, pure functions of the cost matrix |
| `bias.py` | sensor bias and time offset per pair of sources, pure functions |
| `filter.py` | the filter function; `CONDITIONS`, its table of conditions |
| `fuse.py` | the fuse function; `KINEMATICS` and `ATTRIBUTE_RULES`, its tables |
| `quality.py` | the quality function; `MEASURES`, its table of measures |
| `trace.py` | one constructor per trace record shape |
| `snapshot.py` | `snapshot()` of every engine |
| `io.py` | the steps and events files, the runner |
| `packdef.py` | reading `pack.def` from a pack directory; `PackError`, shared by every pack parser |

**Entry point.** Every function has the same shape:

```python
from goat_core import FUNCTIONS
fn = FUNCTIONS["fuse"]
engine = fn.open("packs/fuse-independent")   # load the pack, create the engine
events, trace = engine.ingest(report)        # one entity
events, trace = engine.tick(now_ms)          # one tick
state = engine.snapshot()
```

**Pure functions, state in the engine.** The math is in module functions
that take values and return new values: `estimate.py` (predict, update,
two-model, inverse variance), `gate.py` (d2, distance, course, speed),
`ranking.py`, `bias.py`, `assign.assignment_cost`, `fuse.kinematics`,
`fuse.attribute_winner`, `filter.evaluate` and the geometry,
`quality.entity_measures`, `quality.source_measures`, `quality.rule_step`,
`quality.input_clock`. An engine's state is only its object's attributes;
`snapshot()` (snapshot.py) reads them. Module-level names are constants.
Two memos, derived from the state and never in a snapshot: method assign
computes each prediction and pair value once per tick (reset every tick),
and quality keeps an entity's window measures while its window is
unchanged (keyed by a version the window bumps). `FUNCTIONS` imports a
function's modules when it is first used.

## Registration: one table per extension kind

| Kind | Table | An entry |
|---|---|---|
| correlate method | `correlate.METHODS` | `Method(engine, required, refused)`: the engine class (a `tracks.Correlator`) and the directives the method's packs must and must not hold |
| correlate test | `gate.TESTS` | `TestKind(params, evaluate, text=False)`: `evaluate(eng, prm, a, b)` returns `(value, limit, pass)`, or `None` when skipped |
| quality measure | `quality.MEASURES` | `Measure(aggregate, compute, uses_age=False)`: `compute(window)` gives the entity measure; `aggregate` (sum, mean, max, min) the source measure; `uses_age` when it reads the tick's time, not only the samples |
| filter condition | `filter.CONDITIONS` | `ConditionKind(params, evaluate)` |
| fuse method, attribute rule | `fuse.KINEMATICS`, `fuse.ATTRIBUTE_RULES` | a function; `AttributeRule(winner, numbers_only)` |

Adding a built-in is one entry in its table; the pack parser, the engine,
the trace and the snapshot find it there and need no other edit. The tables
are read-only (`MappingProxyType`). An extension for one use is given to the
parser instead: `gate.extend(gate.TESTS, name, kind)` (and `extend_methods`,
`extend_measures`, `extend_conditions`) returns a new table, and only the
packs parsed with it (`correlate.parse_pack(text, tests=...)`) know the new
name. `tests/registration.py` registers the no-op test `noop` that way;
`tests/test_registration.py` shows that it is invisible to every existing
vector, that the engine's own table refuses it, and runs its own vector
(`tests/fixtures/correlate-noop/`, a test-only pack, not under `packs/`).

## Where each spec section lives

### spec/correlate.md

| Section | File |
|---|---|
| What the correlator does | `correlate.py`, `tracks.py` |
| Reports | `model.py` |
| Reports, Time quality | `tracks.py` (`_time_error_ms`), `model.py` (normalization) |
| Frame | `model.py` |
| Track estimate | `estimate.py` |
| Two-model filter | `estimate.py` |
| Restart | `tracks.py` (`_accept`) |
| Tests | `gate.py` |
| Association | `confirm.py` |
| Events | `confirm.py` |
| Trace | `trace.py` |
| Snapshot | `snapshot.py` |
| Pack | `correlate_pack.py` |
| Floats | `estimate.py` |
| Open points | `DISAGREEMENTS.md` |

### spec/correlate-assign.md

| Section | File |
|---|---|
| What this method does | `assign.py` |
| Shared with `correlate.md` | `tracks.py` |
| Memberships | `assign.py` |
| Assignment of one source | `assign.py` |
| Sensor bias | `bias.py` |
| Ranking | `ranking.py` |
| Window | `assign.py` |
| Events | `assign.py` |
| Trace | `trace.py` |
| Snapshot | `snapshot.py` |
| Pack | `correlate_pack.py` |
| Open points | `DISAGREEMENTS.md` |

### spec/filter.md

| Section | File |
|---|---|
| What the filter does | `filter.py` |
| Reports | `model.py` |
| Geometry | `filter.py` |
| Conditions | `filter.py` |
| Rules | `filter.py` |
| Tick | `filter.py` |
| Events | `filter.py` |
| Trace | `trace.py` |
| Snapshot | `snapshot.py` |
| Pack | `filter.py` |
| Floats | `filter.py` |
| Open points | `DISAGREEMENTS.md` |

### spec/fuse.md

| Section | File |
|---|---|
| What fuse does | `fuse.py` |
| Shared with `correlate.md` | `model.py`, `estimate.py` |
| Reports | `model.py` |
| Groups | `fuse.py` |
| On each tick, Fused event | `fuse.py` |
| Kinematics (each method) | `fuse.py` |
| Attributes | `fuse.py` |
| Events | `fuse.py` |
| Trace | `trace.py` |
| Snapshot | `snapshot.py` |
| Pack | `fuse.py` |
| Floats | `estimate.py` |
| Open points | `DISAGREEMENTS.md` |

### spec/quality.md

| Section | File |
|---|---|
| What quality does | `quality.py` |
| Reports, Time quality | `quality.py` |
| Order | `quality.py` |
| Frame and filter | `model.py`, `estimate.py` |
| Input clock | `quality.py` |
| Samples | `quality.py` |
| Window | `quality.py` |
| Entity measures | `quality.py` |
| Source measures | `quality.py` |
| Rules | `quality.py` |
| Forwarding | `quality.py` |
| Tick, Ingest | `quality.py` |
| Events | `quality.py` |
| Trace | `trace.py` |
| Snapshot | `snapshot.py` |
| Pack | `quality.py` |
| Floats | `estimate.py` |
| Open points | `DISAGREEMENTS.md` |

### spec/vector-format.md

| Section | File |
|---|---|
| Scenario vectors, What the engine checks | `tests/test_vectors.py` and the other `tests/test_*_vectors.py` |
| Load vectors | the same |
| Steps files (tools/perf runner contract) | `io.py`, `runner/` |

## Tests

`PYTHONPATH=src python3 -m unittest discover -s tests` runs all of them
(about 6 s); `PYTHONPATH=src python3 tests/coverage_check.py --floor 98.6`
runs the same suite with line coverage, as CI does.

| File | What |
|---|---|
| `test_vectors.py`, `test_filter_vectors.py`, `test_fuse_vectors.py`, `test_quality_vectors.py` | every scenario vector and load vector of the function |
| `test_model.py`, `test_estimate.py`, `test_gate.py`, `test_ranking.py`, `test_bias.py`, `test_assign.py`, `test_correlate_pack.py`, `test_filter_unit.py`, `test_fuse_unit.py`, `test_quality_unit.py`, `test_trace_snapshot.py`, `test_io.py` | unit tests, one file per module (`test_assign.py` also covers `tracks.py` and `confirm.py`'s pair key) |
| `test_properties.py` | determinism; order independence where the spec allows it (pack lines, the interleaving of reports between ticks for assign, fuse and filter without `near`); snapshot, restore, continue |
| `test_fuzz.py` | the pack.def parsers, the steps JSON reader and the engines' report intake, from a seeded generator; bounded by `GOAT_FUZZ_CASES` (1500) and `GOAT_FUZZ_SECONDS` (4 s per parser); `GOAT_FUZZ_SEED` changes the seed |
| `test_registration.py`, `registration.py`, `fixtures/correlate-noop/` | the registration point (above) |
| `test_compat.py` | the old packages still export every old name |
| `test_mutants.py` | one test per real-fault mutant the vectors missed (REFACTOR.md) |
| `mutate.py` | mutation testing, standard library only (REFACTOR.md) |
| `coverage_check.py` | line coverage with the standard library only: `sys.monitoring` (Python 3.12 and later), `sys.settrace` before |


**Restore.** Filter, fuse and quality restore from a snapshot
(`FUNCTIONS[f].restore(pack, snapshot)`). Correlate does not: its snapshot,
as the spec defines it, omits each entity's last report and measurement
variance, which its tests, staleness and output read.

**Coverage.** Baseline (the engine and its four vector test files before
this refactor, commit 407a295): 98.6 % of 2421 lines. Floor: 98.6 %
(the higher of the baseline and 80 %), enforced by the `python` job of
`.github/workflows/conformance.yml`. The same numbers on Python 3.11, 3.12
and 3.14. Measured after this refactor: 99.8 % of 3018 lines.
