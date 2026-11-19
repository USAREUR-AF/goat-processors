# goat-processors, zig engine

An implementation of `spec/correlate.md` (version 0.4, method `confirm`),
`spec/correlate-assign.md` (version 0.2, method `assign`) and
`spec/quality.md` (version 0.1) in Zig 0.13.0, standard library only. It was written from the specifications and the vectors,
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
| `src/vector_files.zig` | finds and reads vector files, shared by both runners |
| `src/vectors_test.zig` | runs the correlate load vectors and the `packs/correlate-*` vectors |

Quality (`spec/quality.md`) reuses `frame.zig` (Frame), `kalman.zig` (Track
estimate), the `filter` type of `pack.zig` and the key readers of `entity.zig`:

| File | Spec section |
|---|---|
| `src/quality_pack.zig` | Pack, Rules (the rule line, `Op` with its condition and clear test) |
| `src/quality_measures.zig` | Order, the record of Samples, Window, Entity measures, Source measures |
| `src/quality.zig` | Reports, Order, Frame and filter, Samples, Rules (evaluation, actions), Forwarding, Tick, Ingest, Events, Trace, Snapshot |
| `src/quality_vectors_test.zig` | runs `spec/quality-load-vectors/` and the `packs/quality-*` vectors |

## Build and run the vectors

```
cd engines/zig
zig build test
```

This runs every load vector in `spec/correlate-load-vectors/` and every
scenario vector in `packs/correlate-*/vectors/`, then every load vector in
`spec/quality-load-vectors/` and every scenario vector in
`packs/quality-*/vectors/`: each step's events and trace, then the final
snapshot.
It prints a count per kind and, for a vector that fails, the path of the first
mismatch, for example
`01-two-sources-one-object.steps[1].trace[0].value`.

The directories default to `../../packs`, `../../spec/correlate-load-vectors`
and `../../spec/quality-load-vectors` relative to this directory. Override
them with
`zig build test -Dpacks=<dir> -Dload-vectors=<dir> -Dquality-load-vectors=<dir>`.
