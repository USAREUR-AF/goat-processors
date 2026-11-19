# goat-correlator, C++ engine

A C++17 implementation of `spec/correlate.md` (version 0.5, method `confirm`,
with the two-model filter) and `spec/correlate-assign.md` (version 0.3, method
`assign`, with the multi-frame window), written from the specifications and
the vectors. The pack's `method` line selects which runs. It uses only the standard library and has its
own small JSON reader.

| File | Spec section |
|---|---|
| `src/pack.cpp` | Pack (`parse_pack`, `load_pack`) |
| `src/engine.cpp` | correlate.md: Reports, Frame, Track estimate, Two-model filter (`filter_first`, `filter_update`, `predict`), Tests, Association, Events, Trace, Snapshot |
| `src/assign.cpp` | correlate-assign.md: Memberships, Ranking (`rank_assignments`, brute force over every assignment), Assignment of one source (`rank_source`, `apply_assignment`), Window (`tick_assign`, steps 1 to 5), Snapshot |
| `src/common.hpp` | helpers both files use |
| `src/json.cpp` | JSON values for reports, events, trace and snapshot |
| `test/run_vectors.cpp` | the comparison in `spec/vector-format.md` |

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
`spec/correlate-load-vectors/`. `run_vectors` prints `PASS` or `FAIL` for each vector, and for a
failure the path of the first mismatch, for example
`steps[1].trace[0].value: number differs (...)`. You can also run it by hand:

```sh
build/cpp/run_vectors .
```

The build passes `-ffp-contract=off` (and `-msse2 -mfpmath=sse` on x86), so
no `a*b + c` becomes a fused multiply-add and no intermediate is kept in
extended precision (correlate.md "Floats").

Where the specification leaves room for more than one reading, the reading
this engine takes is in `DISAGREEMENTS.md`.
