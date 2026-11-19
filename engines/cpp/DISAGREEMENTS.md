# Open points

No vector contradicts correlate.md 0.5 or correlate-assign.md 0.3 as this
engine reads them. The 0.4/0.2 entries on ties in the least total and on
where `method` may appear are settled by these versions (Ranking; Pack) and
removed. The entries below are points the specifications leave open, and
the reading this engine takes. No vector covers any of them.

## Integers outside the signed 64-bit range (correlate.md "Open points")

- The engine holds integers as signed 64-bit values. A literal outside that
  range is kept as a number that is not an integer: as `time_ms` it is
  rejected with `missing:time_ms`, as `stale_ms` it is treated as absent, and
  it is still accepted where a number is required.

## `same` between booleans, arrays or objects (correlate.md "Open points")

- The engine compares them structurally: booleans by value, arrays element by
  element in order, objects by equal key sets with equal values; values of
  different JSON kinds are never equal.

## A repeated parameter within one `filter`, `manoeuvre` or test line (correlate.md "Open points")

- A load error.

## Decimal spellings in `pack.def` (correlate.md "Open points")

- A number may have a leading sign, a fraction, an exponent, and `.5` or `5.`;
  `inf` and `nan` do not parse. `window` and `hypotheses` take digits with an
  optional sign only. `#` always starts a comment, inside a value too.

## How ranked assignments are found (correlate-assign.md "Ranking")

- The spec allows any exact method. The engine enumerates every assignment
  and sorts them by the Ranking order, which is exact and follows the tie rule
  directly; its cost grows exponentially with the number of rows and columns
  of one source, which is fine at vector sizes but not for large inputs.
