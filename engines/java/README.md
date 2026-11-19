# goat-processors: java engine

An implementation of `spec/correlate.md` (version 0.4), `spec/correlate-assign.md`
(version 0.2) and `spec/fuse.md` (version 0.1) in Java 17, using only the
standard library. It was written from the specification and the vectors,
without reading any other engine.

| File | Spec section |
|---|---|
| `src/correlator/Pack.java` | Pack (`load_pack`, the `pack.def` parser, `method` and the directives each method allows) |
| `src/correlator/Engine.java` | Frame, Track estimate, Tests, Association, Events, Trace, Snapshot (`ingest`, `tick`, `snapshot`); the section "method assign" holds correlate-assign.md: fused estimate, cost, per-source assignment (Hungarian method with potentials), its events, trace and snapshot |
| `src/correlator/Json.java` | the JSON reader and writer the vector test uses |
| `src/correlator/VectorTest.java` | `spec/vector-format.md`: runs every correlate vector and compares the results structurally |
| `src/fuse/FusePack.java` | fuse.md, Pack (`load_pack`, the `pack.def` parser) |
| `src/fuse/Fuse.java` | fuse.md, Reports, Groups, On each tick, Fused event, Kinematics, Attributes, Events, Trace, Snapshot; it reuses the correlate engine's `Axis` filter, Frame conversions and inverse-variance estimate, which fuse.md cites |
| `src/fuse/FuseVectorTest.java` | runs every fuse vector with the comparison of `VectorTest` |

## Build and run the vectors

```
engines/java/build.sh
```

The script compiles with `javac --release 17` into `engines/java/build/`. It
then runs the correlate vectors and then the fuse vectors, and prints one
summary line for each.

Correlate: every load vector in `spec/correlate-load-vectors/` and every scenario vector
in `packs/*/vectors/` (`correlate-assign`, `correlate-distance`, `correlate-gnn`, `correlate-window`). For a scenario vector it checks each step's events and
trace, then the final snapshot. A failing vector prints the path of its first
mismatch, for example
`steps[1].trace[0].value: got 0.2777765689606809, want 0.2778`. The script
exits non-zero when any vector fails.

The pack's `method` line selects which method the engine runs: `confirm` (or no
line) runs `correlate.md`, `assign` runs `correlate-assign.md`. No vector
contradicts either specification, and neither leaves a point open for this
engine. On a tie in the least total cost, which `correlate-assign.md` 0.2
leaves undefined, the Hungarian method's result stands (rows in key order;
columns in creation order, then each row's `alone`).

Fuse: every load vector in `spec/fuse-load-vectors/` and every scenario vector
in `packs/fuse-*/vectors/` (`fuse-best`, `fuse-independent`, `fuse-latest`,
`fuse-priority`, `fuse-shared`), with the same comparison and the same
first-mismatch path. No fuse vector contradicts `spec/fuse.md`. On its two open
points this engine compares two integer attribute values exactly and any other
pair of numbers as binary64, and an integer literal outside the signed 64-bit
range is read as a binary64 number.
