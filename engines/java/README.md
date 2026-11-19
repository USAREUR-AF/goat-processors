# goat-correlator: java engine

An implementation of `spec/correlate.md` (version 0.2) in Java 17, using only the
standard library. It was written from the specification and the vectors,
without reading any other engine.

| File | Spec section |
|---|---|
| `src/correlator/Pack.java` | Pack (`load_pack`, the `pack.def` parser) |
| `src/correlator/Engine.java` | Frame, Track estimate, Tests, Association, Events, Trace, Snapshot (`ingest`, `tick`, `snapshot`) |
| `src/correlator/Json.java` | the JSON reader and writer the vector test uses |
| `src/correlator/VectorTest.java` | `spec/vector-format.md`: runs every vector and compares the results structurally |

## Build and run the vectors

```
engines/java/build.sh
```

The script compiles with `javac --release 17` into `engines/java/build/`. It
then runs every load vector in `spec/correlate-load-vectors/` and every scenario vector
in `packs/*/vectors/` (`correlate-gnn`, `correlate-window`, `correlate-distance`). For a scenario vector it checks each step's events and
trace, then the final snapshot. A failing vector prints the path of its first
mismatch, for example
`steps[1].trace[0].value: got 0.2777765689606809, want 0.2778`. The script
exits non-zero when any vector fails.

`DISAGREEMENTS.md` lists the points where the spec is open, with the reading
this engine takes on each.
