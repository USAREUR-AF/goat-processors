# goat-processors: java engine

An implementation of `spec/correlate.md` (version 0.4) and `spec/correlate-assign.md`
(version 0.2) in Java 17, using only the
standard library. It was written from the specification and the vectors,
without reading any other engine.

| File | Spec section |
|---|---|
| `src/correlator/Pack.java` | Pack (`load_pack`, the `pack.def` parser, `method` and the directives each method allows) |
| `src/correlator/Engine.java` | Frame, Track estimate, Tests, Association, Events, Trace, Snapshot (`ingest`, `tick`, `snapshot`); the section "method assign" holds correlate-assign.md: fused estimate, cost, per-source assignment (Hungarian method with potentials), its events, trace and snapshot |
| `src/correlator/Json.java` | the JSON reader and writer the vector test uses |
| `src/correlator/VectorTest.java` | `spec/vector-format.md`: runs every vector and compares the results structurally |

## Build and run the vectors

```
engines/java/build.sh
```

The script compiles with `javac --release 17` into `engines/java/build/`. It
then runs every load vector in `spec/correlate-load-vectors/` and every scenario vector
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

## Quality

`src/quality/` implements `spec/quality.md` (version 0.1) as its own package,
written from that specification, the sections of `correlate.md` it cites and the
vectors. It reuses this engine's correlate code for those sections: the frame
(`correlator.Engine.toPlane`) and the constant-velocity filter
(`correlator.Engine.Axis`).

| File | Spec section |
|---|---|
| `src/quality/Pack.java` | Pack (the `pack.def` parser, every load error of its table), Rules (`op` and `clear` tests) |
| `src/quality/Engine.java` | Reports, Order, Frame and filter, Samples, Ingest, Forwarding (`ingest`); Tick, Window, Entity measures, Source measures, Rules, Events, Trace (`tick`); Snapshot |
| `src/quality/VectorTest.java` | runs `spec/quality-load-vectors/` and `packs/quality-*/vectors/` with the comparison of `spec/vector-format.md` |

`build.sh` runs both runners: `correlator.VectorTest` reads only
`packs/correlate-*`, `quality.VectorTest` only `packs/quality-*`. No quality
vector contradicts the specification; the open points of `quality.md` are not
decided by any vector, and this engine does not special-case them.
