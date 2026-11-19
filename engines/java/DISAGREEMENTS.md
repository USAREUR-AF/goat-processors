# java engine: disagreements and open points

No vector contradicts `spec/correlate.md` 0.3 or `spec/correlate-assign.md`
0.1; every vector passes as written. The engine does not depart from the
specification anywhere.

## Points `correlate-assign.md` 0.1 leaves open

No vector covers these. The table records what this engine does, so a later
version can settle each with a vector.

| Point | Section | What this engine does |
|---|---|---|
| Ties in the least total cost. The spec says only that vectors make the least total unique. | Assignment, step 3 | The Hungarian method's result, which depends on row and column order (rows in key order; columns in creation order, then each row's `alone`). Engines using another exact solver may pick a different assignment of equal cost. |
| "Since the previous tick" for the set R: by call order, or by `time_ms` against `now_ms`. | Assignment, On each tick | Call order: every entity with an accepted `ingest` after the previous `tick` call, whatever its `time_ms`, including a `time_ms` later than `now_ms`. |
| The reported-since-last-tick set is state that decides the next tick, but the snapshot has no field for it. | Snapshot | Not in the snapshot; `snapshot()` is not the whole state between an `ingest` and the next `tick`. |
| A variance of 0 in the fused estimate (`vel_sigma_ms=0` or `unknown_vel_ms=0` gives `vv = 0`; `1/vv` is infinite). | Assignment, fused estimate | IEEE-754 as written: `1/0` is infinity, so the fused `v` is NaN or infinite. The pack loader accepts such a filter. |
| A `method` value other than `confirm` or `assign`. Vector 15 expects a load error; the spec does not say so in words. | Pack | Load error, as for any value that does not parse. |
| Range of `new_cost` and `keep_bonus` (negative values, `keep_bonus` above `new_cost`). | Pack | Any decimal is accepted; negative entries are fine for the solver. |
