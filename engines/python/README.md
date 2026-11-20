# The Python engine

The reference engine of goat-processors: correlate (methods `confirm` and
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
| `io.py` | the pack directory, the steps and events files, the runner |
| `packdef.py` | `PackError`, shared by every pack parser |

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

## Registration: one table per extension kind

| Kind | Table | An entry |
|---|---|---|
| correlate method | `correlate.METHODS` | `Method(engine, required, refused)`: the engine class (a `tracks.Correlator`) and the directives the method's packs must and must not hold |
| correlate test | `gate.TESTS` | `TestKind(params, evaluate, text=False)`: `evaluate(eng, prm, a, b)` returns `(value, limit, pass)`, or `None` when skipped |
| quality measure | `quality.MEASURES` | `Measure(aggregate, compute)`: `compute(window)` gives the entity measure; `aggregate` (sum, mean, max, min) the source measure |
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
