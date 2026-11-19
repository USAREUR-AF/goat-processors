# goat-processors: java engine

Implementations, in Java 17 with only the standard library, of

- the correlator: `spec/correlate.md` (version 0.4) and `spec/correlate-assign.md` (version 0.2), package `correlator`;
- the filter: `spec/filter.md` (version 0.1), package `filter`.

Both were written from the specifications and the vectors, without reading any other engine.

## Correlator (`src/correlator/`)

| File | Spec section |
|---|---|
| `Pack.java` | Pack (`load_pack`, the `pack.def` parser, `method` and the directives each method allows) |
| `Engine.java` | Frame, Track estimate, Tests, Association, Events, Trace, Snapshot (`ingest`, `tick`, `snapshot`); the section "method assign" holds correlate-assign.md: fused estimate, cost, per-source assignment (Hungarian method with potentials), its events, trace and snapshot |
| `Reports.java` | correlate.md Reports: required keys and their check order, the optional-key rules, the entity key and key order. The filter uses it too, as filter.md Reports cites that section |
| `Json.java` | the JSON reader and writer the vector tests use |
| `VectorTest.java` | `spec/vector-format.md` for the correlator: `spec/correlate-load-vectors/` and `packs/correlate-*` only; also holds the structural comparison both tests use |

The pack's `method` line selects which method the engine runs: `confirm` (or no
line) runs `correlate.md`, `assign` runs `correlate-assign.md`. On a tie in the
least total cost, which `correlate-assign.md` 0.2 leaves undefined, the
Hungarian method's result stands (rows in key order; columns in creation order,
then each row's `alone`).

## Filter (`src/filter/`)

| File | Spec section |
|---|---|
| `Pack.java` | Pack: directives, `rule` and `when` lines, Parameter sets, Values |
| `Condition.java` | one `when` line and its parsed parameters |
| `Geometry.java` | Geometry: `wrap`, haversine distance, polygon (boundary, then crossings), reference prediction |
| `Filter.java` | Reports (environment, affiliation; report checks via `correlator.Reports`), Conditions, Rules, Tick, Events, Trace, Snapshot |
| `VectorTest.java` | `spec/vector-format.md` for the filter: `spec/filter-load-vectors/` and `packs/filter-*` |

No filter vector contradicts `spec/filter.md`. On its two open points the
engine does this: a report integer outside the signed 64-bit range is read as
a float (so it is not an integer), and integers above 2^53 compare as their
nearest binary64; near a pole the reference prediction divides by
`cos(rad(lat))` as written.

## Build and run the vectors

```
engines/java/build.sh
```

The script compiles with `javac --release 17 -Xlint:all -Werror` into
`engines/java/build/`, then runs the correlator vectors and the filter vectors.
For a scenario vector it checks each step's events and trace, then the final
snapshot. A failing vector prints the path of its first mismatch, for example
`steps[1].trace[0].value: got 0.2777765689606809, want 0.2778`. The script
exits non-zero when any vector fails.
