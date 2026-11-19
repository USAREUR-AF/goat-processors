# Open points under spec 0.2

No vector contradicts `spec/correlate.md` (version 0.2) as this engine reads
it. The six points this file listed under 0.1 (stage tests stop at the first
failure, hold per member, the count record's stage, `missing:` rejects carry
no `entity`, the `rank` record form, the dissolved group's remaining member)
are all settled by 0.2, and the engine follows the settled text.

One point is still open; no vector decides it.

| # | Spec section | What the spec says | What the engine does |
|---|---|---|---|
| 1 | Reports | `time_ms` and `stale_ms` must be integers; "an integer is accepted where a number is required" | JSON does not distinguish `1000` from `1000.0`. The engine treats any number with no fractional part as an integer, so `"time_ms": 1000.0` is accepted and `"time_ms": 1.5` is rejected with `missing:time_ms` (as `correlate-gnn/21-wrong-types` requires). The spec could say whether a number written with a fraction part but integral value is an integer. |
