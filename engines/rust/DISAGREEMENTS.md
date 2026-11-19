# Open points under correlate 0.4 and correlate-assign 0.2

No vector contradicts `spec/correlate.md` (version 0.4) or
`spec/correlate-assign.md` (version 0.2) as this engine reads them: scenario
vectors 01 to 32 and load vectors 01 to 21 pass. Correlate-assign 0.2 settles
every point this file listed under 0.1 (gate failure ends the entry, ties
undefined, the set R, zero `gate` lines, `new_cost` and `keep_bonus` ranges).

Two points remain open. `spec/correlate.md` lists both under "Open points",
and no vector decides either.

| # | Spec section | What the spec says | What the engine does |
|---|---|---|---|
| 1 | Tests (`same`) | `same` compares strings byte for byte and numbers by value; a string never equals a number | The spec does not say how other JSON values compare (`true`, arrays, objects). The engine compares them structurally: `true` equals `true` but never `1`, and arrays and objects are equal when their elements are, with numbers inside them compared by value. |
| 2 | Reports | An integer is a number written without a fraction or an exponent | The spec sets no range. The engine holds integers as 64-bit signed values. An integer literal outside that range is read as a non-integer number, so `time_ms` or `stale_ms` with that value counts as missing or absent. |
