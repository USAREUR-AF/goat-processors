# Disagreements

No vector contradicts specification 0.2 as this engine reads it. The four
readings listed under 0.1 (stopping at a failure in `hold`, `course` without
`speed_ms`, values from the last report, the dissolved group's remaining
member) are all settled by 0.2 and are gone from this file.

## Readings the vectors do not settle

The spec leaves these cases open and no vector covers them. Each one names
the choice this engine makes.

- Tests, `same`, numbers. The spec does not say whether an integer and a
  float with the same value are equal (`1` and `1.0`). This engine compares
  numbers by value, so they are equal.
- Tests, `@env`. The spec does not say what `@env` is when `type` has fewer
  than three `-`-separated elements. This engine treats it as absent.
