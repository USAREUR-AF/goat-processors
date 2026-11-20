# Open points under correlate 0.8 and correlate-assign 0.6

No vector contradicts `spec/correlate.md` (version 0.8) or
`spec/correlate-assign.md` (version 0.6) as this engine reads them: scenario
vectors 01 to 56 and load vectors 01 to 73 pass.

## Readings the engine takes

These follow the spec text. The vectors agree with them, but they are written
down because the text could be read another way.

| # | Spec section | Reading |
|---|---|---|
| 1 | correlate-assign.md Trace | The `history` records (`total` per candidate, `commit` per history) are emitted only when `window` is above 1. They sit in the paragraph that opens "With `window` above 1", and vectors 23 to 32 and 35, 39, 42 (window 1) have none. |
| 2 | correlate-assign.md Window, step 4 | Histories are pruned by comparing only the `choices` of their oldest record with the committed record's. Staleness events are the same in every history, so equal choices from the same committed membership give the same membership. |
| 3 | correlate-assign.md Window, step 4 | The entities removed at a commit are those named by a `drop` event in the committed record. They are also taken out of the retiring set, so a later report for that key is a new entity (vector 44, step 8). |
| 4 | correlate-assign.md Ranking | Ranked assignments come from brute-force enumeration of every assignment, sorted by total and then by choice vector. This is exact, but its cost grows with the number of assignments, so it suits vector sizes only. |
| 5 | correlate.md Restart; correlate-assign.md Snapshot | The set of restarted entities is kept only with `method assign`, where Window step 1 reads it, and is in the snapshot (`restarted`) only when the pack has `restart`. With `method confirm` a restart leaves no state beyond the filter (vector 52 has no `restarted` key). |
| 6 | correlate-assign.md Window, step 1 | A restarted entity found stale at the same tick gets only the stale events (`leave` reason `stale`, `drop`), not a second `leave` reason `restart`; the restarted set is emptied at every tick (vector 53, step 9). |
| 7 | correlate-assign.md Sensor bias, Update | The update runs at every tick, also when nothing is committed, and always on the committed membership; with no pair from the tick's rows it adds no trace record (vector 45, step 9). |
| 8 | correlate-assign.md Window, step 3 | With `margin`, a candidate is kept when it is among the first `k` and its total is at most `cut`; its `total` record has `pass` true exactly then, and `limit` `cut` (vectors 49 to 53). |
| 9 | correlate-assign.md Sensor bias | Only the `distance`, `window` and `mahalanobis` tests and the Cost move B; the Restart test compares an entity with its own prediction and moves nothing, and so does the fused estimate for output. |
| 10 | correlate.md Reports, Time quality | `time_error_ms` and `time_state` are resolved per key on every accepted report, after the reject checks; a rejected report gives no `time` record. A present `time_error_ms` of 0 is the report's value and wins over the pack's default (vector 54, step 5, gives no `time` record although radar-1 has `error_ms=500`); an absent or invalid one falls back to the default (vector 54, steps 7 and 8). |
| 11 | correlate.md Track estimate, Measurement variance | With two models, the velocity for `(v*ts)²` on a later report is that of the combined prediction (Two-model filter, Prediction), and the per-axis `r` is used in both models' position updates and so in their likelihood terms. The same `r` is used by the Restart test and, after a failed one, as the first-report `pp`. |
| 12 | correlate.md Tests; correlate-assign.md Cost | B's timing variance is added only where `pp` is read (`mahalanobis`, `rank`, the Cost); `distance` and `window` read no `pp`, so time quality does not change them. When the time error is 0 the added variance is exactly 0, so earlier vectors are unchanged bit for bit. |
| 13 | correlate-assign.md Sensor bias, Time offset | Without `time_offset`, the move and the update use `o` itself, not `o - v*0`, and the snapshot and `bias` trace carry no `time_offset_ms` or `sums`. With it, `w` is no longer updated as a running sum but set to `S1` and `S2` after each accepted pair. |

## Points the spec leaves open

`spec/correlate.md` lists both points below under "Open points", and no
vector decides either.

| # | Spec section | What the spec says | What the engine does |
|---|---|---|---|
| 1 | Tests (`same`) | `same` compares strings byte for byte and numbers by value; a string never equals a number | The spec does not say how other JSON values compare (`true`, arrays, objects). The engine compares them structurally: `true` equals `true` but never `1`, and arrays and objects are equal when their elements are, with numbers inside them compared by value. |
| 2 | Reports | An integer is a number written without a fraction or an exponent | The spec sets no range. The engine holds integers as 64-bit signed values. An integer literal outside that range is read as a non-integer number, so `time_ms` or `stale_ms` with that value counts as missing or absent. |

# Open points under fuse 0.2

No vector contradicts `spec/fuse.md` (version 0.2) as this engine reads it:
scenario vectors `fuse-*` 01 to 16 and fuse load vectors 01 to 33 pass. The
two points `spec/fuse.md` lists under "Open points" are decided here as
follows; no vector covers either.

| # | Spec section | What the spec says | What the engine does |
|---|---|---|---|
| 1 | Reports | An integer literal outside the signed 64-bit range is open (as `correlate.md`) | As under correlate: read as a non-integer number, so `time_ms` with that value is `missing:time_ms` and `stale_ms` is removed from the normalized report. A `stale_ms` line in a pack outside that range does not load. |
| 2 | Attributes | `majority`, `max`, `min` between integers above 2^53 are open | Two values written as integers compare exactly as 64-bit integers; an integer against a non-integer compares as binary64. |

# Filter 0.1

No vector contradicts `spec/filter.md` (version 0.1) as this engine reads it:
scenario vectors 01 to 27 (`packs/filter-area`, `filter-thin`,
`filter-dateline`) and load vectors 01 to 50 pass.

One reading point, not a contradiction:

| Vector | Step / field | Spec section | Reading |
|---|---|---|---|
| `spec/filter-load-vectors/03-valid-directives-after-rules` | `pack_def`, `version 1` | Pack | The directive table writes `version <semver>`, but the Values table gives `version` no grammar and the list of load errors names none for its form; the only binding rule is "`pack` and `version` take one token". The engine accepts any one token, as the vector expects, and does not apply the correlate engine's semver check. |

The two open points of `spec/filter.md` (integers beyond 2^53 or the signed
64-bit range; a report or reference within 1 m of a pole) are not decided by
any vector. The engine holds report integers as 64-bit signed values (an
integer literal outside that range is read as a float, so `time_ms` with that
value is missing), compares integers with pack numbers after conversion to
binary64, and applies the prediction formula as written near a pole.

# Open points under quality 0.2

No vector contradicts `spec/quality.md` (version 0.2) as this engine reads it:
scenario vectors q01 to q22 and load vectors 01 to 62 pass. Version 0.2
settles three points this file listed under 0.1: a forwarded `ce` that
overflows is now the largest finite binary64 (Forwarding); only space and
tab separate tokens and a control character is a load error (Pack); two
reports whose keys collide are one entity (Reports). The spec's one
remaining open point is undecided; the engine does this:

| # | Spec section | What the engine does |
|---|---|---|
| 1 | Reports | Integers are 64-bit signed, as for correlate (point 2 above): a `time_ms` or `received_ms` literal outside that range is not an integer, so `time_ms` is missing and `received_ms` absent. |

## Readings the engine takes

These follow the spec text and the vectors agree with them; they are written
down because the text could be read another way.

| # | Spec section | Reading |
|---|---|---|
| 1 | Trace, `time_error` and `time_state` | The `inputs` are the report's *valid* value and the default's value: a report value treated as absent (negative or non-finite `time_error_ms`, an unknown `time_state`, a wrong type) is written `null` (vector q20, step 3). |
| 2 | Input clock; Reports | "The entities whose source is" a source means the entities whose *entity* source it is. On a key collision, a report from source `a` for the entity `a/b/c` created by source `a/b` has no source latest, and `a/b` is one of the other sources of its input clock (vector q22, step 2). |
| 3 | Rules, Actions; Reports | A source rule is in force for a report when it is active for the report's own `track.source_id`, which on a key collision differs from the entity's source. |
| 4 | Input clock; Samples | The clock is an integer for an odd count of other sources; for an even count it is `(a + b) / 2` with `a` and `b` converted to binary64, and `lateness` is then `clock - t` in binary64. Source and entity `lateness_max`/`lateness_min` keep the sample's type (integer or binary64); two integers are compared exactly. |

# Limits found by fuzzing (refactor round, 2026-11-20)

The refactor's fuzz tests (`tests/fuzz.rs`) feed every engine malformed
reports. Three classes of input with extreme values reach behavior no spec
defines. No vector holds any of them, and the refactor changes none of them
(a change would alter output, so it is not a refactor). They are listed here
for proc-coord to decide in the specs; the fuzz tests keep their numbers inside
the range below.

| # | Input | What the engine does | What a spec decision would need |
|---|---|---|---|
| 1 | A report `lon` (or a predicted position, from a huge `speed_ms` or `dt`) so large that `wrap` (correlate.md Frame, filter.md Geometry) moves it by 360 at a time for longer than any run, or a non-finite one (`1e999` reads as infinity) | `wrap180` subtracts 360 until the value is in range: above about 1e12 degrees that takes impractically long, and for infinity, or above 2^62 where subtracting 360 no longer changes the value, it never ends | A range for `lat`/`lon` (a reject reason, as for a missing key), or `wrap` defined by remainder |
| 2 | `time_ms`, `received_ms`, `stale_ms` or a tick near the signed 64-bit limits | `received_ms - time_ms` (quality Samples, `latency`) and `now_ms - last_time_ms` (staleness) overflow: a panic in a debug build, a wrapped value in a release build | A range for millisecond integers (open point 2 of correlate.md covers only their parsing) |
| 3 | A `ce` so large that `ce²` is infinite, so a variance is infinite and a cost is NaN | `method assign`: sorting the assignment totals panics on NaN (`Ranking` assumes totals compare) | A bound on `ce`, or the order of a NaN total |
