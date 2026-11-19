# goat-processors, C++ engine

Two functions, correlate and fuse.

## Correlate

A C++17 implementation of `spec/correlate.md` (version 0.4, method `confirm`)
and `spec/correlate-assign.md` (version 0.2, method `assign`), written from the
specifications and the vectors. The pack's `method` line selects which runs. It uses only the standard library and has its
own small JSON reader.

| File | Spec section |
|---|---|
| `src/track.cpp` | correlate.md Reports (reading keys, required keys), Frame, Track estimate; shared with fuse |
| `src/pack.cpp` | Pack (`parse_pack`, `load_pack`) |
| `src/engine.cpp` | Reports, Frame, Track estimate, Tests, Association, Events, Trace, Snapshot; then correlate-assign.md: Assignment (with `min_cost_assignment`, the Hungarian method with potentials), Events, Trace, Snapshot |
| `src/json.cpp` | JSON values for reports, events, trace and snapshot |
| `test/compare.hpp` | the comparison in `spec/vector-format.md`, shared by both runners |
| `test/run_vectors.cpp` | runs the correlate vectors |
| `test/assignment_test.cpp` | `min_cost_assignment` against brute force on random matrices |

API, in `src/engine.hpp` and `src/pack.hpp`:

```cpp
corr::Pack pack = corr::load_pack("packs/correlate-gnn");   // throws corr::PackError
corr::Engine engine(pack);
corr::Output out = engine.ingest(report);          // out.events, out.trace
out = engine.tick(now_ms);
corr::Json state = engine.snapshot();
```

## Build and run the vectors

From the repository root:

```sh
cmake -S engines/cpp -B build/cpp && cmake --build build/cpp && ctest --test-dir build/cpp --output-on-failure
```

The ctest test `vectors` runs `run_vectors <repo root>`. It runs every
scenario vector under `packs/correlate-*/vectors/` and checks each step's events and
trace, then the final snapshot. It also runs every load vector under
`spec/correlate-load-vectors/`. The ctest test `assignment` checks the
assignment solver against brute force. `run_vectors` prints `PASS` or `FAIL` for each vector, and for a
failure the path of the first mismatch, for example
`steps[1].trace[0].value: number differs (...)`. You can also run it by hand:

```sh
build/cpp/run_vectors .
```

## Fuse

A C++17 implementation of `spec/fuse.md` (version 0.1), in its own module
(`corr::fuse`). It reuses the correlate engine's filter, frame and report
reading from `src/track.cpp`, as fuse.md "Shared with correlate.md" cites.

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

Where the specification leaves room for more than one reading, the reading
this engine takes is in `DISAGREEMENTS.md`.
