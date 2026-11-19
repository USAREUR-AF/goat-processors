# Disagreements and interpretations

No vector contradicts specification 0.3 as this engine reads it. The points
0.2 left open (what counts as an integer, `null` for a key named only by a
`same` test, `@env` when `type` has fewer than three elements) are settled by
0.3 and removed from this file. The entry below is a place where 0.3 is still
silent, and the reading this engine takes. No vector covers it.

## Integers outside the signed 64-bit range

- Spec: "Reports" says an integer is a JSON number written without a fraction
  or an exponent, but sets no range. A literal such as `99999999999999999999`
  is an integer by that wording.
- The engine holds integers as signed 64-bit values. A literal outside that
  range is kept as a number that is not an integer: as `time_ms` it is
  rejected with `missing:time_ms`, as `stale_ms` it is treated as absent, and
  it is still accepted where a number is required.

# Method assign (correlate-assign.md 0.1)

No vector in `packs/correlate-assign` or load vectors 11 to 16 contradicts
correlate-assign.md 0.1 as this engine reads it. The entries below are places
where 0.1 is silent or can be read two ways, and the reading this engine
takes. No vector covers any of them.

## Ties in the least total

- Spec: "Assignment", step 3, says vectors are written so the least total is
  unique, and gives no rule for a tie.
- The engine takes whatever assignment its Hungarian solver reaches first
  (rows in key order, columns in creation order, then each row's `alone`).
  That is deterministic for this engine, but another engine's exact solver
  may pick a different assignment with the same total.

## Gate failure against a column with several others

- Spec: "Entries" says to run the `gate` tests between A and each of T's
  others in key order, "stop at the first failure". It does not say whether
  a failure against one other stops only that other's tests or the whole
  entry.
- The engine reads it as the whole entry: the first failing test against any
  other makes the entry forbidden, and the others after it are not tested
  and have no trace records. The vectors fail a gate only against columns
  with a single other, where both readings agree.

## Where `method` may appear

- Spec: "Pack" lists `method` third but does not say it must come before the
  directives it governs.
- The engine accepts `method` anywhere in `pack.def`, and checks the
  required and refused directives after the whole file is read.

## Entity not yet assigned, in the snapshot

- Spec: "Snapshot" says each entity holds `system`, but not what an entity
  holds when it was reported after the last tick and so has no system track
  yet.
- The engine writes `"system": null`, as correlate.md does for `group`.

## Values of `new_cost` and `keep_bonus`

- Spec: "Pack" gives both as numbers, with no range.
- The engine accepts any decimal number, including negative ones and a
  `keep_bonus` larger than `new_cost`.
