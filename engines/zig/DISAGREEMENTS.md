# Disagreements and open points, zig engine

## Vectors that contradict the specification

None. Every load vector (01 to 21) and every scenario vector (01 to 32)
agrees with `spec/correlate.md` 0.4 and `spec/correlate-assign.md` 0.2 as
this engine reads them.

## Points `correlate-assign.md` 0.2 leaves open

| Point | This engine |
|---|---|
| Order of the `gate` trace records within a source. The spec places the `cost` records "after a source's entries are computed", but does not order the gate records among themselves. | Entities of R in key order, then columns in creation order, then T's others in key order; all before the first `cost` record. Vectors 23, 25 and 31 agree. |

## Points `correlate.md` 0.4 leaves open

| Point | This engine |
|---|---|
| An integer literal outside the signed 64-bit range | `std.json` does not return it as an integer, so it is the wrong type where an integer is required. |
| `same` between booleans, arrays or objects | Compared structurally: equal when of the same kind and equal element by element. |

## Quality: vectors that contradict the specification

None. Every quality load vector (01 to 45) and every scenario vector (q01 to
q15) agrees with `spec/quality.md` 0.1 as this engine reads it.

## Points `quality.md` 0.1 leaves open

| Point | This engine |
|---|---|
| An integer literal outside the signed 64-bit range | As for correlate: `std.json` does not give it as an integer, so `time_ms` is missing and `received_ms` absent. In `pack.def`, an integer that does not fit `i64` is a load error. |
| Two sources whose key strings collide | Entities are keyed by the key string alone, so the two reports are one entity; its source stays the `track.source_id` of its first report. Sources are compared by their `track.source_id` string. |
| A forwarded `ce` that overflows binary64 | The product is the binary64 result, `+inf`; no check is made. |
| Whitespace other than space and tab inside a `pack.def` line | It is part of a token. A trailing CR (CRLF line ends) therefore joins the last token of the line, which is a load error wherever that token must be a number or an integer. |

## Readings of `quality.md` 0.1 the vectors do not fix

| Point | This engine |
|---|---|
| `rule` followed directly by a parameter (`rule scope=entity ...`) | The first token is the name; `=` is not a name character, so it is a load error ("no name"). Load vector 19 agrees. |
| `#` inside a token | Starts a comment anywhere on the line, as the Pack section says. |
