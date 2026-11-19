# goat-processors, zig engine

An implementation of `spec/correlate.md` (version 0.4, method `confirm`) and
`spec/correlate-assign.md` (version 0.2, method `assign`), and of
`spec/filter.md` (version 0.1), in Zig 0.13.0,
standard library only. It was written from the specifications and the vectors,
not from another engine. Points the specifications leave open, and how this
engine decides them, are in `DISAGREEMENTS.md`.

| File | Spec section |
|---|---|
| `src/pack.zig` | Pack (`load_pack`, `pack.def` parsing and load errors) |
| `src/frame.zig` | Frame |
| `src/kalman.zig` | Track estimate |
| `src/entity.zig` | Reports (entity state, `@env`) |
| `src/pair_tests.zig` | Tests |
| `src/engine.zig` | Association, Events, Trace, Snapshot (`ingest`, `tick`, `snapshot`); dispatches on the pack's `method` |
| `src/assign.zig` | `correlate-assign.md`: Assignment, fused estimate, Events, Trace, Snapshot |
| `src/hungarian.zig` | exact minimum-cost assignment (Hungarian method with potentials) |
| `src/compare.zig` | `spec/vector-format.md`, structural comparison |
| `src/vector_files.zig` | finds and reads vector files (both functions) |
| `src/vectors_test.zig` | runs the correlate load vectors and the `packs/correlate-*` scenario vectors |
| `src/filter_pack.zig` | `filter.md` Pack (`load_pack`, parameter sets, values, load errors) |
| `src/filter_geo.zig` | `filter.md` Geometry (distance, polygon, reference prediction); reuses `frame.zig`'s `R`, `rad`, `deg`, `wrap` |
| `src/filter.zig` | `filter.md` Reports, Conditions, Rules, Tick, Events, Trace, Snapshot; reads reports with `entity.zig`'s correlate key readers |
| `src/filter_vectors_test.zig` | runs `spec/filter-load-vectors/` and the `packs/filter-*` scenario vectors |

## Build and run the vectors

```
cd engines/zig
zig build test
```

This runs every load vector in `spec/correlate-load-vectors/` with every
scenario vector in `packs/correlate-*/vectors/`, and every load vector in
`spec/filter-load-vectors/` with every scenario vector in
`packs/filter-*/vectors/`: each step's events and trace, then the final snapshot.
It prints a count per kind and, for a vector that fails, the path of the first
mismatch, for example
`01-two-sources-one-object.steps[1].trace[0].value`.

The directories default to `../../packs`, `../../spec/correlate-load-vectors`
and `../../spec/filter-load-vectors` relative to this directory. Override them
with `zig build test -Dpacks=<dir> -Dload-vectors=<dir> -Dfilter-load-vectors=<dir>`.
