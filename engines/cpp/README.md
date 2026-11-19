# goat-processors, C++ engine

Four functions: correlate, filter, fuse and quality.

## Correlate and filter

A C++17 implementation of `spec/filter.md` (version 0.1), of `spec/correlate.md`
(version 0.8, method `confirm`, with the two-model filter, the filter
restart and time quality) and of `spec/correlate-assign.md` (version 0.6,
method `assign`, with the multi-frame window, its margin, sensor bias and the
clock offset), written from the specifications and the vectors. The pack's `method`
line selects which correlate method runs. It uses only the standard library and has its
own small JSON reader.

| File | Spec section |
|---|---|
| `src/track.cpp` | correlate.md Frame, Track estimate (steps 1 to 3, each update returning its likelihood term for the two-model filter); shared with fuse and quality |
| `src/pack.cpp` | Pack (`parse_pack`, `load_pack`), with `time_default` and `time_offset` |
| `src/engine.cpp` | correlate.md: Reports "Time quality" (in `ingest`), Track estimate Measurement variance (`measurement_variance`, the `time` record, `predict_for_comparison` for the timing variance), Two-model filter (`filter_first`, `filter_update`, `predict`), Restart (`restart_test`, and its use in `ingest`), Tests, Association, Events, Trace, Snapshot |
| `src/assign.cpp` | correlate-assign.md: Memberships, Ranking (`rank_assignments`, brute force over every assignment), Assignment of one source (`rank_source`, `apply_assignment`), Sensor bias (`bias_state`, `predict_into_frame`, `bias_update`, and Time offset in `fit_time_offset`), Window (`tick_assign`, steps 1 to 6, with `margin`), Snapshot |
| `src/common.hpp` | helpers engine.cpp and assign.cpp both use |
| `src/report.cpp` | correlate.md "Reports": required keys, optional-key rules, `type` elements, the time quality keys (`time_error_at`, `time_state_at`); shared by all four functions |
| `src/filter_pack.cpp` | filter.md "Pack": directives, rules, `when` lines, parameter sets, values |
| `src/filter.cpp` | filter.md Geometry (distance, polygon, reference prediction), Conditions, Rules, Tick, Events, Trace, Snapshot |
| `src/json.cpp` | JSON values for reports, events, trace and snapshot |
| `test/run_vectors.cpp` | runs the correlate vectors |
| `test/run_filter_vectors.cpp` | the same comparison for `packs/filter-*` and `spec/filter-load-vectors/` |
| `test/vector_support.hpp` | the comparison in `spec/vector-format.md`, shared by the correlate, filter, fuse and quality runners |

API, in `src/engine.hpp` and `src/pack.hpp`:

```cpp
corr::Pack pack = corr::load_pack("packs/correlate-gnn");   // throws corr::PackError
corr::Engine engine(pack);
corr::Output out = engine.ingest(report);          // out.events, out.trace
out = engine.tick(now_ms);
corr::Json state = engine.snapshot();

// The filter (spec/filter.md 0.1), in src/filter.hpp and src/filter_pack.hpp:
corr::filter::Pack fpack = corr::filter::load_pack("packs/filter-area");  // throws corr::PackError
corr::filter::Engine filter(fpack);
corr::Output fout = filter.ingest(report);          // fout.events, fout.trace
fout = filter.tick(now_ms);
corr::Json fstate = filter.snapshot();
```

## Build and run the vectors

From the repository root:

```sh
cmake -S engines/cpp -B build/cpp && cmake --build build/cpp && ctest --test-dir build/cpp --output-on-failure
```

The ctest test `vectors` runs `run_vectors <repo root>`. It runs every
scenario vector under `packs/correlate-*/vectors/` and checks each step's events and
trace, then the final snapshot. It also runs every load vector under
`spec/correlate-load-vectors/`. The ctest test `filter_vectors` runs `run_filter_vectors <repo root>`: every
scenario vector under `packs/filter-*/vectors/` and every load vector under
`spec/filter-load-vectors/`. `run_vectors` prints `PASS` or `FAIL` for each vector, and for a
failure the path of the first mismatch, for example
`steps[1].trace[0].value: number differs (...)`. You can also run it by hand:

```sh
build/cpp/run_vectors .
build/cpp/run_quality_vectors .
```

The build passes `-ffp-contract=off` (and `-msse2 -mfpmath=sse` on x86) to
the correlator library, which holds the shared frame and filter, so no
`a*b + c` becomes a fused multiply-add and no intermediate is kept in
extended precision (correlate.md "Floats").

## Fuse

A C++17 implementation of `spec/fuse.md` (version 0.2), in its own module
(`corr::fuse`). It reuses the correlate engine's filter and frame from
`src/track.cpp` and its report reading from `src/report.cpp`, as fuse.md
"Shared with correlate.md" cites.

| File | Spec section |
|---|---|
| `src/fuse_pack.cpp` | Pack (`corr::fuse::parse_pack`, `corr::fuse::load_pack`) |
| `src/fuse.cpp` | Reports (normalized report, `stale-report`), Groups (`new`, `move`, output order), On each tick, Kinematics (all five methods), Attributes (all five rules), Fused event, Height, Trace, Snapshot |
| `test/run_fuse_vectors.cpp` | runs every vector under `packs/fuse-*/vectors/` and `spec/fuse-load-vectors/` |

```cpp
corr::fuse::Pack pack = corr::fuse::load_pack("packs/fuse-shared");  // throws corr::PackError
corr::fuse::Engine engine(pack);
corr::Output out = engine.ingest(report);   // out.events, out.trace
out = engine.tick(now_ms);
corr::Json state = engine.snapshot();
```

The ctest test `fuse_vectors` runs `run_fuse_vectors <repo root>`, which
prints `PASS`/`FAIL` per vector and, for a failure, the first mismatch path.

## Quality

A C++17 implementation of `spec/quality.md` (version 0.1), in its own module
(`corr::quality`). It reuses the correlate frame and filter from
`src/track.cpp`.

| File | Spec section |
|---|---|
| `src/quality_pack.cpp` | quality.md Pack and Rules (`quality::parse_pack`, `quality::load_pack`) |
| `src/quality.cpp` | quality.md Reports, Order, Frame and filter, Samples, Window, Entity measures, Source measures, Rules, Forwarding, Tick, Ingest, Events, Trace, Snapshot |
| `test/run_quality_vectors.cpp` | runs every vector under `packs/quality-*/vectors/` and `spec/quality-load-vectors/` |

```cpp
corr::quality::Pack qp = corr::quality::load_pack("packs/quality-feed");   // throws corr::PackError
corr::quality::Engine quality(qp);
corr::quality::Output qout = quality.ingest(report);   // qout.events, qout.trace
qout = quality.tick(now_ms);
corr::Json qstate = quality.snapshot();
```

The ctest test `quality_vectors` runs `run_quality_vectors <repo root>`, the
same checks for every vector under `packs/quality-*/vectors/` and
`spec/quality-load-vectors/`.

Where the specification leaves room for more than one reading, the reading
this engine takes is in `DISAGREEMENTS.md`.
