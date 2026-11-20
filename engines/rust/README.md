# goat-processors, rust engine

An implementation in Rust of `spec/correlate.md` (version 0.8),
`spec/correlate-assign.md` (version 0.6), `spec/filter.md` (version 0.1),
`spec/fuse.md` (version 0.2) and `spec/quality.md` (version 0.2), written from
the specifications and the vectors only. Standard library only; it carries its
own small JSON reader (`src/model/json.rs`).

## Layout

One module per concern, the same names as the other engines use:

| Module | What it holds |
|---|---|
| `src/model/` | the shared data model: JSON values, reports, frame, track estimate, two-model filter, shared pack values. Values and pure functions only |
| `src/correlate/` | correlate: the engine both methods share, its pack, the tests, restart, and the `confirm` method |
| `src/assign/` | correlate's `assign` method (correlate-assign.md) |
| `src/filter/` | the filter function |
| `src/fuse/` | the fuse function |
| `src/quality/` | the quality function |
| `src/trace.rs` | `StepResult` and the shared event and trace record builders |
| `src/snapshot.rs` | the JSON forms every Snapshot shares |
| `src/io/` | the steps file, the events file, the runner contract |
| `src/function.rs` | `Function`, the one entry-point shape |
| `src/bin/runner.rs` | the command-line runner (`runner/build`, `runner/run`) |

Every function has the same entry point, the trait `goat_correlator::Function`:

```rust
use goat_correlator::{Function, correlate};

let pack = correlate::Engine::load_pack(std::path::Path::new("packs/correlate-gnn"))?;
let mut engine = correlate::Engine::new(pack);
let step = engine.ingest(&report);   // step.events, step.trace (JSON values)
let step = engine.tick(1500);
let state = engine.snapshot();
```

`filter::Engine`, `fuse::Engine` and `quality::Engine` are driven by the same
five calls. `Function::NAME` is the name the runner's `--function` takes.

## Where each spec section lives

### spec/correlate.md

| Section | File |
|---|---|
| What the correlator does | `src/correlate/mod.rs` |
| Reports | `src/model/report.rs` (required keys, reject, optional keys); `src/correlate/mod.rs` (`ingest`: out-of-order, the reference) |
| Reports, Time quality | `src/model/report.rs` (`time_quality`) |
| Frame | `src/model/frame.rs` |
| Track estimate | `src/model/track.rs` (the per-axis steps, velocity, Measurement variance, `d²`); `src/correlate/entity.rs` (an entity's prediction, first and later reports) |
| Two-model filter | `src/model/two_model.rs` |
| Restart | `src/correlate/restart.rs` |
| Tests | `src/correlate/pair_tests.rs` |
| Association | `src/correlate/confirm.rs` |
| Events | `src/correlate/confirm.rs`; `src/trace.rs` |
| Trace | `src/trace.rs` (the record shape); written where each stage runs |
| Snapshot | `src/correlate/confirm.rs`; `src/correlate/mod.rs` (`filter_json`); `src/snapshot.rs` |
| Pack | `src/correlate/pack.rs`; `src/model/pack.rs` (`filter`, `time_default`) |
| Floats | every number is a binary64 (`f64`); integers of reports are `i64` |

### spec/correlate-assign.md

| Section | File |
|---|---|
| What this method does; Shared with `correlate.md` | `src/assign/mod.rs` |
| Memberships | `src/assign/membership.rs` |
| Assignment of one source | `src/assign/cost.rs` |
| Sensor bias | `src/assign/bias.rs` |
| Ranking | `src/assign/ranking.rs` |
| Window | `src/assign/window.rs` |
| Events | `src/assign/membership.rs` (membership events); `src/assign/window.rs` (`system`, `provisional`) |
| Trace | `src/assign/cost.rs` (gate, cost); `src/assign/window.rs` (choice, history); `src/assign/bias.rs` (bias) |
| Snapshot | `src/assign/snapshot.rs` |
| Pack | `src/correlate/pack.rs` |

### spec/filter.md

| Section | File |
|---|---|
| What the filter does; Rules; Tick; Events; Trace; Snapshot | `src/filter/mod.rs` |
| Reports | `src/model/report.rs` (cited from correlate.md) |
| Geometry | `src/filter/geometry.rs` |
| Conditions | `src/filter/conditions.rs` |
| Pack | `src/filter/pack.rs` |

### spec/fuse.md

| Section | File |
|---|---|
| What fuse does; Groups; On each tick; Fused event; Events; Trace | `src/fuse/mod.rs` |
| Shared with `correlate.md` | `src/model/frame.rs`, `src/model/track.rs` |
| Reports | `src/fuse/report.rs` |
| Kinematics | `src/fuse/kinematics.rs` |
| Attributes | `src/fuse/attributes.rs` |
| Snapshot | `src/fuse/snapshot.rs` |
| Pack | `src/fuse/pack.rs` |

### spec/quality.md

| Section | File |
|---|---|
| What quality does; Reports; Frame and filter; Window; Tick; Ingest | `src/quality/mod.rs` |
| Reports, Time quality | `src/model/report.rs` (`time_error_ms`, `time_state`) |
| Order; Input clock; Samples | `src/quality/samples.rs` |
| Entity measures; Source measures | `src/quality/measures.rs` |
| Rules | `src/quality/rules.rs` |
| Forwarding | `src/quality/forwarding.rs` |
| Events | `src/quality/measures.rs` (`quality`), `src/quality/rules.rs` (actions), `src/quality/forwarding.rs` (`pass`), `src/quality/mod.rs` |
| Trace | `src/quality/mod.rs` (samples), `src/quality/rules.rs` (rules) |
| Snapshot | `src/quality/snapshot.rs` |
| Pack | `src/quality/pack.rs` |

### spec/vector-format.md

| Section | File |
|---|---|
| Steps, the comparison | `tests/common/mod.rs`; `src/io/mod.rs` (steps files) |

## Build

```
export PATH=$HOME/.cargo/bin:$PATH
cd engines/rust
cargo build
```

## Run the vectors

```
cd engines/rust
cargo test
```

`scenario_vectors` runs every `packs/correlate-*/vectors/*.json`: each step's
events and trace, then the final snapshot. `load_vectors` runs every
`spec/correlate-load-vectors/*.json`. `filter_scenario_vectors`,
`fuse_scenario_vectors`, `quality_scenario_vectors` and their `*_load_vectors`
do the same for the other functions. Numbers compare within
`1e-6 * max(1, abs(want))`; a key with `null` differs from an absent key. On a
failure the test prints the vector and the path of the first mismatch, for
example `steps[2].trace[6].value: got 1.0, want 2.0`. Add `-- --nocapture` to
see one line per vector.

## The runner

`runner/build` builds `src/bin/runner.rs` with the release profile;
`runner/run` runs it, as `tools/perf/README.md` "Runner contract" states:

```
runner/run --function correlate --pack ../../packs/correlate-gnn --steps <steps.json> --events out.jsonl --trace
```

Points still open under each spec are in `DISAGREEMENTS.md`.
