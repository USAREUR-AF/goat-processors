# Disagreements and interpretations

No vector contradicts the specification as this engine reads it. The entries
below are places where two parts of the specification differ, or where the
specification is silent, and the reading this engine takes.

## Reject for a missing key carries no `entity`

- Vector: `gnn/08-rejections`, step 0, field `expect[0]` (no `entity` key).
- Spec: "Reports" gives the event as `{"ev":"reject","reason":"missing:<key>"}`;
  "Events" says `reject` has `entity` "when the key is known".
- In step 0 the report has `track.source_id` and `uid`, so the key could be
  built, but the vector has no `entity`. That matches the "Reports" form. The
  engine never adds `entity` to a `missing:` reject and adds it only to
  `out-of-order`.

## Tests in a stage stop at the first failure

- Vectors: `gnn/02` step 1, `gnn/09` step 1, `window/12` step 1.
- Spec: "Association" says to run the `gate` tests and, if all passed, the
  `confirm` tests. It does not say whether the tests after a failure in the
  same stage still run.
- The vectors show no trace record after a failing test in a stage. The
  engine stops each stage, `hold` included, at its first failure. `hold`
  still runs for every other member of the group.

## The `count` record's stage is `confirm`

- Spec: "Trace" names the `count` record but not its stage. The vectors give
  it `"stage":"confirm"` even when a `gate` test failed. The engine does the
  same.

## `course` and `speed` when a value is missing

- Spec: "Tests" skips the test "when either entity lacks the value or either
  speed is below `min_speed_ms`".
- The engine skips `course` when either entity lacks `course` or `speed_ms`:
  a missing speed cannot be shown to be at or above `min_speed_ms`. If both
  speeds are 0 and `min_speed_ms` is 0, `slow/fast` is undefined, and the
  engine takes the `speed` value as 0. No vector covers either case.

## A report value of the wrong type

- Spec: "Reports" gives the types but no reason for a wrong one. The engine
  rejects a required key that is null or of the wrong type with
  `missing:<key>`, and treats an optional key that is null or of the wrong
  type as absent. No vector covers this.
