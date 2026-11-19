# goat-processors, rust engine

An implementation of `spec/correlate.md` (version 0.4),
`spec/correlate-assign.md` (version 0.2) and `spec/quality.md` (version 0.1)
in Rust, written from the
specifications and the vectors only. The pack's `method` line selects which
runs: `confirm` (the default) or `assign`. Standard library only; it carries
its own small JSON reader (`src/json.rs`).

| File | Spec section |
|---|---|
| `src/pack.rs` | Pack: `load_pack(dir)` and `parse_pack(text)` |
| `src/filter.rs` | Frame; Track estimate (the per-axis Kalman steps) |
| `src/engine.rs` | Reports, Tests, Association, Events, Trace, Snapshot: `Engine::ingest`, `Engine::tick`, `Engine::snapshot` |
| `src/engine/assign.rs` | `correlate-assign.md`: system tracks, fused estimate, cost, per-source assignment (Hungarian method with potentials), its events, trace and snapshot |
| `src/quality.rs` | `spec/quality.md` 0.1: Reports, Order, Samples, Window, Entity and Source measures, Rules, Forwarding, Tick, Ingest, Events, Trace, Snapshot; reuses `src/filter.rs` for Frame and Track estimate |
| `src/quality/pack.rs` | `spec/quality.md`, Pack: `quality::load_pack(dir)` and `quality::parse_pack(text)` |
| `tests/common/mod.rs` | `spec/vector-format.md`: the structural comparison, shared by both runners |
| `tests/vectors.rs` | runs the correlate vectors (`packs/correlate-*`, `spec/correlate-load-vectors`) |
| `tests/quality_vectors.rs` | runs the quality vectors (`packs/quality-*`, `spec/quality-load-vectors`) |

Use:

```rust
let pack = goat_correlator::load_pack(std::path::Path::new("packs/correlate-gnn"))?;
let mut engine = goat_correlator::Engine::new(pack);
let step = engine.ingest(&report);   // step.events, step.trace (JSON values)
let step = engine.tick(1500);
let state = engine.snapshot();

let pack = goat_correlator::quality::load_pack(std::path::Path::new("packs/quality-feed"))?;
let mut quality = goat_correlator::quality::Engine::new(pack);
let step = quality.ingest(&report);  // new, pass (with the actions in force)
let step = quality.tick(60000);      // forget, quality, action-start / action-end
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

`scenario_vectors` runs every `packs/correlate-*/vectors/*.json`: each step's
events and trace, then the final snapshot. `load_vectors` runs every
`spec/correlate-load-vectors/*.json`. `quality_scenario_vectors` and
`quality_load_vectors` do the same for `packs/quality-*/vectors/*.json` and
`spec/quality-load-vectors/*.json`. Numbers compare within
`1e-6 * max(1, abs(want))`; a key with `null` differs from an absent key. On a
failure the test prints the vector and the path of the first mismatch, for
example `steps[2].trace[6].value: got 1.0, want 2.0`. Add `-- --nocapture` to
see one line per vector.

Points still open under correlate 0.4, correlate-assign 0.2 and quality 0.1
are in `DISAGREEMENTS.md`.
