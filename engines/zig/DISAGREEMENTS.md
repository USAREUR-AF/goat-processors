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
