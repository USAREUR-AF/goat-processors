# goat-correlator, rust engine

An implementation of `spec/correlate.md` (version 0.4),
`spec/correlate-assign.md` (version 0.2) and `spec/fuse.md` (version 0.1) in Rust, written from the
specifications and the vectors only. The pack's `method` line selects which
runs: `confirm` (the default) or `assign`. Standard library only; it carries
its own small JSON reader (`src/json.rs`).

| File | Spec section |
|---|---|
| `src/pack.rs` | Pack: `load_pack(dir)` and `parse_pack(text)` |
| `src/filter.rs` | Frame; Track estimate (the per-axis Kalman steps) |
| `src/engine.rs` | Reports, Tests, Association, Events, Trace, Snapshot: `Engine::ingest`, `Engine::tick`, `Engine::snapshot` |
| `src/engine/assign.rs` | `correlate-assign.md`: system tracks, fused estimate, cost, per-source assignment (Hungarian method with potentials), its events, trace and snapshot |
| `src/fuse.rs` | `spec/fuse.md` Reports (validation, normalised report), Groups, On each tick, Fused event (with Height), Events, Trace, Snapshot: `fuse::Engine` |
| `src/fuse/pack.rs` | `spec/fuse.md` Pack: `fuse::load_pack(dir)` and `fuse::parse_pack(text)` |
| `src/fuse/kinematics.rs` | `spec/fuse.md` Kinematics: `inverse_variance`, `covariance_intersection` (weight, fold), `best`, `priority`, `latest` |
| `src/fuse/attributes.rs` | `spec/fuse.md` Attributes: candidates, the five rules, `majority` equality |
| `tests/common/mod.rs` | `spec/vector-format.md`: the structural comparison, shared by both runners |
| `tests/vectors.rs` | runs the correlate vectors (`packs/correlate-*`, `spec/correlate-load-vectors`) |
| `tests/fuse_vectors.rs` | runs the fuse vectors (`packs/fuse-*`, `spec/fuse-load-vectors`) |

Use:

```rust
let pack = goat_correlator::load_pack(std::path::Path::new("packs/correlate-gnn"))?;
let mut engine = goat_correlator::Engine::new(pack);
let step = engine.ingest(&report);   // step.events, step.trace (JSON values)
let step = engine.tick(1500);
let state = engine.snapshot();

// fuse (spec/fuse.md); reuses correlate's Frame and filter (src/filter.rs)
let pack = goat_correlator::fuse::load_pack(std::path::Path::new("packs/fuse-shared"))?;
let mut fuse = goat_correlator::fuse::Engine::new(pack);
```

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

`scenario_vectors` runs every `packs/correlate-*/vectors/*.json`: each step's events and
trace, then the final snapshot. `load_vectors` runs every
`spec/correlate-load-vectors/*.json`. Numbers compare within
`1e-6 * max(1, abs(want))`; a key with `null` differs from an absent key. On a
failure the test prints the vector and the path of the first mismatch, for
example `steps[2].trace[6].value: got 1.0, want 2.0`. `fuse_scenario_vectors`
and `fuse_load_vectors` do the same for `packs/fuse-*/vectors/*.json` and
`spec/fuse-load-vectors/*.json`. Add `-- --nocapture` to
see one line per vector.

Points still open under correlate 0.4, correlate-assign 0.2 and fuse 0.1 are in
`DISAGREEMENTS.md`.
