# Disagreements and open points: Erlang engine

## Vectors against the specification

None. Every vector under `packs/correlate-*/vectors/` and
`spec/correlate-load-vectors/` agrees with `spec/correlate.md` (0.5) and
`spec/correlate-assign.md` (0.3) as this engine reads them.

## Open points the specifications leave undecided

No vector covers these cases. The table gives the reading this engine takes.

| Point | Section | This engine |
|---|---|---|
| An integer literal outside the signed 64-bit range | correlate.md, Reports | OTP decodes it as an arbitrary-precision integer, and the engine accepts it. |
| `same` between booleans, arrays or objects | correlate.md, Tests | Compared by exact term equality. |
