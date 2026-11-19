# goat-correlator, rust engine

An implementation of `spec/correlator-spec.md` (version 0.1) in Rust, written
from the specification and the vectors only. Standard library only; it carries
its own small JSON reader (`src/json.rs`).

| File | Spec section |
|---|---|
| `src/pack.rs` | Pack: `load_pack(dir)` and `parse_pack(text)` |
| `src/filter.rs` | Frame; Track estimate (the per-axis Kalman steps) |
| `src/engine.rs` | Reports, Tests, Association, Events, Trace, Snapshot: `Engine::ingest`, `Engine::tick`, `Engine::snapshot` |
| `tests/vectors.rs` | `spec/vector-format.md`: runs the vectors with the structural comparison |

Use:

```rust
let pack = goat_correlator::load_pack(std::path::Path::new("packs/gnn"))?;
let mut engine = goat_correlator::Engine::new(pack);
let step = engine.ingest(&report);   // step.events, step.trace (JSON values)
let step = engine.tick(1500);
let state = engine.snapshot();
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

`scenario_vectors` runs every `packs/*/vectors/*.json`: each step's events and
trace, then the final snapshot. `load_vectors` runs every
`spec/load-vectors/*.json`. Numbers compare within
`1e-6 * max(1, abs(want))`; a key with `null` differs from an absent key. On a
failure the test prints the vector and the path of the first mismatch, for
example `steps[2].trace[6].value: got 1.0, want 2.0`. Add `-- --nocapture` to
see one line per vector.

Points where the specification is silent and the engine follows the vectors
are in `DISAGREEMENTS.md`.
