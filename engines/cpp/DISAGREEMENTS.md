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

## fuse.md 0.1

No vector contradicts fuse.md 0.1 as this engine reads it. The points below
are the readings this engine takes where the spec is open; no vector covers
them.

- Integers outside the signed 64-bit range (fuse.md "Open points", Reports):
  as for correlate above.
- `majority`, `max`, `min` between integers above 2^53 (fuse.md "Open
  points", Attributes): the engine compares every number as binary64, so two
  such integers that round to the same double are equal for `majority` and
  tie (to key order) for `max` and `min`.
- `inverse_variance` with one member (fuse.md "Kinematics"): the spec says
  every method gives that member's predicted filter, so the engine returns it
  as is rather than through `1/(1/pp)`, which can differ in the last bit.
