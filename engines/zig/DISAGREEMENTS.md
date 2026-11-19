# Disagreements and open points, zig engine

## Vectors that contradict the specification

None. Every load vector (01 to 42) and every scenario vector (01 to 44)
agrees with `spec/correlate.md` 0.5 and `spec/correlate-assign.md` 0.3 as
this engine reads them.

## Points `correlate-assign.md` 0.3 leaves open

None found. (The gate-record order left open in 0.2 is now stated in Trace.)

## Points `correlate.md` 0.5 leaves open

| Point | This engine |
|---|---|
| An integer literal outside the signed 64-bit range | `std.json` does not return it as an integer, so it is the wrong type where an integer is required. |
| `same` between booleans, arrays or objects | Compared structurally: equal when of the same kind and equal element by element. |
