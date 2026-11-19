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
