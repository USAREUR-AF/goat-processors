# goat-correlator, C++ engine

A C++17 implementation of `spec/correlate.md` (version 0.3, method `confirm`)
and `spec/correlate-assign.md` (version 0.1, method `assign`), written from the
specifications and the vectors. The pack's `method` line selects which runs. It uses only the standard library and has its
own small JSON reader.

| File | Spec section |
|---|---|
| `src/pack.cpp` | Pack (`parse_pack`, `load_pack`) |
| `src/engine.cpp` | Reports, Frame, Track estimate, Tests, Association, Events, Trace, Snapshot; then correlate-assign.md: Assignment (with `min_cost_assignment`, the Hungarian method with potentials), Events, Trace, Snapshot |
| `src/json.cpp` | JSON values for reports, events, trace and snapshot |
| `test/run_vectors.cpp` | the comparison in `spec/vector-format.md` |
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
cmake -S engines/cpp -B /tmp/corr4-cpp && cmake --build /tmp/corr4-cpp && ctest --test-dir /tmp/corr4-cpp --output-on-failure
```

The ctest test `vectors` runs `run_vectors <repo root>`. It runs every
scenario vector under `packs/*/vectors/` and checks each step's events and
trace, then the final snapshot. It also runs every load vector under
`spec/correlate-load-vectors/`. The ctest test `assignment` checks the
assignment solver against brute force. `run_vectors` prints `PASS` or `FAIL` for each vector, and for a
failure the path of the first mismatch, for example
`steps[1].trace[0].value: number differs (...)`. You can also run it by hand:

```sh
/tmp/corr4-cpp/run_vectors .
```

Where the specification leaves room for more than one reading, the reading
this engine takes is in `DISAGREEMENTS.md`.
