# goat-processors, zig engine

An implementation of `spec/correlate.md` (version 0.5, method `confirm`, with
the two-model filter), `spec/correlate-assign.md` (version 0.3, method
`assign`, with the multi-frame window), `spec/filter.md` (version 0.1) and
`spec/quality.md` (version 0.1) in Zig 0.13.0, standard library only. It also
implements `spec/fuse.md` (version 0.1), the function fuse, as its own module
that reuses the correlate Frame, Track estimate and report helpers. It was
written from the specifications and the vectors,
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
| `src/fuse_pack.zig` | `fuse.md` Pack (fuse `pack.def` parsing and load errors) |
| `src/fuse_kinematics.zig` | `fuse.md` Kinematics (inverse variance, covariance-intersection weight and fold, position variance) |
| `src/fuse.zig` | `fuse.md` Reports (normalised report), Groups, On each tick, Fused event, Attributes, Events, Trace, Snapshot |
| `src/fuse_vectors_test.zig` | runs `spec/fuse-load-vectors/` and `packs/fuse-*/vectors/` |
| `src/compare.zig` | `spec/vector-format.md`, structural comparison |
| `src/vector_files.zig` | finds and reads vector files, shared by the runners |
| `src/vectors_test.zig` | runs the correlate load vectors and the `packs/correlate-*` scenario vectors |
| `src/filter_pack.zig` | `filter.md` Pack (`load_pack`, parameter sets, values, load errors) |
| `src/filter_geo.zig` | `filter.md` Geometry (distance, polygon, reference prediction); reuses `frame.zig`'s `R`, `rad`, `deg`, `wrap` |
| `src/filter.zig` | `filter.md` Reports, Conditions, Rules, Tick, Events, Trace, Snapshot; reads reports with `entity.zig`'s correlate key readers |
| `src/filter_vectors_test.zig` | runs `spec/filter-load-vectors/` and the `packs/filter-*` scenario vectors |

Quality (`spec/quality.md`) reuses `frame.zig` (Frame), `kalman.zig` (Track
estimate), the `filter` type of `pack.zig` and the key readers of `entity.zig`:

| File | Spec section |
|---|---|
| `src/quality_pack.zig` | Pack, Rules (the rule line, `Op` with its condition and clear test) |
| `src/quality_measures.zig` | Order, the record of Samples, Window, Entity measures, Source measures |
| `src/quality.zig` | Reports, Order, Frame and filter, Samples, Rules (evaluation, actions), Forwarding, Tick, Ingest, Events, Trace, Snapshot |
| `src/quality_vectors_test.zig` | runs `spec/quality-load-vectors/` and the `packs/quality-*` vectors |

## Floats

Zig's default float mode is strict: no fused multiply-add contraction and no
extended precision (binary64 on SSE2), as `correlate.md` "Floats" requires.
No file sets `@setFloatMode(.optimized)`.

## Build and run the vectors

```
cd engines/zig
zig build test
```

This runs every load vector in `spec/correlate-load-vectors/` with every
scenario vector in `packs/correlate-*/vectors/`, every load vector in
`spec/fuse-load-vectors/` with every scenario vector in `packs/fuse-*/vectors/`,
every load vector in `spec/filter-load-vectors/` with every scenario vector
in `packs/filter-*/vectors/`, and every load vector in
`spec/quality-load-vectors/` with every scenario vector in
`packs/quality-*/vectors/`: each step's events and trace, then the final snapshot.
It prints a count per kind and, for a vector that fails, the path of the first
mismatch, for example
`01-two-sources-one-object.steps[1].trace[0].value`.

The directories default to `../../packs`, `../../spec/correlate-load-vectors`,
`../../spec/fuse-load-vectors`, `../../spec/filter-load-vectors` and
`../../spec/quality-load-vectors` relative to this directory. Override them with
`zig build test -Dpacks=<dir> -Dload-vectors=<dir> -Dfuse-load-vectors=<dir> -Dfilter-load-vectors=<dir> -Dquality-load-vectors=<dir>`.
