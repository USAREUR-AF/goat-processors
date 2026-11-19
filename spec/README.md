# Specifications

Each function has one specification. Every engine implements every function
from these documents and the vectors, never from another engine's source.

| Function | Specification | Status | What it does |
|---|---|---|---|
| correlate | [correlate.md](correlate.md) | Written, version 0.6; seven engines built | decides which tracks from different sources are one object, groups them, emits one estimate per group |
| correlate, method assign | [correlate-assign.md](correlate-assign.md) | Written, version 0.4; seven engines built | every track in one system track; per-source least-cost assignment at each tick; members fused by uncertainty weight |
| fuse | [fuse.md](fuse.md) | Written, version 0.2; seven engines built | combines the members of each group named by `fuse.group` into one estimate: inverse variance, covariance intersection, best, priority or latest; one rule per attribute |
| filter | [filter.md](filter.md) | Written, version 0.1; seven engines built | keeps or drops each report by the first matching rule: inside or outside a circle or polygon, within a distance of a reference such as own ship, by environment, affiliation, source, identity or any key, and thins a feed by interval |
| quality | [quality.md](quality.md) | Written, version 0.1; seven engines built | measures each entity and source from its reports (update interval, age, latency, normalized innovation squared against reported error, implied against reported speed, order, missing keys) and applies the action a rule attaches to a measure: mark, downgrade, drop or alert |

## What every function shares

- **Input** is the shared-model entity that
  [goat-transformers](https://github.com/USAREUR-AF/goat-transformers)
  decodes from any message format; keys are named as in its `model/`.
- **Determinism.** The only clock is the time in the input. No wall clock, no
  randomness, and every collection is visited in an order the specification
  defines, so every engine gives the same output for the same input.
- **Rules are data.** A pack names fixed, specified tests and their
  parameters. No pack holds code or expressions.
- **Every decision is in the trace.** Each test is a record naming its
  inputs, the value it computed, the limit and the result, and `snapshot()`
  returns the whole state.
- **Vectors** follow [vector-format.md](vector-format.md).
