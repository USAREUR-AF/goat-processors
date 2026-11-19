# Disagreements and open points: Erlang engine

## Vectors against the specification

None. Every vector under `packs/*/vectors/`, `spec/correlate-load-vectors/`,
`spec/filter-load-vectors/`, `spec/fuse-load-vectors/` and `spec/quality-load-vectors/`
agrees with `spec/correlate.md` (0.7), `spec/correlate-assign.md` (0.5), `spec/filter.md` (0.1),
`spec/fuse.md` (0.2) and `spec/quality.md` (0.1) as this engine reads them.

## Open points the specifications leave undecided

No vector covers these cases. The table gives the reading this engine takes.

| Point | Section | This engine |
|---|---|---|
| An integer literal outside the signed 64-bit range | correlate.md, Reports | OTP decodes it as an arbitrary-precision integer, and the engine accepts it. |
| `same` between booleans, arrays or objects | correlate.md, Tests | Compared by exact term equality. |
| An integer literal outside the signed 64-bit range | fuse.md, Reports | As for correlate: accepted as an arbitrary-precision integer. |
| `majority`, `max`, `min` between integers above 2^53 | fuse.md, Attributes | Integers are compared exactly; an integer and a float are compared by Erlang's numeric comparison. |
| Filter: an integer above 2^53 in magnitude in a `key` eq, in or range, or a `speed` or `altitude` range | filter.md, Conditions | Range bounds compare the exact integer with the pack's binary64 (Erlang mixed comparison); `key` eq and in compare with `==` against the pack number's binary64. |
| Filter: a report or reference within 1 m of a pole | filter.md, Geometry | The formulas as written; `cos(rad(lat))` near 0 gives a large or infinite-looking longitude step, and an exact 0 raises `badarith`. |
| Filter: `version` | filter.md, Pack | Checked to be one token; its semver form is not checked (no vector tests it). |
| An integer literal outside the signed 64-bit range | quality.md, Reports | As for correlate: accepted as an arbitrary-precision integer. |
| Two entity keys that collide (`a/b` + `c` and `a` + `b/c`) | quality.md, Reports | The second report is taken as a report of the first entity; its source stays the first entity's. |
| A forwarded `ce` that overflows binary64 | quality.md, Forwarding | OTP raises `badarith` on float overflow, so `ingest` would crash rather than forward `inf`. |
| Whitespace other than space and tab in a `pack.def` line | quality.md, Pack | Not a separator: it stays inside the token (a `\r` at line end joins the last value, which then fails a number, integer or name check, but not a `pack` or `version` value). |
| `hypot` in `speed_err` | quality.md, Samples | Computed as `sqrt(de*de + dn*dn)`; OTP has no `math:hypot`. Agrees with `hypot` well within the vector tolerance at these magnitudes. |
