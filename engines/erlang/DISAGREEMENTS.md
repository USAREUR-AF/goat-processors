# Disagreements and open points: Erlang engine

## Vectors against the specification

None. Every vector under `packs/*/vectors/`, `spec/correlate-load-vectors/` and
`spec/fuse-load-vectors/` agrees with `spec/correlate.md` (0.4),
`spec/correlate-assign.md` (0.2) and `spec/fuse.md` (0.1) as this engine reads them.

## Open points the specifications leave undecided

No vector covers these cases. The table gives the reading this engine takes.

| Point | Section | This engine |
|---|---|---|
| Ties for the least total cost (correlate-assign.md defines no rule) | correlate-assign.md, Assignment, step 3 | Takes whichever assignment the Hungarian solver reaches first: rows in key order, columns in creation order, then each row's own *alone*. Other engines may choose differently. |
| An integer literal outside the signed 64-bit range | correlate.md, Reports | OTP decodes it as an arbitrary-precision integer, and the engine accepts it. |
| `same` between booleans, arrays or objects | correlate.md, Tests | Compared by exact term equality. |
| An integer literal outside the signed 64-bit range | fuse.md, Reports | As for correlate: accepted as an arbitrary-precision integer. |
| `majority`, `max`, `min` between integers above 2^53 | fuse.md, Attributes | Integers are compared exactly; an integer and a float are compared by Erlang's numeric comparison. |
