# Disagreements and open points: Go engine

## Vectors that contradict the specification

None. Every vector in `packs/correlate-*/vectors/` (01-56),
`spec/correlate-load-vectors/` (01-73), `packs/filter-*/vectors/`,
`spec/filter-load-vectors/`, `packs/fuse-*/vectors/` and
`spec/fuse-load-vectors/` agrees with `spec/correlate.md` 0.8,
`spec/correlate-assign.md` 0.6, `spec/filter.md` 0.1 and `spec/fuse.md` 0.2 as
this engine reads them.

## Points still open

No vector covers any of them; each is listed with what this engine does.

| Point | Section | This engine |
|---|---|---|
| An integer literal outside the signed 64-bit range | `correlate.md` Reports | not an integer: the field is treated as absent |
| `same` between booleans, arrays or objects | `correlate.md` Tests | booleans equal when both are the same boolean; arrays and objects equal when their JSON encodings (object keys sorted) are identical |
| A repeated parameter within one `filter`, `maneuver` or test line | `correlate.md` Pack | load error |
| Which decimal spellings a number may take | `correlate.md` Pack | Go `strconv.ParseFloat` / `ParseInt` base 10, minus hex, `inf`, `nan` and `_`; so `1e3`, `.5` and a leading `+` load, including `window +2` |
| Ranges of `confirm_count`, `hold_failures`, `stale_ms` and of test parameters | `correlate.md` Pack | any value that parses loads |
| An integer literal outside the signed 64-bit range (open point of `fuse.md` 0.2) | fuse Reports | as correlate: not an integer, so `time_ms` is missing and `stale_ms` absent |
| `majority`, `max`, `min` between integers above 2^53 (open point of `fuse.md` 0.2) | fuse Attributes | compared as binary64 |
| An integer literal in a report outside the signed 64-bit range (open point of `filter.md` 0.1) | filter: Reports | as for correlate: not an integer, so a required `time_ms` is missing and an optional `stale_ms` is absent |
| `key` eq, in or range, `speed` or `altitude`, on an integer above 2^53 in magnitude (open point of `filter.md` 0.1) | filter: Conditions | the JSON number is read as the nearest binary64 and compared as that |
| A report or reference within 1 m of a pole (open point of `filter.md` 0.1) | filter: Geometry | the formula as written; no guard on `cos(rad(lat))` |
| `key` range on a present value that is not a number (a string, a boolean) | filter: Conditions, Trace | unknown, with `value` the report's value (only `near` is told to give null when unknown) |
| `#` inside a parameter value | filter: Pack | `#` always starts a comment, wherever it is on the line |
| A repeated parameter within one `restart` or `bias` line | `correlate.md` Pack, `correlate-assign.md` Pack | load error, as for `filter` and `maneuver` |
| `margin` with a value that is not finite or not decimal | `correlate-assign.md` Pack | read as the other pack numbers above |
| A repeated parameter within one `time_offset` line | `correlate-assign.md` Pack | load error, as for `bias` |
| `time_default` `error_ms` spelled with an exponent, `+` or `.5` | `correlate.md` Pack | read as the other pack numbers above; `inf` and `nan` do not load |

## Quality (`quality/`, `spec/quality.md` 0.2)

### Vectors that contradict the specification

None. Every vector in `packs/quality-*/vectors/` and `spec/quality-load-vectors/`
(q01-q22, load 01-62) agrees with `spec/quality.md` 0.2 and, for the time
quality keys and `time_default` it cites, `spec/correlate.md` 0.8, as this
engine reads them.

### Points still open

| Point | Section | This engine |
|---|---|---|
| An integer literal outside the signed 64-bit range | Reports | not an integer: `time_ms` is missing (reject); `received_ms` is absent |

### Readings where the text allows a choice (no vector depends on them)

| Point | Section | This engine |
|---|---|---|
| Lateness max or min over equal values, one integer and one binary64 | Entity measures, Source measures | the first in window (or key) order, in its own type |
| A source forgotten that never had a rule evaluated | Tick, step 3 | still gives its `forget` event |
| A tick that runs with no entities | Tick | gives no events but sets `last_tick` |
