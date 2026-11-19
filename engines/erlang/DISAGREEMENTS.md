# Disagreements and open points: Erlang engine

## Vectors against the specification

None. Every vector under `packs/*/vectors/` and `spec/correlate-load-vectors/`
agrees with `spec/correlate.md` (0.3) and `spec/correlate-assign.md` (0.1) as
this engine reads them.

## Open points in correlate-assign.md 0.1

Cases the specification leaves undecided or decides only implicitly. No vector
covers them. The table gives the reading this engine takes.

| Point | Section | This engine |
|---|---|---|
| "stop at the first failure" in Entries: whether a failed gate test against one of T's others also stops the gate tests against T's later others, or only the remaining tests against that one other | Assignment, step 2 | The column's gate tests stop entirely at the first failure, so later others get no gate records. The entry is forbidden either way; only the trace differs. |
| Ties for the least total cost | Assignment, step 3 | The vectors are written so the minimum is unique. On a tie the engine takes whatever the Hungarian solver (rows in key order, columns in creation order then each row's own *alone*) reaches first. Engines may differ. |
| The entities reported since the previous tick are state, but the snapshot has no field for them | Snapshot | Not in the snapshot. Two engines with equal snapshots may still decide the next tick differently. |
| An entity's `system` in the snapshot before its first tick | Snapshot | `null`. |
| `method` given more than once, or with a value that is not `confirm` or `assign`, when the rest of the pack would be valid for one of them | Pack | A repeated `method` is a load error (it is a directive that appears once); an unknown value is a load error (load vector 15). The first `method` line selects which directive set is checked. |
| Sign of `new_cost` and `keep_bonus` | Pack | Any decimal number is accepted, negative included. |
| A tick whose `now_ms` is earlier than an entity's `last_time_ms` | Assignment, Output | Predicted with a negative `dt`, as `correlate.md` allows for prediction. |

## Open points in correlate.md 0.3

As listed in its "Open points" section: an integer literal outside the signed
64-bit range (OTP decodes it as an arbitrary-precision integer and the engine
accepts it), and `same` between booleans, arrays or objects (compared by exact
term equality).
