# Disagreements and interpretations

No vector contradicts specification 0.3 as this engine reads it. The points
0.2 left open (what counts as an integer, `null` for a key named only by a
`same` test, `@env` when `type` has fewer than three elements) are settled by
0.3 and removed from this file. The entry below is a place where 0.3 is still
silent, and the reading this engine takes. No vector covers it.

## Integers outside the signed 64-bit range

- Spec: "Reports" says an integer is a JSON number written without a fraction
  or an exponent, but sets no range. A literal such as `99999999999999999999`
  is an integer by that wording.
- The engine holds integers as signed 64-bit values. A literal outside that
  range is kept as a number that is not an integer: as `time_ms` it is
  rejected with `missing:time_ms`, as `stale_ms` it is treated as absent, and
  it is still accepted where a number is required.
