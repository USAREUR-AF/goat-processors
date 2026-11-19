# Specifications

Each function has one specification. Every engine implements every function
from these documents and the vectors, never from another engine's source.

| Function | Specification | Status | What it does |
|---|---|---|---|
| correlate | [correlate.md](correlate.md) | Written, version 0.3; seven engines built | decides which tracks from different sources are one object, groups them, emits one estimate per group |
| fuse | — | Designed, not built | combines the measurements of a group's members into one estimate weighted by each member's uncertainty, instead of reporting one member |
| filter | — | Designed, not built | keeps or drops entities by rule: inside or outside an area, within a distance of a reference such as own ship, by environment, identity or source |
| quality | — | Designed, not built | measures each source and track (update interval, latency, reported against observed error, gaps, staleness) and states the action a rule attaches to a measurement: mark, downgrade, drop or alert |

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
