# Disagreements and open points, zig engine

## Vectors that contradict the specification

None. Every load vector (01 to 21) and every scenario vector (01 to 32)
agrees with `spec/correlate.md` 0.4 and `spec/correlate-assign.md` 0.2 as
this engine reads them.

## Filter: vectors that contradict `filter.md` 0.1

None. Every filter load vector (01 to 50) and every filter scenario vector
(01 to 27) agrees with `spec/filter.md` 0.1 as this engine reads it.

## Filter: points `filter.md` 0.1 leaves open

| Point | This engine |
|---|---|
| An integer literal in a report outside the signed 64-bit range | `std.json` keeps it as a number string: the wrong type for `time_ms` and `stale_ms`, a number (read as the nearest binary64) for `lat`, `lon`, `key`, `speed`, `altitude`. |
| `key` and `speed`/`altitude` on an integer above 2^53 | The integer is converted to the nearest binary64 before comparing. |
| A reference within 1 m of a pole | The formula is evaluated as written; no special case. |
| Differences of two times (`near` age, `interval`, tick `age`) that overflow int64 | Computed in i128; a trace value outside int64 is written as a float. |
| `version` | Any single token is accepted (load vector 03 uses `version 1`); no semver check. |

## Points `correlate-assign.md` 0.2 leaves open

| Point | This engine |
|---|---|
| Order of the `gate` trace records within a source. The spec places the `cost` records "after a source's entries are computed", but does not order the gate records among themselves. | Entities of R in key order, then columns in creation order, then T's others in key order; all before the first `cost` record. Vectors 23, 25 and 31 agree. |

## Points `correlate.md` 0.4 leaves open

| Point | This engine |
|---|---|
| An integer literal outside the signed 64-bit range | `std.json` does not return it as an integer, so it is the wrong type where an integer is required. |
| `same` between booleans, arrays or objects | Compared structurally: equal when of the same kind and equal element by element. |
