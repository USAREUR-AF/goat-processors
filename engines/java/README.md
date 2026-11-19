# goat-processors: java engine

Implementations, in Java 17 with only the standard library, of

- the correlator: `spec/correlate.md` (version 0.5) and `spec/correlate-assign.md` (version 0.3), package `correlator`;
- the filter: `spec/filter.md` (version 0.1), package `filter`;
- the fuser: `spec/fuse.md` (version 0.1), package `fuse`;
- quality: `spec/quality.md` (version 0.1), package `quality`.

All were written from the specifications and the vectors, without reading any other engine.

## Correlator (`src/correlator/`)

| File | Spec section |
|---|---|
| `Pack.java` | Pack (`load_pack`, the `pack.def` parser, `method`, `manoeuvre`, `window`, `hypotheses` and the directives each method allows) |
| `Filter.java` | Track estimate (predict, position and velocity update, prediction; fuse and quality reuse its `Axis`) and Two-model filter (switching, mixing, per-model update, likelihood, mode probabilities, combination) |
| `Engine.java` | Reports, Frame, Tests, Association, Events, Trace, Snapshot for method `confirm` (`ingest`, `tick`, `snapshot`); the two-model filter trace records; the `retiring` reject |
| `Assign.java` | correlate-assign.md: Memberships, Assignment of one source (columns, entries, fused estimate, cost, apply), Ranking, Window (staleness and retiring, rows, sources over histories, commit, output), its trace and snapshot; the inverse-variance combination is `Engine.inverseVariance`, which fuse reuses |
| `Json.java` | the JSON reader and writer the vector test uses |
| `Reports.java` | Reports: required keys and their check order, the optional-key rules, the entity key and key order. The filter uses it too, as filter.md Reports cites that section |
| `VectorTest.java` | `spec/vector-format.md` for the correlator: `spec/correlate-load-vectors/` and `packs/correlate-*` only; also holds the structural comparison the other tests use |

The pack's `method` line selects which method the engine runs: `confirm` (or no
line) runs `correlate.md`, `assign` runs `correlate-assign.md`.

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

## Fuse (`src/fuse/`)

| File | Spec section |
|---|---|
| `FusePack.java` | fuse.md, Pack (`load_pack`, the `pack.def` parser) |
| `Fuse.java` | fuse.md, Reports, Groups, On each tick, Fused event, Kinematics, Attributes, Events, Trace, Snapshot; it reuses the correlate engine's `Axis` filter, Frame conversions and inverse-variance estimate, which fuse.md cites |
| `FuseVectorTest.java` | `spec/vector-format.md` for the fuser: `spec/fuse-load-vectors/` and `packs/fuse-*`, with the comparison of `correlator.VectorTest` |

No fuse vector contradicts `spec/fuse.md`. On its two open points this engine
compares two integer attribute values exactly and any other pair of numbers as
binary64, and an integer literal outside the signed 64-bit range is read as a
binary64 number.

## Quality (`src/quality/`)

`src/quality/` implements `spec/quality.md` (version 0.1) as its own package,
written from that specification, the sections of `correlate.md` it cites and the
vectors. It reuses this engine's correlate code for those sections: the frame
(`correlator.Engine.toPlane`) and the constant-velocity filter
(`correlator.Filter.Axis`).

| File | Spec section |
|---|---|
| `Pack.java` | Pack (the `pack.def` parser, every load error of its table), Rules (`op` and `clear` tests) |
| `Engine.java` | Reports, Order, Frame and filter, Samples, Ingest, Forwarding (`ingest`); Tick, Window, Entity measures, Source measures, Rules, Events, Trace (`tick`); Snapshot |
| `VectorTest.java` | `spec/vector-format.md` for quality: `spec/quality-load-vectors/` and `packs/quality-*` |

No quality vector contradicts `spec/quality.md`; the open points of
`quality.md` are not decided by any vector, and this engine does not
special-case them.

## Build and run the vectors

```
engines/java/build.sh
```

The script compiles with `javac --release 17 -Xlint:all -Werror` into
`engines/java/build/`, then runs the correlator vectors, the filter vectors, the fuse vectors and the
quality vectors, each with one summary line.
For a scenario vector it checks each step's events and trace, then the final
snapshot. A failing vector prints the path of its first mismatch, for example
`steps[1].trace[0].value: got 0.2777765689606809, want 0.2778`. The script
exits non-zero when any vector fails.

Floats: Java evaluates every `double` operation as one correctly rounded
binary64 operation (strict semantics since Java 17) and never contracts into a
fused multiply-add; the code calls no `Math.fma`.

Ranked assignments are found by enumerating every assignment of the source's
rows (column or *alone*, each column at most once, no forbidden entry) in
ascending choice-vector order, then a stable sort by total, which is the
Ranking order exactly. This is brute force, which is fine at vector sizes.

No vector contradicts `correlate.md` or `correlate-assign.md`, so there is no `DISAGREEMENTS.md`.
