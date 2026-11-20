# Java engine: the refactor

Round brief: `~/inbox/proc/round-refactor.md`. Branch `refactor/java`, from `main` at
407a295. Six steps, one signed commit each, then this page:

| Step | Commit | What |
|---|---|---|
| 1 | `feat(java): runner of the perf runner contract` | `runner/build`, `runner/run` (tools/perf/README.md, Runner contract); then the golden output was recorded |
| 2 | `refactor(java): one module layout` | the nine modules, one entry-point shape, README maps every spec section to a file |
| 3 | `refactor(java): pure functions for the math` | immutable filter state; pure gating, costs, ranking, bias fit, kinematics, measures |
| 4 | `refactor(java): one registration point per extension kind` | registries for tests, methods, measures, kinematics; the no-op test kind |
| 5 | `test(java): unit, property and fuzz tests; line coverage with a floor in CI` | 90 tests, coverage tool, CI floor |
| 6 | `perf(java): the three hot spots of the large scenario, and the vector comparison` | profile, three fixes |

## Layout

`src/goat/<module>/`, one package per module, the same nine modules as every engine:

| Module | Files |
|---|---|
| `model` | `Axis` (one axis of the constant-velocity filter, a value), `TrackEstimate` (one filter or the two-model filter, a value), `FilterParams`, `Measurement`, `Frame`, `Report` (required keys, optional-key rules, entity key, time quality), `KeyOrder`, `InverseVariance` |
| `filter` | `FilterProcessor` (the filter function), `FilterPack`, `Condition`, `Geometry` |
| `correlate` | `Correlator` (the shared report path: reports, frame, measurement variance, restart, filter update), `Tests` (the test table and how a stage runs it), `Registry`, `TestKind`, `MethodKind`, `Directive`, `Method`, `FrameMove`, `Entity`, `Predicted`, `CorrelatePack`, `Confirm` (method confirm, moved unchanged) |
| `assign` | `Assign` (method assign), `Ranking`, `Membership`, `History`, `Record`, `Bias` |
| `fuse` | `Fuse`, `FusePack`, `Kinematics` |
| `quality` | `Quality`, `QualityPack`, `Measures`, `Record` |
| `trace` | `Result` (events, then trace), `Records` (builders), `Fields` (the ordered map events and records are) |
| `snapshot` | `Snapshots` (what every snapshot shares) |
| `io` | `Processor` (the entry-point shape), `Functions` (the function table), `Json`, `PackFile`, `LoadError`, `Steps`, `Runner` (the runner contract), `Vectors` (vector-format.md) |

Every function is a `goat.io.Processor`: `load_pack` makes one (`Functions.load(function, dir)`),
then `ingest(report)` and `tick(now_ms)` each return a `Result` (events, then trace records), and
`snapshot()` gives the state. The runner and the vector runner call nothing else. The four
classes the perf harness and CI run (`correlator.VectorTest`, `filter.VectorTest`,
`fuse.FuseVectorTest`, `quality.VectorTest`) are one-line entry points into `goat.io.Vectors`.
`README.md` maps every section of every spec to the file that implements it.

Left alone, as the round asks (correlate 1.0 replaces them): the confirm pipeline moved into
`correlate/Confirm.java` with its logic unchanged (gate tests, confirm stage, `confirm_count`,
hold and `hold_failures`, `output priority|latest`, fixed staleness); the `window` and `same`
test formulas moved into the test table unchanged. Their only edits are the calls into the new
layout (for example `Predicted.of(e, t)` for `new Predicted(e, t)`).

## Pure functions and state

`model.Axis` is immutable: predict and both updates return a new axis, and the two-model
likelihood terms are their own functions. `TrackEstimate.update` returns the next estimate and
its trace values. Gating (`correlate/Tests`), the assign cost (`Assign.cost`), ranking
(`assign/Ranking`), the sensor-bias d², update and time-offset fit (`Bias.d2`, `Bias.accept`,
`Bias.fitTimeOffset`), the fuse covariance-intersection weight and fold (`fuse/Kinematics`), the
quality measures (`quality/Measures`) and the input-clock median (`Quality.median`) are pure.
State lives in the processor objects (and the method object a correlator holds) and is read out
by `snapshot()`. No mutable static field anywhere: every table is unmodifiable, every registry an
immutable value.

## The registration point

| Kind | One place | Add one by |
|---|---|---|
| correlate test | `correlate/Tests.java`, `Tests.STANDARD`: a `TestKind` (name, parameters, which are text, formula) | one entry, or `Registry.STANDARD.withTest(kind)` |
| correlate method | `correlate/Registry.java`: a `MethodKind` (name, factory, its own directives, required directives, end checks) | one `withMethod(kind)`; `Confirm.KIND` and `Assign.KIND` are the two |
| quality measure | `quality/Measures.java`, `Measures.STANDARD`: name, value over the window, source aggregate | one entry, or `Measures.STANDARD.with(measure)` |
| fuse kinematics | `fuse/Kinematics.java`, the enum `Kinematics.Method` (`TABLE` by name) | one constant |
| function | `io/Functions.java` | one entry |

The pack readers read against a registry (`CorrelatePack.parse(text, registry)`,
`QualityPack.parse(text, measures)`): the directive table of `CorrelatePack` comes from the
registry, so which directives a method owns, which it requires and what it checks at the end are
part of its registration, not code spread through the parser.

**Proof.** `test/goat/correlate/NoopTestKindTest.java` registers a test kind `noop` (no
parameter, always passes, one trace record) in the test code only:
`Registry.STANDARD.withTest(new TestKind("noop", List.of(), ...))`. Its pack is a test-only
fixture, `test/fixtures/correlate-noop/pack.def` (`correlate-assign` plus `gate noop`), not under
`packs/` and not in the spec. Four tests: the standard registry refuses the fixture pack (unknown
test `noop`), so no existing vector can see the kind; with it registered the pack loads and its
parameters are checked like any test's; every `correlate-assign` vector gives the same events and
snapshot, and the same trace less the noop records, with the noop line as without it; and the
fixture's own vector, `test/fixtures/correlate-noop/vectors/01-noop-gate.json`, passes.

## Tests and coverage

`engines/java/build.sh` compiles `src/` and `test/`, runs `goat.TestMain` (90 tests), then every
conformance vector.

| Kind | Tests |
|---|---|
| unit, per module | `ModelTest` (axis steps by hand, two-model filter, frame, course, key order against its definition, report rules, time quality, inverse variance), `TraceTest` (record key order, `Fields` against `LinkedHashMap`, snapshot pieces), `IoTest` (JSON values and errors, function table, steps, comparison, the runner contract), `FilterTest`, `CorrelateTest`, `AssignTest` (ranking order, the branch-and-bound against the definition on 3,000 seeded problems, membership, cost, bias), `FuseTest`, `QualityTest` |
| registration | `NoopTestKindTest` (above) |
| property: determinism | every scenario vector twice, and every pack on a seeded random scenario twice: the same output, byte for byte |
| property: order independence | a report's key order (a JSON object); correlate's once-only directives (correlate.md, Pack: only the repeating directives' order is meaningful); filter's directives other than the rules (filter.md, Pack: "may appear in any order relative to the rules") |
| property: snapshot then restore | not applicable: this engine has no restore, and no spec defines reading a snapshot back |
| fuzzing | `FuzzTest`: the JSON reader (round trip of seeded random values; mutated vector files; random text) and the four pack.def readers (mutated packs and load vectors). Each must accept or refuse with its own error, the same way twice. Seeded generator written in the test (`goat.testkit.Rng`, xorshift64*); bounded: at least 200 cases, at most 4 s per test (1 s per pack reader) |

The JSON fuzzer found one defect: truncated input made the reader throw
`StringIndexOutOfBoundsException` instead of its parse error. Fixed in step 5; valid input reads
as before. The pack fuzzer found none in the four pack readers.

**Coverage.** The JDK has no line coverage without a third-party package (JaCoCo is one), so
`test/goat/coverage/Coverage.java` measures it with the JDK's own debugger interface, `jdk.jdi`:
it launches each command in a VM with a breakpoint on every line of every class of `src/` (the
class files' line tables; a first command loads every class, so untouched classes count), and a
line is covered when any command hits it. `coverage.sh` runs the tests and the four vector
suites under it and fails below the floor; the java job of `.github/workflows/conformance.yml`
runs it (the only workflow change).

| | Lines covered |
|---|---|
| Baseline: the engine at 407a295 under its conformance vectors, its only tests then | 96.6 % (2,654 of 2,748) |
| Floor: max(baseline, 80 %) | 96.6 % |
| Measured after the refactor (tests and vectors) | 97.7 % (2,946 of 3,015) |

## Hot spots

Profiled with JDK Flight Recorder (`-XX:StartFlightRecording`, settings `profile`) on the large
scenario (`perf.py generate --size large`, 18,571 reports, 600 ticks) through the runner, one
run per pack the harness names. The three largest:

| # | Hot spot (share of samples) | Fix | Before | After |
|---|---|---|---|---|
| 1 | `assign/Ranking`: every assignment of a source enumerated, each total sorted and summed, then all sorted (90 % of `correlate-assign-time`) | an exact branch-and-bound in the definition's own order: keeps the k best, skips a branch only when a lower bound on its totals beats the k-th best by more than any rounding (margin (n+2)·2⁻⁵⁰ per unit of magnitude); kept totals are computed as before; non-finite entries fall back to the exhaustive definition, which is also the test oracle (3,000 seeded problems agree) | runner `run_ns`, `correlate-assign-time`: 41.1 s, 45.4 s | 5.1 s, 4.6 s |
| 2 | `model/KeyOrder`: two code-point arrays allocated per comparison, in every TreeMap lookup and insert (20 % of `quality-time`, 4 % of `correlate-assign-time`) | compare UTF-16 units; decode only when a surrogate is at the first difference (property-tested against the definition, surrogates included). With it, quality keeps each source's latest time instead of rescanning every entity per report | `quality-time` 4.5 s, 5.8 s; `correlate-gnn-imm` 1.9 s, 1.7 s | 3.6 s, 2.1 s; 0.84 s, 0.91 s |
| 3 | JSON reading and record maps (23 to 38 % of the `correlate-gnn-imm`, `filter-thin` and `fuse-independent` runs; most of every vector command): a `StringBuilder` per string, a substring per number, a `LinkedHashMap` per object and per record, a path string per compared node | strings without escapes and integers up to 18 digits read without copies; events, records and parsed objects in `trace/Fields` (insertion-ordered arrays, tested against `LinkedHashMap`); the comparison walks two maps in step when their keys come in the same order and builds a path only on a mismatch | harness, large vector command: filter 5.50 s, fuse 6.51 s (medians) | filter 5.03 s, fuse 4.79 s |

Runner numbers: old engine (commit 3a5092c, the step-1 runner on the untouched engine) and new
engine alternated on this machine, two runs each, `run_ns` (engine calls only).

| Pack | Old run_ns, s | New run_ns, s |
|---|---|---|
| correlate-gnn-imm | 1.90, 1.67 | 0.84, 0.91 |
| correlate-assign-time | 41.12, 45.35 | 5.14, 4.60 |
| filter-thin | 0.85, 1.51 | 0.82, 0.74 |
| fuse-independent | 1.08, 1.17 | 0.87, 1.11 |
| quality-time | 4.47, 5.83 | 3.60, 2.08 |

## Byte-identical check

Golden output was recorded once, after step 1 and before any engine change, outside the
repository (`/tmp/rj/golden`), by the runner with `--events` and `--trace`: every scenario vector of
every function under its own pack (121), every load vector (218: its `pack_def` written to a
directory, then an empty steps file; the exit status and standard error recorded), and the large
scenario for each pack the harness names (5). After every later step all were recorded again
and compared with `cmp`:

**854 files (344 runs: the events file, the exit status and standard error of each), 854
identical, after every step.** The counters lines (timings) were not compared.

## Performance before and after

`python3 -I tools/perf/perf.py baseline --engines java` on this machine: before at 407a295
(the untouched tree, in its own worktree), after at 91c5780 (step 6). Medians; the harness's
reports per second follow from these.

| Function | Vectors, before | Vectors, after | Large, before | Large, after | Large peak memory, before → after |
|---|---|---|---|---|---|
| correlate | 1.31 s | 1.80 s | 78.10 s | 24.51 s (−69 %) | 4,260 → 2,425 MB |
| filter | 0.92 s | 0.97 s | 5.50 s | 5.03 s (−9 %) | 717 → 564 MB |
| fuse | 0.85 s | 1.04 s | 6.51 s | 4.79 s (−26 %) | 468 → 315 MB |
| quality | 1.35 s | 1.62 s | 18.19 s | 13.90 s (−24 %) | 1,459 → 872 MB |

Runner, engine calls only (after; there was no runner before): correlate-gnn-imm 10,694
reports/s, correlate-assign-time 3,312, filter-thin 14,822, fuse-independent 17,300,
quality-time 5,061.

**The small vector commands.** The harness's "vectors" cells (one JVM start, every conformance
vector of a function, about one second) read slower after: +37 %, +5 %, +22 %, +20 %. Those two
harness runs were two hours apart on a machine shared with six other engine sessions (load
average 35 to 190 on 16 cores), and the commands are mostly JVM start-up. Measured instead with
old and new builds alternated, 15 runs each, in the same minutes:

| Command | CPU (user + sys), old | new | Wall, old | new |
|---|---|---|---|---|
| correlator.VectorTest | 1.14 s | 1.02 s | 1.25 s | 1.37 s |
| filter.VectorTest | 0.39 s | 0.42 s | 0.68 s | 0.79 s |
| fuse.FuseVectorTest | 0.30 s | 0.31 s | 0.71 s | 0.67 s |
| quality.VectorTest | 0.69 s | 0.69 s | 0.93 s | 1.04 s |

The same JIT work (filter: 633 and 624 compilations), the same classes loaded give or take
lambda classes, and the same interpreted work (fuse with `-Xint`: 0.235 s and 0.24 s). Earlier
alternated rounds put filter and fuse level (0.390 s and 0.390 s CPU; 0.29 s and 0.30 s) and
correlate faster. So CPU time is level or lower and the wall-time differences are within this
machine's noise; I could not show a slowdown, nor rule out one of a few percent. Two start-up
costs were removed in step 6 (the function and kinematics tables were lambdas, now an anonymous
class table and an enum). proc-coord: a rerun of the harness on a quiet machine settles these
four cells.

Snapshot then restore: not applicable (no restore). Mutation testing is the Python engine's,
not this engine's.
