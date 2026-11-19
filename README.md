# goat-processors

goat-processors holds the functions that work on data once it has been
translated: correlation, fusion, filtering, and quality measurement with the
actions that follow from it. [goat-transformers](https://github.com/USAREUR-AF/goat-transformers)
is the layer beneath it, translating messages between formats into one shared
model; goat-processors reads that model.

| Function | Status |
|---|---|
| correlate | Written (specification 0.4) and built in seven languages |
| correlate, method assign | Written (specification 0.2) and built in seven languages |
| filter | Written (specification 0.1), built in Python |
| fuse, quality | Designed, not built ([spec/README.md](spec/README.md)) |

Every decision is explainable from the output. Each test a function runs is a
trace record naming the inputs, the value computed, the limit and the result,
and `snapshot()` returns the whole state, including each track's filter. The
functions are deterministic: their only clock is the time in their input, so
replaying the same input gives the same output and trace in every language.

## Layout

| Path | What |
|---|---|
| `spec/` | one specification per function, the shared vector format, load vectors |
| `packs/<function>-<name>/pack.def` | a rule set: which tests run, with which parameters |
| `packs/<function>-<name>/vectors/` | scenarios with their exact expected events, trace and final state |
| `engines/<language>/` | one independent engine per language: Python, Rust, Go, Java, C++, Erlang, Zig |
| `tools/make-vectors.py` | the scenarios, with their decisions stated by hand |

## Correlate packs

| Pack | Gate | Use |
|---|---|---|
| `correlate-gnn` | method confirm: the reported track inside the other track's predicted 99 % uncertainty region | sources that report position error |
| `correlate-window` | distance below a window that grows with both tracks' error, in the shape of the Link 16 correlation window | sources with coarse or fixed error |
| `correlate-distance` | plain distance; same-source pairs allowed; output follows the latest report | feeds that report no error |
| `correlate-assign` | method assign: least-cost assignment to system tracks, fused by uncertainty weight | a complete picture, one track per object |

## Running the vectors

| Engine | Command |
|---|---|
| Python | `cd engines/python && PYTHONPATH=src python3 -m unittest discover -s tests` |
| Rust | `cd engines/rust && cargo test` |
| Go | `cd engines/go && go test ./...` |
| Java | `engines/java/build.sh` |
| C++ | `cmake -S engines/cpp -B build/cpp && cmake --build build/cpp && ctest --test-dir build/cpp --output-on-failure` |
| Erlang | `engines/erlang/run_tests` |
| Zig | `cd engines/zig && zig build test` |
