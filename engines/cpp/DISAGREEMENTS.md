# Open points

No vector contradicts correlate.md 0.8 or correlate-assign.md 0.6 as this
engine reads them, including the new time quality and time offset vectors
(scenario vectors 54-56, load vectors 61-73) and the earlier `restart`, `bias`
and `margin` vectors (scenario vectors 45-53, load vectors 43-60). The 0.4/0.2 entries on ties in the least total and on
where `method` may appear are settled by these versions (Ranking; Pack) and
removed. The entries below are points the specifications leave open, and
the reading this engine takes. No vector covers any of them.

## Integers outside the signed 64-bit range (correlate.md "Open points")

- The engine holds integers as signed 64-bit values. A literal outside that
  range is kept as a number that is not an integer: as `time_ms` it is
  rejected with `missing:time_ms`, as `stale_ms` it is treated as absent, and
  it is still accepted where a number is required.

## `same` between booleans, arrays or objects (correlate.md "Open points")

- The engine compares them structurally: booleans by value, arrays element by
  element in order, objects by equal key sets with equal values; values of
  different JSON kinds are never equal.

## A repeated parameter within one `filter`, `maneuver` or test line (correlate.md "Open points")

- A load error. The same holds for `restart` and `bias` lines, which take
  exactly their named parameters.

## A repeated parameter or an empty value on a `time_default` line (correlate.md "Pack")

- correlate.md 0.8 makes a repeated `error_ms` or `state` a load error; the
  engine also refuses a parameter with an empty name (`=20`), and an empty
  `state=` value, which is not one of the three states. An empty
  `error_ms=` does not parse as a number.

## Decimal spellings in `pack.def` (correlate.md "Open points")

- A number may have a leading sign, a fraction, an exponent, and `.5` or `5.`;
  `inf` and `nan` do not parse. This includes the values of `restart`,
  `bias` and `margin`. `window` and `hypotheses` take digits with an
  optional sign only. `#` always starts a comment, inside a value too.
  `time_default error_ms` and `time_offset sigma_ms` take the same number
  spellings.

## How ranked assignments are found (correlate-assign.md "Ranking")

- The spec allows any exact method. The engine enumerates every assignment
  and sorts them by the Ranking order, which is exact and follows the tie rule
  directly; its cost grows exponentially with the number of rows and columns
  of one source, which is fine at vector sizes but not for large inputs.

## fuse.md 0.2

No vector contradicts fuse.md 0.2 as this engine reads it. The points below
are the readings this engine takes where the spec is open; no vector covers
them.

- Integers outside the signed 64-bit range (fuse.md "Open points", Reports):
  as for correlate above.
- `majority`, `max`, `min` between integers above 2^53 (fuse.md "Open
  points", Attributes): the engine compares every number as binary64, so two
  such integers that round to the same double are equal for `majority` and
  tie (to key order) for `max` and `min`.
- `inverse_variance` with one member (fuse.md "Kinematics"): the spec says
  every method gives that member's predicted filter, so the engine returns it
  as is rather than through `1/(1/pp)`, which can differ in the last bit.

# Filter (spec/filter.md 0.1)

No filter vector contradicts filter.md 0.1 as this engine reads it. The
entries below are its open points and the reading this engine takes. No
vector covers them.

## Integers above 2^53 and outside the signed 64-bit range (filter.md "Open points")

- Reports are read by the same JSON reader as the correlator, so the
  correlator entry above applies: a literal outside the signed 64-bit range
  is a number that is not an integer (`missing:time_ms`, or `stale_ms`
  absent). `key` eq, in and range, `speed` and `altitude` compare the
  binary64 value of an integer, so integers above 2^53 compare after
  rounding to binary64.

## A reference near a pole (filter.md "Open points", Geometry)

- The reference prediction divides by `R * cos(rad(lat))` as written. Near a
  pole the longitude can become very large; `wrap` then reduces a magnitude
  above 1e6 with `fmod(x, 360)` (exact) before the add-or-subtract loop, so it
  always ends, and passes an infinite or NaN longitude through unchanged.

# Quality 0.2

No quality vector contradicts quality.md 0.2 as this engine reads it,
including the time quality vectors (q16 to q20), the edge vectors (q21, q22)
and load vectors 46 to 62. Version 0.2 settles three points 0.1 left open, and
their entries are removed: a forwarded `ce` that overflows is now the largest
finite binary64 (Forwarding); line ends and whitespace in `pack.def` follow
Pack steps 1 to 5; colliding keys are one entity (Reports). The entries
below are the open point quality.md still lists, and readings this engine
takes where the text leaves room. No vector covers any of them.

## Integers outside the signed 64-bit range (quality.md "Open points", Reports)

- As for correlate: the literal is kept as a number that is not an integer.
  As `time_ms` the report is rejected with `missing:time_ms`; as
  `received_ms` it is absent (no `latency` sample). A `window` value too
  large for a signed 64-bit integer is read with `strtoll`, which saturates.

## A control character inside a comment (quality.md "Pack", steps 2 and 3)

- Step 2 comes before step 3, so the engine checks the whole line, comment
  included: a control character after `#` is a load error too.

## A repeated parameter or an empty value on a `time_default` line (quality.md "Pack")

- The line is read by the same code as correlate's (`parse_time_default`),
  with quality's number grammar for `error_ms`, so the correlate entry above
  applies: a repeated `error_ms` or `state` and an empty parameter name are
  load errors; an empty `state=` is not a time state, and an empty
  `error_ms=` is not a number.

## Ties among `lateness_max`, `lateness_min` and `time_error_max` samples (quality.md "Entity measures")

- A tie keeps the first such sample in window order. The value is the same
  either way; only an integer against an equal binary64 `lateness` (a clock
  that was a mean of two) could differ in how it is written, which the
  vector comparison treats as equal.
