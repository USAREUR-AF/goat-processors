# goat-processors, zig engine

An implementation of `spec/correlate.md` (version 0.8, method `confirm`, with
the two-model filter, the filter restart and the time quality of a report),
`spec/correlate-assign.md` (version 0.6, method `assign`, with the multi-frame
window and its margin, the filter restart, the sensor bias and its clock
offset), `spec/filter.md` (version 0.1) and
`spec/quality.md` (version 0.2, with time quality) in Zig 0.13.0, standard library only. It also
implements `spec/fuse.md` (version 0.2), the function fuse, as its own module
that reuses the correlate Frame, Track estimate and report helpers. It was
written from the specifications and the vectors,
not from another engine. Points the specifications leave open, and how this
engine decides them, are in `DISAGREEMENTS.md`.

| File | Spec section |
|---|---|
| `src/pack.zig` | Pack (`load_pack`, `pack.def` parsing and load errors) |
| `src/frame.zig` | Frame |
| `src/kalman.zig` | Track estimate: first report, predict, position update with the per-axis measurement variance, velocity update (and the update terms used by the two-model filter) |
| `src/imm.zig` | Two-model filter: switching, mixing, likelihood, mode probabilities, combination, prediction |
| `src/entity.zig` | Reports (entity state, `@env`, Time quality: `time_error_ms`, `time_state`, `time_default`); the entity's measurement variance and timing variance, and its prediction for a comparison (Track estimate) |
| `src/pair_tests.zig` | Tests |
| `src/engine.zig` | Track estimate, Measurement variance (and its `time` record), Restart, Association, Events, Trace, Snapshot (`ingest`, `tick`, `snapshot`); dispatches on the pack's `method` |
| `src/assign.zig` | `correlate-assign.md`: Memberships, Assignment of one source, Ranking (brute-force enumeration, sorted by total then choice vector), Window (with `margin` and the leave of a restarted entity), Events, Trace, Snapshot |
| `src/bias.zig` | `correlate-assign.md` Sensor bias: State, Moving B into A's frame, Update steps 1 to 3, Time offset (the fit of `y = o - v*tau`) (called from `engine.zig`'s tests, `assign.zig`'s Cost and Window step 5) |
| `src/fuse_pack.zig` | `fuse.md` Pack (fuse `pack.def` parsing and load errors) |
| `src/fuse_kinematics.zig` | `fuse.md` Kinematics (inverse variance, covariance-intersection weight and fold, position variance) |
| `src/fuse.zig` | `fuse.md` Reports (normalized report), Groups, On each tick, Fused event, Attributes, Events, Trace, Snapshot |
| `src/fuse_vectors_test.zig` | runs `spec/fuse-load-vectors/` and `packs/fuse-*/vectors/` |
| `src/compare.zig` | `spec/vector-format.md`, structural comparison |
| `src/vector_files.zig` | finds and reads vector files, shared by the runners |
| `src/vectors_test.zig` | runs the correlate load vectors and the `packs/correlate-*` scenario vectors |
| `src/filter_pack.zig` | `filter.md` Pack (`load_pack`, parameter sets, values, load errors) |
| `src/filter_geo.zig` | `filter.md` Geometry (distance, polygon, reference prediction); reuses `frame.zig`'s `R`, `rad`, `deg`, `wrap` |
| `src/filter.zig` | `filter.md` Reports, Conditions, Rules, Tick, Events, Trace, Snapshot; reads reports with `entity.zig`'s correlate key readers |
| `src/filter_vectors_test.zig` | runs `spec/filter-load-vectors/` and the `packs/filter-*` scenario vectors |

Quality (`spec/quality.md` 0.2) reuses `frame.zig` (Frame), `kalman.zig` (Track
estimate), the `filter`, `TimeState` and `TimeDefault` types of `pack.zig`, and
the key readers of `entity.zig`, among them the reading of a report's own
`time_error_ms` and `time_state` (correlate.md 0.8, Time quality, step 1):

| File | Spec section |
|---|---|
| `src/quality_pack.zig` | Pack (line ends, control characters, `time_default` with quality's number grammar), Rules (the rule line, `Op` with its condition and clear test), the time state codes |
| `src/quality_measures.zig` | Order, the record of Samples, Window, Entity measures, Source measures |
| `src/quality.zig` | Reports (Time quality, steps 2 and 3), Order, Frame and filter, Input clock, Samples, Rules (evaluation, actions), Forwarding, Tick, Ingest, Events, Trace, Snapshot |
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
