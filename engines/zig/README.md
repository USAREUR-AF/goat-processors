# goat-correlator, zig engine

An implementation of `spec/correlator-spec.md` (version 0.1) in Zig 0.13.0,
standard library only. It was written from the specification and the vectors,
not from another engine.

| File | Spec section |
|---|---|
| `src/pack.zig` | Pack (`load_pack`, `pack.def` parsing and load errors) |
| `src/frame.zig` | Frame |
| `src/kalman.zig` | Track estimate |
| `src/entity.zig` | Reports (entity state, `@env`) |
| `src/pair_tests.zig` | Tests |
| `src/engine.zig` | Association, Events, Trace, Snapshot (`ingest`, `tick`, `snapshot`) |
| `src/compare.zig` | `spec/vector-format.md`, structural comparison |
| `src/vectors_test.zig` | runs the load vectors and the scenario vectors |

## Build and run the vectors

```
cd engines/zig
zig build test
```

This runs every load vector in `spec/load-vectors/` and every scenario vector
in `packs/*/vectors/`: each step's events and trace, then the final snapshot.
It prints a count per kind and, for a vector that fails, the path of the first
mismatch, for example
`01-two-sources-one-object.steps[1].trace[0].value`.

The directories default to `../../packs` and `../../spec/load-vectors`
relative to this directory. Override them with
`zig build test -Dpacks=<dir> -Dload-vectors=<dir>`.
