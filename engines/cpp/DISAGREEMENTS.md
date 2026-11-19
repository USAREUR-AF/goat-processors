# Open points

No vector contradicts correlate.md 0.4 or correlate-assign.md 0.2 as this
engine reads them. The 0.3/0.1 entries on gate failure against several
others, the unassigned entity's `system` in the snapshot, and the ranges of
`new_cost` and `keep_bonus` are settled by these versions and removed. The
entries below are points the specifications leave open, and the reading this
engine takes. No vector covers any of them.

## Integers outside the signed 64-bit range (correlate.md "Open points")

- The engine holds integers as signed 64-bit values. A literal outside that
  range is kept as a number that is not an integer: as `time_ms` it is
  rejected with `missing:time_ms`, as `stale_ms` it is treated as absent, and
  it is still accepted where a number is required.

## `same` between booleans, arrays or objects (correlate.md "Open points")

- The engine compares them structurally: booleans by value, arrays element by
  element in order, objects by equal key sets with equal values; values of
  different JSON kinds are never equal.

## Ties in the least total (correlate-assign.md "Assignment", step 3)

- 0.2 says engines may choose differently on a tie. The engine takes
  whatever assignment its Hungarian solver reaches first (rows in key order,
  columns in creation order, then each row's `alone`).

## Where `method` may appear (correlate-assign.md "Pack")

- The spec does not say `method` must come before the directives it
  governs. The engine accepts `method` anywhere in `pack.def`, and checks the
  required and refused directives after the whole file is read.

# Quality 0.1

No quality vector contradicts quality.md 0.1 as this engine reads it. The
entries below are the open points quality.md lists, and the reading this
engine takes. No vector covers any of them.

## Integers outside the signed 64-bit range (quality.md "Open points", Reports)

- As for correlate: the literal is kept as a number that is not an integer.
  As `time_ms` the report is rejected with `missing:time_ms`; as
  `received_ms` it is absent (no `latency` sample).

## Colliding entity keys (quality.md "Open points", Reports)

- Entities are keyed by the string `<track.source_id>/<uid>` alone, so `a/b`
  with uid `c` and `a` with uid `b/c` are one entity. Its source stays the
  `track.source_id` of its first accepted report, and the source rules in
  force for its reports are that source's.

## A forwarded `ce` that overflows (quality.md "Open points", Forwarding)

- The engine multiplies in binary64 without a guard, so the forwarded `ce`
  becomes +infinity, which the JSON writer cannot express as a JSON number.

## Whitespace other than space and tab in `pack.def` (quality.md "Open points", Pack)

- Only space and tab separate tokens; any other whitespace is part of the
  token it touches, which then fails its check (unknown directive, bad name,
  not a number). One exception: a carriage return at the very end of a line
  is removed, so a file with CRLF line ends loads as with LF.
