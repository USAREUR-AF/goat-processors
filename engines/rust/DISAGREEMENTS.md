# Open points under correlate 0.5 and correlate-assign 0.3

No vector contradicts `spec/correlate.md` (version 0.5) or
`spec/correlate-assign.md` (version 0.3) as this engine reads them: scenario
vectors 01 to 44 and load vectors 01 to 42 pass.

## Readings the engine takes

These follow the spec text. The vectors agree with them, but they are written
down because the text could be read another way.

| # | Spec section | Reading |
|---|---|---|
| 1 | correlate-assign.md Trace | The `history` records (`total` per candidate, `commit` per history) are emitted only when `window` is above 1. They sit in the paragraph that opens "With `window` above 1", and vectors 23 to 32 and 35, 39, 42 (window 1) have none. |
| 2 | correlate-assign.md Window, step 4 | Histories are pruned by comparing only the `choices` of their oldest record with the committed record's. Staleness events are the same in every history, so equal choices from the same committed membership give the same membership. |
| 3 | correlate-assign.md Window, step 4 | The entities removed at a commit are those named by a `drop` event in the committed record. They are also taken out of the retiring set, so a later report for that key is a new entity (vector 44, step 8). |
| 4 | correlate-assign.md Ranking | Ranked assignments come from brute-force enumeration of every assignment, sorted by total and then by choice vector. This is exact, but its cost grows with the number of assignments, so it suits vector sizes only. |

## Points the spec leaves open

`spec/correlate.md` lists both points below under "Open points", and no
vector decides either.

| # | Spec section | What the spec says | What the engine does |
|---|---|---|---|
| 1 | Tests (`same`) | `same` compares strings byte for byte and numbers by value; a string never equals a number | The spec does not say how other JSON values compare (`true`, arrays, objects). The engine compares them structurally: `true` equals `true` but never `1`, and arrays and objects are equal when their elements are, with numbers inside them compared by value. |
| 2 | Reports | An integer is a number written without a fraction or an exponent | The spec sets no range. The engine holds integers as 64-bit signed values. An integer literal outside that range is read as a non-integer number, so `time_ms` or `stale_ms` with that value counts as missing or absent. |
