# goat-processors, C++ engine

A C++17 implementation of `spec/correlate.md` (version 0.4, method `confirm`)
and `spec/correlate-assign.md` (version 0.2, method `assign`), and of
`spec/quality.md` (version 0.1), written from the
specifications and the vectors. The pack's `method` line selects which runs. It uses only the standard library and has its
own small JSON reader.

| File | Spec section |
|---|---|
| `src/kalman.cpp` | correlate.md Frame and Track estimate, shared by both functions |
| `src/pack.cpp` | Pack (`parse_pack`, `load_pack`) |
| `src/engine.cpp` | Reports, Frame, Track estimate, Tests, Association, Events, Trace, Snapshot; then correlate-assign.md: Assignment (with `min_cost_assignment`, the Hungarian method with potentials), Events, Trace, Snapshot |
| `src/json.cpp` | JSON values for reports, events, trace and snapshot |
| `src/quality_pack.cpp` | quality.md Pack and Rules (`quality::parse_pack`, `quality::load_pack`) |
| `src/quality.cpp` | quality.md Reports, Order, Frame and filter, Samples, Window, Entity measures, Source measures, Rules, Forwarding, Tick, Ingest, Events, Trace, Snapshot |
| `test/vector_compare.hpp` | the comparison in `spec/vector-format.md` |
| `test/run_vectors.cpp` | correlate vectors: `packs/correlate-*` and `spec/correlate-load-vectors/` |
| `test/run_quality_vectors.cpp` | quality vectors: `packs/quality-*` and `spec/quality-load-vectors/` |
| `test/assignment_test.cpp` | `min_cost_assignment` against brute force on random matrices |

API, in `src/engine.hpp` and `src/pack.hpp`:

```cpp
corr::Pack pack = corr::load_pack("packs/correlate-gnn");   // throws corr::PackError
corr::Engine engine(pack);
corr::Output out = engine.ingest(report);          // out.events, out.trace
out = engine.tick(now_ms);
corr::Json state = engine.snapshot();

corr::quality::Pack qp = corr::quality::load_pack("packs/quality-feed");   // throws corr::PackError
corr::quality::Engine quality(qp);                 // same ingest / tick / snapshot
```

## Build and run the vectors

From the repository root:

```sh
cmake -S engines/cpp -B build/cpp && cmake --build build/cpp && ctest --test-dir build/cpp --output-on-failure
```

The ctest test `vectors` runs `run_vectors <repo root>`. It runs every
scenario vector under `packs/correlate-*/vectors/` and checks each step's events and
trace, then the final snapshot. It also runs every load vector under
`spec/correlate-load-vectors/`. The ctest test `quality_vectors` runs `run_quality_vectors <repo root>`, the
same checks for every vector under `packs/quality-*/vectors/` and
`spec/quality-load-vectors/`. The ctest test `assignment` checks the
assignment solver against brute force. `run_vectors` prints `PASS` or `FAIL` for each vector, and for a
failure the path of the first mismatch, for example
`steps[1].trace[0].value: number differs (...)`. You can also run it by hand:

```sh
build/cpp/run_vectors .
build/cpp/run_quality_vectors .
```

Where the specification leaves room for more than one reading, the reading
this engine takes is in `DISAGREEMENTS.md`.
