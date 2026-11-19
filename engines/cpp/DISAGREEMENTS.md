# Disagreements and interpretations

No vector contradicts specification 0.2 as this engine reads it. The points
0.1 left open (stage tests stopping at the first failure, the `count` record's
stage, `rank` records, `entity` on a `missing:` reject, `course` and `speed`
with a missing or zero speed, value types) are settled by 0.2 and removed from
this file. The entries below are places where 0.2 is still silent, and the
reading this engine takes. No vector covers any of them.

## What counts as an integer

- Spec: "Reports" says `time_ms` must be an integer and `stale_ms` an integer,
  but not whether a JSON number written with a fraction or exponent and an
  integral value (`1000.0`, `1e3`) is one. Vector `correlate-gnn/21` only
  shows that `1.5` is not.
- The engine takes an integer to be a JSON number written without fraction or
  exponent that fits in a signed 64-bit integer. `1000.0` as `time_ms` is
  rejected with `missing:time_ms`; as `stale_ms` it is treated as absent.

## `null` for a key named only by a `same` test

- Spec: "Reports" treats `null` as absent for the listed optional keys, and
  "Tests" says a `same` trace value is null when absent, but neither says
  whether `null` for any other key (for example `track.simulated`) is absent.
- The engine treats it as absent, so `null` on one side and no key on the
  other passes `same`.

## `@env` when `type` has fewer than three elements

- Spec: "Reports" defines `@env` as the third `-`-separated element of `type`
  but not what it is when there is none (`type` = `a-f`).
- The engine treats `@env` as absent in that case, as it does when `type` is
  absent or not a string.
