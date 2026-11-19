# Disagreements and open points, zig engine

## Vectors that contradict the specification

None. Every load vector (01 to 16) and every scenario vector (01 to 30)
agrees with `spec/correlate.md` 0.3 and `spec/correlate-assign.md` 0.1 as
this engine reads them.

## Points `correlate-assign.md` 0.1 leaves open

How this engine decides each one. A later version may settle them with vectors.

| Point | This engine |
|---|---|
| Order of the `gate` trace records within a source. The spec says gate tests give the `correlate.md` records and that the `cost` records come "after a source's entries are computed", but not the order of the gate records among themselves. | Entities of R in key order, then columns in creation order, then T's others in key order; all before the first `cost` record. Vectors 23 and 25 agree. |
| A forbidden entry for a column whose gate stopped early: whether the gate tests against T's later others are run. | Not run: "stop at the first failure" is read across all of T's others, so the first failing test ends that entry. |
| `system` of an entity in the snapshot before its first tick. | `null`. |
| An entity that goes stale before it was ever assigned. | No `leave` or `end`, only `drop`; it is also removed from the reported set. |
| A fused estimate where a member's `pp` or `vv` is 0 (for example `vel_sigma_ms=0`), so `1/pp_i` is infinite. | Not guarded; IEEE-754 gives infinities or NaN. |
| Sign and range of `new_cost` and `keep_bonus`. | Any decimal number is accepted, negative included. |
| Where the `method` line may appear in `pack.def`. | Anywhere; the method-specific checks run after the whole file is read. `method` appears at most once. |
| Whether `new_cost` and `keep_bonus` are load errors with `method confirm`. | Load errors, as load vector 14 expects; `correlate.md` 0.3 does not list them among its directives. |
| Exact ties in the least total cost. | The spec rules them out ("vectors are written so the least total is unique"); this engine returns whichever optimum the Hungarian method reaches. |
| Choosing *alone* when A is in a system track whose other members are all entities of R. | Cannot occur: a system track holds at most one entity per source, and R is one source, so A's track has no other R member. |

## Points `correlate.md` 0.3 leaves open

| Point | This engine |
|---|---|
| An integer literal outside the signed 64-bit range | `std.json` does not return it as an integer, so it is the wrong type where an integer is required. |
| `same` between booleans, arrays or objects | Compared structurally: equal when of the same kind and equal element by element. |
