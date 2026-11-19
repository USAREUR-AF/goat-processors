# goat-correlator, C++ engine

A C++17 implementation of `spec/correlator-spec.md`, written from the
specification and the vectors. It uses only the standard library and has its
own small JSON reader.

| File | Spec section |
|---|---|
| `src/pack.cpp` | Pack (`parse_pack`, `load_pack`) |
| `src/engine.cpp` | Reports, Frame, Track estimate, Tests, Association, Events, Trace, Snapshot |
| `src/json.cpp` | JSON values for reports, events, trace and snapshot |
| `test/run_vectors.cpp` | the comparison in `spec/vector-format.md` |

API, in `src/engine.hpp` and `src/pack.hpp`:

```cpp
corr::Pack pack = corr::load_pack("packs/gnn");   // throws corr::PackError
corr::Engine engine(pack);
corr::Output out = engine.ingest(report);          // out.events, out.trace
out = engine.tick(now_ms);
corr::Json state = engine.snapshot();
```

## Build and run the vectors

From the repository root:

```sh
cmake -S engines/cpp -B /tmp/corr-cpp && cmake --build /tmp/corr-cpp && ctest --test-dir /tmp/corr-cpp --output-on-failure
```

The ctest test `vectors` runs `run_vectors <repo root>`. It runs every
scenario vector under `packs/*/vectors/` and checks each step's events and
trace, then the final snapshot. It also runs every load vector under
`spec/load-vectors/`. It prints `PASS` or `FAIL` for each vector, and for a
failure the path of the first mismatch, for example
`steps[1].trace[0].value: number differs (...)`. You can also run it by hand:

```sh
/tmp/corr-cpp/run_vectors .
```

Where the specification leaves room for more than one reading, the reading
this engine takes is in `DISAGREEMENTS.md`.
