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
| `correlate.py` | what both correlate methods share: the entities, their filters, time quality, restart; the choice of method |
| `correlate_pack.py` | the correlate `pack.def` (both methods) |
| `gate.py` | the correlate tests |
| `confirm.py` | correlate method `confirm` (moved unchanged; correlate 1.0 replaces it) |
| `assign.py` | correlate method `assign`: memberships, assignment, ranking, window, bias |
| `filter.py` | the filter function |
| `fuse.py` | the fuse function |
| `quality.py` | the quality function |
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

## Where each spec section lives

### spec/correlate.md

| Section | File |
|---|---|
| What the correlator does | `correlate.py` |
| Reports | `model.py` |
| Reports, Time quality | `correlate.py` (`_time_error_ms`), `model.py` (normalization) |
| Frame | `model.py` |
| Track estimate | `estimate.py` |
| Two-model filter | `estimate.py` |
| Restart | `correlate.py` (`_accept`) |
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
| Shared with `correlate.md` | `correlate.py` |
| Memberships | `assign.py` |
| Assignment of one source | `assign.py` |
| Sensor bias | `assign.py` |
| Ranking | `assign.py` |
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
