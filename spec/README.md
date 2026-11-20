# Specifications

Each function has one specification. Every engine implements every function
from these documents and the vectors (test cases with their exact expected
output), never from another engine's source. Words such as track, tick, pack
and trace record are defined in the README, [Words used here](../README.md#words-used-here);
the correlate packs are listed in [Methods and packs](../README.md#methods-and-packs).

| Function | Specification | Status | What it does |
|---|---|---|---|
| correlate | [correlate.md](correlate.md) | Written, version 0.8; seven engines built | decides which tracks from different sources describe the same object, groups them, and outputs one estimate per group. This row is the per-report method, `confirm`: each new report is tested, and a pair is grouped after passing on two reports in a row |
| correlate, method assign | [correlate-assign.md](correlate-assign.md) | Written, version 0.6; seven engines built | the per-tick method, `assign`: at each tick, places all of one source's tracks at once into one output track per object (a system track) by the least total cost, and combines the members' positions weighted by their uncertainty |
| fuse | [fuse.md](fuse.md) | Written, version 0.2; seven engines built | combines the tracks of one group (those whose reports carry the same `fuse.group` key) into one estimate: weighted by each member's uncertainty (inverse variance), or by covariance intersection when members may share an error, or by taking the best, highest-priority or latest member; each other attribute (identity, for example) by its own rule |
| filter | [filter.md](filter.md) | Written, version 0.1; seven engines built | keeps or drops each report by the first matching rule: inside or outside a circle or polygon, within a distance of a reference such as own ship, by environment, affiliation, source, identity or any key, and thins a feed by interval |
| quality | [quality.md](quality.md) | Written, version 0.2; Python built | measures each track and each source from its reports (time between updates, age, latency, how far reports fall from the track's prediction in units of the reported error, the speed implied by successive positions against the reported speed, reports out of order, missing keys, lateness against the other sources, and the clock error and clock state the source reports) and applies the action a rule attaches to a measure: mark, downgrade, drop or alert |

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
