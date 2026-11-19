# goat-correlator: java engine

An implementation of `spec/correlate.md` (version 0.5) and `spec/correlate-assign.md`
(version 0.3) in Java 17, using only the standard library. It was written from
the specification and the vectors, without reading any other engine.

| File | Spec section |
|---|---|
| `src/correlator/Pack.java` | Pack (`load_pack`, the `pack.def` parser, `method`, `manoeuvre`, `window`, `hypotheses` and the directives each method allows) |
| `src/correlator/Filter.java` | Track estimate (predict, position and velocity update, prediction) and Two-model filter (switching, mixing, per-model update, likelihood, mode probabilities, combination) |
| `src/correlator/Engine.java` | Reports, Frame, Tests, Association, Events, Trace, Snapshot for method `confirm` (`ingest`, `tick`, `snapshot`); the two-model filter trace records; the `retiring` reject |
| `src/correlator/Assign.java` | correlate-assign.md: Memberships, Assignment of one source (columns, entries, fused estimate, cost, apply), Ranking, Window (staleness and retiring, rows, sources over histories, commit, output), its trace and snapshot |
| `src/correlator/Json.java` | the JSON reader and writer the vector test uses |
| `src/correlator/VectorTest.java` | `spec/vector-format.md`: runs every vector and compares the results structurally |

## Build and run the vectors

```
engines/java/build.sh
```

The script compiles with `javac --release 17` into `engines/java/build/`. It
then runs every load vector in `spec/correlate-load-vectors/` and every scenario
vector in `packs/correlate-*/vectors/`. For a scenario vector it checks each
step's events and trace, then the final snapshot. A failing vector prints the
path of its first mismatch, for example
`steps[1].trace[0].value: got 0.2777765689606809, want 0.2778`. The script
exits non-zero when any vector fails.

The pack's `method` line selects which method the engine runs: `confirm` (or no
line) runs `correlate.md`, `assign` runs `correlate-assign.md`.

Floats: Java evaluates every `double` operation as one correctly rounded
binary64 operation (strict semantics since Java 17) and never contracts into a
fused multiply-add; the code calls no `Math.fma`.

Ranked assignments are found by enumerating every assignment of the source's
rows (column or *alone*, each column at most once, no forbidden entry) in
ascending choice-vector order, then a stable sort by total, which is the
Ranking order exactly. This is brute force, which is fine at vector sizes.

No vector contradicts either specification, so there is no `DISAGREEMENTS.md`.
