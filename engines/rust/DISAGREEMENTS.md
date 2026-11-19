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

# Open points under fuse 0.1

No vector contradicts `spec/fuse.md` (version 0.1) as this engine reads it:
scenario vectors `fuse-*` 01 to 16 and fuse load vectors 01 to 33 pass. The
two points `spec/fuse.md` lists under "Open points" are decided here as
follows; no vector covers either.

| # | Spec section | What the spec says | What the engine does |
|---|---|---|---|
| 1 | Reports | An integer literal outside the signed 64-bit range is open (as `correlate.md`) | As under correlate: read as a non-integer number, so `time_ms` with that value is `missing:time_ms` and `stale_ms` is removed from the normalised report. A `stale_ms` line in a pack outside that range does not load. |
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

# Open points under quality 0.1

No vector contradicts `spec/quality.md` (version 0.1) as this engine reads it:
scenario vectors q01 to q15 and load vectors 01 to 45 pass. The spec's own
"Open points" are undecided; the engine does this:

| # | Spec section | What the engine does |
|---|---|---|
| 1 | Reports | Integers are 64-bit signed, as for correlate (point 2 above): a `time_ms` or `received_ms` literal outside that range is not an integer, so `time_ms` is missing and `received_ms` absent. |
| 2 | Reports | The entity key is the string `<track.source_id>/<uid>`; two reports whose keys collide are one entity, whose source is that of its first report. |
| 3 | Forwarding | The forwarded `ce` is the binary64 product; one that overflows is written as Rust's `inf`, which is not valid JSON. |
| 4 | Pack | Only space and tab separate tokens; any other whitespace is part of a token, so it makes a value or directive fail to parse. |
