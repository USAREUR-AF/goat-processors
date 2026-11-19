# Disagreements and open points: Erlang engine

## Vectors against the specification

None. Every vector under `packs/*/vectors/`, `spec/correlate-load-vectors/` and
`spec/quality-load-vectors/` agrees with `spec/correlate.md` (0.4),
`spec/correlate-assign.md` (0.2) and `spec/quality.md` (0.1) as this engine reads them.

## Open points the specifications leave undecided

No vector covers these cases. The table gives the reading this engine takes.

| Point | Section | This engine |
|---|---|---|
| Ties for the least total cost (correlate-assign.md defines no rule) | correlate-assign.md, Assignment, step 3 | Takes whichever assignment the Hungarian solver reaches first: rows in key order, columns in creation order, then each row's own *alone*. Other engines may choose differently. |
| An integer literal outside the signed 64-bit range | correlate.md, Reports | OTP decodes it as an arbitrary-precision integer, and the engine accepts it. |
| `same` between booleans, arrays or objects | correlate.md, Tests | Compared by exact term equality. |
| An integer literal outside the signed 64-bit range | quality.md, Reports | As for correlate: accepted as an arbitrary-precision integer. |
| Two entity keys that collide (`a/b` + `c` and `a` + `b/c`) | quality.md, Reports | The second report is taken as a report of the first entity; its source stays the first entity's. |
| A forwarded `ce` that overflows binary64 | quality.md, Forwarding | OTP raises `badarith` on float overflow, so `ingest` would crash rather than forward `inf`. |
| Whitespace other than space and tab in a `pack.def` line | quality.md, Pack | Not a separator: it stays inside the token (a `\r` at line end joins the last value, which then fails a number, integer or name check, but not a `pack` or `version` value). |
| `hypot` in `speed_err` | quality.md, Samples | Computed as `sqrt(de*de + dn*dn)`; OTP has no `math:hypot`. Agrees with `hypot` well within the vector tolerance at these magnitudes. |
