# goat-processors, C++ engine

Four functions: correlate, filter, fuse and quality.

## Correlate and filter

A C++17 implementation of `spec/filter.md` (version 0.1) and of `spec/correlate.md` (version 0.4, method `confirm`)
and `spec/correlate-assign.md` (version 0.2, method `assign`), written from the
specifications and the vectors. The pack's `method` line selects which runs. It uses only the standard library and has its
own small JSON reader.

| File | Spec section |
|---|---|
| `src/track.cpp` | correlate.md Frame, Track estimate; shared with fuse and quality |
| `src/pack.cpp` | Pack (`parse_pack`, `load_pack`) |
| `src/engine.cpp` | Reports, Frame, Track estimate, Tests, Association, Events, Trace, Snapshot; then correlate-assign.md: Assignment (with `min_cost_assignment`, the Hungarian method with potentials), Events, Trace, Snapshot |
| `src/report.cpp` | correlate.md "Reports": required keys, optional-key rules, `type` elements; shared by all three functions |
| `src/filter_pack.cpp` | filter.md "Pack": directives, rules, `when` lines, parameter sets, values |
| `src/filter.cpp` | filter.md Geometry (distance, polygon, reference prediction), Conditions, Rules, Tick, Events, Trace, Snapshot |
| `src/json.cpp` | JSON values for reports, events, trace and snapshot |
| `test/run_vectors.cpp` | runs the correlate vectors |
| `test/run_filter_vectors.cpp` | the same comparison for `packs/filter-*` and `spec/filter-load-vectors/` |
| `test/vector_support.hpp` | the comparison in `spec/vector-format.md`, shared by the correlate, filter, fuse and quality runners |
| `test/assignment_test.cpp` | `min_cost_assignment` against brute force on random matrices |

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
`spec/filter-load-vectors/`. The ctest test `assignment` checks the
assignment solver against brute force. `run_vectors` prints `PASS` or `FAIL` for each vector, and for a
failure the path of the first mismatch, for example
`steps[1].trace[0].value: number differs (...)`. You can also run it by hand:

```sh
build/cpp/run_vectors .
build/cpp/run_quality_vectors .
```

## Fuse

A C++17 implementation of `spec/fuse.md` (version 0.1), in its own module
(`corr::fuse`). It reuses the correlate engine's filter and frame from
`src/track.cpp` and its report reading from `src/report.cpp`, as fuse.md
"Shared with correlate.md" cites.

| File | Spec section |
|---|---|
| `src/fuse_pack.cpp` | Pack (`corr::fuse::parse_pack`, `corr::fuse::load_pack`) |
| `src/fuse.cpp` | Reports (normalised report, `stale-report`), Groups (`new`, `move`, output order), On each tick, Kinematics (all five methods), Attributes (all five rules), Fused event, Height, Trace, Snapshot |
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
