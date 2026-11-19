# goat-correlator, zig engine

An implementation of `spec/correlate.md` (version 0.5, method `confirm`, with
the two-model filter) and `spec/correlate-assign.md` (version 0.3, method
`assign`, with the multi-frame window) in Zig 0.13.0,
standard library only. It was written from the specifications and the vectors,
not from another engine. Points the specifications leave open, and how this
engine decides them, are in `DISAGREEMENTS.md`.

| File | Spec section |
|---|---|
| `src/pack.zig` | Pack (`load_pack`, `pack.def` parsing and load errors) |
| `src/frame.zig` | Frame |
| `src/kalman.zig` | Track estimate (and the update terms used by the two-model filter) |
| `src/imm.zig` | Two-model filter: switching, mixing, likelihood, mode probabilities, combination, prediction |
| `src/entity.zig` | Reports (entity state, `@env`) |
| `src/pair_tests.zig` | Tests |
| `src/engine.zig` | Association, Events, Trace, Snapshot (`ingest`, `tick`, `snapshot`); dispatches on the pack's `method` |
| `src/assign.zig` | `correlate-assign.md`: Memberships, Assignment of one source, Ranking (brute-force enumeration, sorted by total then choice vector), Window, Events, Trace, Snapshot |
| `src/compare.zig` | `spec/vector-format.md`, structural comparison |
| `src/vectors_test.zig` | runs the load vectors and the scenario vectors |

## Floats

Zig's default float mode is strict: no fused multiply-add contraction and no
extended precision (binary64 on SSE2), as `correlate.md` "Floats" requires.
No file sets `@setFloatMode(.optimized)`.

## Build and run the vectors

```
cd engines/zig
zig build test
```

This runs every load vector in `spec/correlate-load-vectors/` and every scenario vector
in `packs/correlate-*/vectors/`: each step's events and trace, then the final snapshot.
It prints a count per kind and, for a vector that fails, the path of the first
mismatch, for example
`01-two-sources-one-object.steps[1].trace[0].value`.

The directories default to `../../packs` and `../../spec/correlate-load-vectors`
relative to this directory. Override them with
`zig build test -Dpacks=<dir> -Dload-vectors=<dir>`.
