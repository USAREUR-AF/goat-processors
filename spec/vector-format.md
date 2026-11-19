# Vector format

Status: Written. Version 0.1. A vector is one conformance case. Every engine
runs every vector and must reproduce it exactly, including the trace.

## Scenario vectors

One JSON object per file under `packs/<pack>/vectors/*.json`.

| Key | Meaning |
|---|---|
| `name` | unique within the pack |
| `pack` | the pack directory under `packs/` to load |
| `steps` | list of calls, run in order on one engine |
| `snapshot` | the expected `snapshot()` after the last step |

Each step holds exactly one of `ingest` (a report object) or `tick` (an
integer `now_ms`), plus `expect` (the list of events the call returns) and
`trace` (the list of trace records it returns).

## What the engine checks

For each step, the returned events equal `expect` and the returned trace
equals `trace`. After the last step, `snapshot()` equals `snapshot`.

Equality is structural: objects have the same keys with equal values, lists
have the same length and equal items in order, strings are equal byte for
byte, `true`/`false`/`null` are equal to themselves. Two numbers are equal
when `abs(got - want) <= 1e-6 * max(1, abs(want))`; an integer and a float
with that relation are equal. A key present with value `null` is not the same
as a key absent.

In a report, JSON numbers are the key's value; `time_ms` and `stale_ms` are
integers.

## Load vectors

One JSON object per file under `spec/load-vectors/*.json`: `name`,
`pack_def` (the full text of a `pack.def`) and `expect_error` (boolean).
Parsing `pack_def` must fail when `expect_error` is true and succeed when it
is false. The error text is not compared.

## Writing vectors

`tools/make-vectors.py` holds every scenario with its association decisions
stated by hand, runs the Python engine, and refuses to write a vector whose
events differ from those decisions. The numbers in a vector come from that
engine; the other engines check them independently.
