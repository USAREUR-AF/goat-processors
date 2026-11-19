# Disagreements and open points: Go engine

## Vectors that contradict the specification

None. Every vector in `packs/*/vectors/` and `spec/correlate-load-vectors/`
agrees with `spec/correlate.md` 0.3 and `spec/correlate-assign.md` 0.1 as this
engine reads them.

## Points `correlate-assign.md` 0.1 leaves open

Each is listed with what this engine does. No vector covers any of them.

| Point | Section | This engine |
|---|---|---|
| `system` in the snapshot for an entity not yet in a system track (reported after the last tick) | Snapshot | `null` |
| Ties in the least total cost. The spec says vectors avoid them but not how an engine breaks them | Assignment, step 3 | whatever the solver (shortest augmenting paths with potentials, rows in key order, columns in creation order then `alone`) finds first; not a defined rule |
| A pack with `method assign` and no `gate` line | Pack | accepted; every column passes the gate and only the cost decides |
| `new_cost` or `keep_bonus` negative, or `keep_bonus` above `new_cost` | Pack | accepted, used as written |
| A `filter` that gives a variance of 0 (`vel_sigma_ms=0` or `unknown_vel_ms=0`), so an inverse-variance weight is infinite | Fused estimate | no guard; IEEE-754 results (Inf/NaN) pass through |
| The set of entities reported since the previous tick is state that affects the next tick, but the snapshot has no field for it, so `snapshot()` is not the whole state | Snapshot | kept internally, not in the snapshot |
| During Apply, an entity B of source S may join the column that holds A of the same source before A (later in key order) leaves it, so for a moment the system track holds two entities of S. The spec's "at most one per `track.source_id`" holds before and after a source, not between events | Assignment, step 4 | applies in key order as written: B's `join` is emitted before A's `leave` |
| An entity reported since the previous tick that is dropped as stale in the same tick | On each tick | not in R; it no longer exists when the sources are assigned |
| Whether `method` may appear after other directives | Pack | anywhere in the file; the method's directive rules are checked after the whole file is read |

The two open points of `correlate.md` 0.3 (integers outside signed 64-bit;
`same` between booleans, arrays or objects) still apply to both methods.
