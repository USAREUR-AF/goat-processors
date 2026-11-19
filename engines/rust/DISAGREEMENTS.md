# Open points under spec 0.3

No vector contradicts `spec/correlate.md` (version 0.3) as this engine reads
it. The point this file listed under 0.2 (whether `1000.0` is an integer) is
settled by 0.3: an integer is a number written without a fraction or an
exponent, and the engine's JSON reader keeps that distinction.

Two points are still open. No vector decides either one.

| # | Spec section | What the spec says | What the engine does |
|---|---|---|---|
| 1 | Tests (`same`) | `same` compares strings byte for byte and numbers by value; a string never equals a number | The spec does not say how other JSON values compare (`true`, arrays, objects). The engine compares them structurally: `true` equals `true` but never `1`, and arrays and objects are equal when their elements are, with numbers inside them compared by value. |
| 2 | Reports | An integer is a number written without a fraction or an exponent | The spec sets no range. The engine holds integers as 64-bit signed values. An integer literal outside that range is read as a non-integer number, so `time_ms` or `stale_ms` with that value counts as missing or absent. |

# Open points under correlate-assign 0.1

No vector contradicts `spec/correlate-assign.md` (version 0.1) as this engine
reads it: vectors 23 to 30 and load vectors 11 to 16 pass. These points the
specification leaves open; no vector decides them.

| # | Spec section | What the spec says | What the engine does |
|---|---|---|---|
| 1 | Assignment, step 2 | Run the gate tests between A and each of T's others in key order, "stop at the first failure" | Read as: the first failing test ends the column, so the others after it are not tested and have no trace records. Every vector has columns with one other, so none tells this from "stop per other". |
| 2 | Assignment, step 3 | Vectors are written so the least total is unique | No tie rule is given. The engine returns whichever least-cost assignment the Hungarian method reaches (float costs, no tolerance); with a tie, engines may differ. |
| 3 | Fused estimate | Gives `p`, `pp`, `v`, `vv` per axis | The cross term `pv` of a fused estimate is not defined. Nothing reads it (cost uses `pp`, output uses `p` and `v`), so the engine leaves it 0. |
| 4 | Assignment, "On each tick" | The entities that had an accepted report since the previous tick | An entity with several reports between ticks counts once. An entity that reported and is stale at the tick is dropped by staleness first and takes no part in the assignment. |
| 5 | Pack | `gate` repeats | Whether zero `gate` lines is valid is not said. The engine accepts it: every column entry then passes and costs `d²` (less `keep_bonus`). |
| 6 | Pack | `new_cost` and `keep_bonus` are numbers | No range is set. The engine accepts any decimal, negative included. |
| 7 | Pack | The directives refused with `method assign` | The `method` line may come anywhere in the file; the engine checks refused and required directives after reading the whole file. With `method confirm` (or no `method`), `new_cost` and `keep_bonus` are load errors (load vector 14). |
