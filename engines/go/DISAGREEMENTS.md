# Disagreements and open points: Go engine

## Vectors that contradict the specification

None. Every vector in `packs/*/vectors/` and `spec/correlate-load-vectors/`
agrees with `spec/correlate.md` 0.4 and `spec/correlate-assign.md` 0.2 as this
engine reads them.

## Points still open

No vector covers any of them; each is listed with what this engine does.

| Point | Section | This engine |
|---|---|---|
| An integer literal outside the signed 64-bit range (open point of `correlate.md` 0.4) | Reports | not an integer: the field is treated as absent |
| `same` between booleans, arrays or objects (open point of `correlate.md` 0.4) | Tests | booleans equal when both are the same boolean; arrays and objects equal when their JSON encodings (object keys sorted) are identical |
| Whether `method` may appear after other directives | `correlate-assign.md` Pack | anywhere in the file; each method's directive rules are checked after the whole file is read |

## Quality (`quality/`, `spec/quality.md` 0.1)

### Vectors that contradict the specification

None. Every vector in `packs/quality-*/vectors/` and `spec/quality-load-vectors/`
agrees with `spec/quality.md` 0.1 as this engine reads it.

### Points still open

| Point | Section | This engine |
|---|---|---|
| An integer literal outside the signed 64-bit range | Reports | not an integer: `time_ms` is missing (reject); `received_ms` is absent |
| Two sources whose key strings collide (`a/b` + `c` and `a` + `b/c`) | Reports | one entity `a/b/c`; its source is the `track.source_id` of its first accepted report |
| A forwarded `ce` that overflows binary64 after many `downgrade` factors | Forwarding | the forwarded `ce` is +Inf (binary64 arithmetic, no check) |
| Whitespace other than space and tab inside a `pack.def` line | Pack | a carriage return also separates tokens (CRLF files load); any other whitespace is part of a token, which then fails its check |

### Readings where the text allows a choice (no vector depends on them)

| Point | Section | This engine |
|---|---|---|
| `#` inside a line | Pack | starts a comment wherever it appears |
| A source forgotten that never had a rule evaluated | Tick, step 3 | still gives its `forget` event |
| A tick that runs with no entities | Tick | gives no events but sets `last_tick` |
