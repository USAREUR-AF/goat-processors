# Disagreements and open points: Go engine

## Vectors that contradict the specification

None. Every vector in `packs/correlate-*/vectors/` and
`spec/correlate-load-vectors/` agrees with `spec/correlate.md` 0.4 and
`spec/correlate-assign.md` 0.2, and every vector in `packs/fuse-*/vectors/` and
`spec/fuse-load-vectors/` agrees with `spec/fuse.md` 0.1, as this engine reads them.

## Points still open

No vector covers any of them; each is listed with what this engine does.

| Point | Section | This engine |
|---|---|---|
| An integer literal outside the signed 64-bit range (open point of `correlate.md` 0.4) | Reports | not an integer: the field is treated as absent |
| `same` between booleans, arrays or objects (open point of `correlate.md` 0.4) | Tests | booleans equal when both are the same boolean; arrays and objects equal when their JSON encodings (object keys sorted) are identical |
| Whether `method` may appear after other directives | `correlate-assign.md` Pack | anywhere in the file; each method's directive rules are checked after the whole file is read |
| An integer literal outside the signed 64-bit range (open point of `fuse.md` 0.1) | fuse Reports | as correlate: not an integer, so `time_ms` is missing and `stale_ms` absent |
| `majority`, `max`, `min` between integers above 2^53 (open point of `fuse.md` 0.1) | fuse Attributes | compared as binary64 |
