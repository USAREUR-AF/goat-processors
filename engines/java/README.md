# goat-processors: java engine

Java 17, standard library only. Implements

- correlate: `spec/correlate.md` (0.8) and `spec/correlate-assign.md` (0.6);
- filter: `spec/filter.md` (0.1);
- fuse: `spec/fuse.md` (0.2);
- quality: `spec/quality.md` (0.2).

All were written from the specifications and the vectors, without reading any other engine.

## Layout

One package per module, the same modules as every engine: `src/goat/<module>/`.

| Module | Holds |
|---|---|
| `model` | what every function shares about a report and a track: the report rules, the frame, the constant-velocity filter, the two-model filter, the inverse-variance estimate, key order |
| `filter` | the filter function (filter.md) |
| `correlate` | the correlate function (correlate.md): the shared report path, the tests, the method table, and method `confirm` |
| `assign` | correlate method `assign` (correlate-assign.md) |
| `fuse` | the fuse function (fuse.md) |
| `quality` | the quality function (quality.md) |
| `trace` | the result of a call (events, then trace) and the record builders |
| `snapshot` | the pieces every snapshot shares |
| `io` | the JSON reader and writer, pack files, the entry-point shape (`Processor`), the function table (`Functions`), the runner and the vector runner |

"Filter" names two things in the specifications: the filter *function* (filter.md) is the module
`filter`; the track *filter* (correlate.md, Track estimate) is part of `model`.

**Entry point.** Every function has the one shape of `goat.io.Processor`: `load_pack` makes a
processor (`Functions.load(function, dir)`, or `Correlator.load`, `FilterProcessor.load`,
`Fuse.load`, `Quality.load`), then `ingest(report)` and `tick(now_ms)` each return a `Result`
(its `events`, then its `trace` records), and `snapshot()` gives the state. The runner and the
vector runner call nothing else.

The four classes `correlator.VectorTest`, `filter.VectorTest`, `fuse.FuseVectorTest` and
`quality.VectorTest` only call `goat.io.Vectors`: they keep the names the perf harness runs.

## Where each spec section lives

### correlate.md

| Section | File |
|---|---|
| What the correlator does | `correlate/Correlator.java` |
| Reports | `model/Report.java` |
| Reports, Time quality | `model/Report.java` |
| Frame | `model/Frame.java` |
| Track estimate | `model/TrackEstimate.java` (one axis: `model/Axis.java`; measurement variance: `correlate/Correlator.java`) |
| Two-model filter | `model/TrackEstimate.java` |
| Restart | `correlate/Correlator.java` |
| Tests | `correlate/Tests.java` (the registry: `correlate/Registry.java`, `correlate/TestKind.java`) |
| Association | `correlate/Confirm.java` |
| Events | `correlate/Confirm.java` |
| Trace | `correlate/Tests.java` |
| Snapshot | `correlate/Confirm.java` |
| Pack | `correlate/CorrelatePack.java` (directives: `correlate/Directive.java`; method directives: `Confirm.KIND`, `Assign.KIND`) |
| Floats | `model/Axis.java` |

### correlate-assign.md

| Section | File |
|---|---|
| What this method does | `assign/Assign.java` |
| Shared with `correlate.md` | `correlate/Correlator.java` |
| Memberships | `assign/Membership.java` |
| Assignment of one source | `assign/Assign.java` |
| Sensor bias | `assign/Bias.java` |
| Ranking | `assign/Ranking.java` |
| Window | `assign/History.java` (records: `assign/Record.java`; the tick: `assign/Assign.java`) |
| Events | `assign/Membership.java` |
| Trace | `assign/Assign.java` |
| Snapshot | `assign/Assign.java` |
| Pack | `correlate/CorrelatePack.java` |

### filter.md

| Section | File |
|---|---|
| What the filter does | `filter/FilterProcessor.java` |
| Reports | `model/Report.java` |
| Geometry | `filter/Geometry.java` |
| Conditions | `filter/Condition.java` (evaluation: `filter/FilterProcessor.java`) |
| Rules | `filter/FilterProcessor.java` |
| Tick | `filter/FilterProcessor.java` |
| Events | `filter/FilterProcessor.java` |
| Trace | `filter/FilterProcessor.java` |
| Snapshot | `filter/FilterProcessor.java` |
| Pack | `filter/FilterPack.java` |

### fuse.md

| Section | File |
|---|---|
| What fuse does | `fuse/Fuse.java` |
| Shared with `correlate.md` | `model/` |
| Reports | `fuse/Fuse.java` |
| Groups | `fuse/Fuse.java` |
| On each tick, Fused event | `fuse/Fuse.java` |
| Kinematics | `fuse/Kinematics.java` |
| Attributes | `fuse/Fuse.java` |
| Events, Trace, Snapshot | `fuse/Fuse.java` |
| Pack | `fuse/FusePack.java` |

### quality.md

| Section | File |
|---|---|
| What quality does | `quality/Quality.java` |
| Reports, Time quality | `model/Report.java` |
| Order, Frame and filter, Input clock, Samples, Ingest, Forwarding | `quality/Quality.java` |
| Window, Rules, Tick | `quality/Quality.java` |
| Samples (the record of one report) | `quality/Record.java` |
| Entity measures, Source measures | `quality/Measures.java` |
| Events, Trace, Snapshot | `quality/Quality.java` |
| Pack | `quality/QualityPack.java` |

### vector-format.md

| Section | File |
|---|---|
| Scenario vectors, What the engine checks, Load vectors | `io/Vectors.java` |

## Registration points

Each extension kind is added in one place: one table entry, or one registration from outside.

| Kind | Where | Add one by |
|---|---|---|
| correlate test | `correlate/Tests.java`, `Tests.STANDARD` (a `TestKind`: name, parameters, formula) | one entry, or `Registry.STANDARD.withTest(kind)` |
| correlate method | `correlate/Registry.java` (a `MethodKind`: name, factory, its own directives, required directives, end checks) | one `withMethod(kind)`; `Confirm.KIND` and `Assign.KIND` are the two |
| quality measure | `quality/Measures.java`, `Measures.STANDARD` (name, value over the window, source aggregate) | one entry, or `Measures.STANDARD.with(measure)` |
| fuse kinematics method | `fuse/Kinematics.java`, `Kinematics.TABLE` | one entry |
| function | `io/Functions.java` | one entry |

The pack parsers read against a registry (`CorrelatePack.parse(text, registry)`,
`QualityPack.parse(text, measures)`), so a test can add an entry without any global state: the
registries are immutable values and `with...` returns a new one.

The proof is `test/goat/correlate/NoopTestKindTest.java`: it registers a test kind `noop` (no
parameter, always passes, one trace record) in test code only, against the test-only fixture pack
`test/fixtures/correlate-noop/pack.def` (`correlate-assign` plus `gate noop`). The standard
registry refuses that pack (unknown test), so no existing vector can see it; with the noop
registered, every `correlate-assign` vector gives the same events and snapshot and the same trace
less the noop records; and the fixture's own vector, `test/fixtures/correlate-noop/vectors/01-noop-gate.json`, passes.

## Pure functions and state

The math is pure functions of values: `model/Axis` is immutable and every filter step returns a
new axis; `model/TrackEstimate` returns the next estimate from `update`; gating
(`correlate/Tests`), the assign cost (`Assign.cost`), ranking (`assign/Ranking`), the sensor bias
fit (`Bias.d2`, `Bias.accept`, `Bias.fitTimeOffset`), the fuse weight and fold
(`fuse/Kinematics`), the quality measures (`quality/Measures`) and the input clock
(`Quality.median`) read their arguments and change nothing. State lives only in each
processor object (and the method object it holds) and is read out by `snapshot()`. There is no
mutable static field anywhere in the engine.

## Performance notes

- Ranking (correlate-assign.md) is a branch-and-bound walk in the definition's own order
  (`assign/Ranking.rank`): it keeps the k best so far and skips a branch only when a lower bound
  on every total in it exceeds the k-th best by more than rounding could close; kept totals are
  computed as the definition computes them. `Ranking.rankAll` is the definition (every
  assignment, stable sort), used when an entry is not finite and by the tests as the oracle.
- Key order (`model/KeyOrder`) compares UTF-16 units and decodes code points only when a
  surrogate is at the first difference.
- Events, trace records and parsed JSON objects are `trace/Fields`, an insertion-ordered map in
  arrays; the JSON reader takes strings without escapes and integers of up to 18 digits without
  copying; the vector comparison walks two maps in step when their keys come in the same order.
- Quality keeps each source's latest time instead of rescanning every entity per report.

## Open points

No vector contradicts any specification, so there is no `DISAGREEMENTS.md`. On the open points:
a report integer outside the signed 64-bit range is read as a binary64 (so it is not an
integer); integers above 2^53 compare as their nearest binary64, except that fuse compares two
integer attribute values exactly; near a pole the filter's reference prediction divides by
`cos(rad(lat))` as written.

Floats: Java evaluates every `double` operation as one correctly rounded binary64 operation
(strict semantics since Java 17) and never contracts into a fused multiply-add; the code calls no
`Math.fma`.

## Tests

`test/` holds the engine's own tests, run by `goat.TestMain` (standard library only: every
`public static void test*()` of the listed classes); `build.sh` runs them before the vectors.

| Kind | Where |
|---|---|
| unit, per module | `test/goat/<module>/*Test.java`: model, trace and snapshot, io (JSON, function table, steps, comparison, runner contract), filter, correlate, assign, fuse, quality |
| registration point | `test/goat/correlate/NoopTestKindTest.java` (above) |
| property: determinism | `PropertyTest`: every scenario vector twice, and every pack on a seeded random scenario twice, byte for byte |
| property: order independence | `PropertyTest`: a report's key order (a JSON object); correlate's once-only directives (correlate.md, Pack); filter's directives other than its rules (filter.md, Pack) |
| property: snapshot then restore | none: this engine has no restore, as no specification defines reading a snapshot back |
| fuzzing | `FuzzTest`: the JSON reader (round trip of seeded random values; mutated vector files and random text) and the four pack.def readers (mutated packs and load vectors). Each must accept or refuse with its own error, the same way twice. Seeded (`goat.testkit.Rng`, xorshift64*), at least 200 cases and at most 4 s per test; `-Dgoat.fuzz.cases=N` runs longer |

**Coverage.** Java has no line coverage in the JDK without a third-party package (JaCoCo is
one), so `test/goat/coverage/Coverage.java` measures it with the JDK's own debugger interface,
`jdk.jdi`: a breakpoint on every line of every class of `src/` (the lines of the class files'
line tables), counted when hit by the tests or any conformance vector. `coverage.sh` runs it and
fails below the floor; CI runs it in the java job. Baseline (the engine before the refactor,
commit 407a295, under the conformance vectors, its only tests then): 96.6 % (2,654 of 2,748
lines). Floor: max(96.6 %, 80 %) = 96.6 %. The per-file report is `build-test/coverage.tsv`.

## Build, test, run

```
engines/java/build.sh          # compile src/ and test/, the tests (goat.TestMain), then every conformance vector
engines/java/coverage.sh       # line coverage of tests and vectors; fails below 96.6 %
engines/java/runner/build      # the perf runner (tools/perf/README.md, Runner contract)
engines/java/runner/run --function correlate --pack packs/correlate-gnn --steps <file> [--events <file>] [--trace]
```
