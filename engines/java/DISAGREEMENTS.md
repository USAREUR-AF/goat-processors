# Disagreements

No vector contradicts the specification as this engine reads it.

## Readings the vectors do not settle

Cases the spec leaves open and no vector covers. Each one names the choice
this engine makes.

- Tests, stopping at a failure. The vectors show that `gate` and `confirm`
  tests stop at the first failure for a pair (02, 09, 10, 12). This engine
  also stops at the first failure for each member in `hold`, and runs the hold
  tests against every other member, even after one member has passed.
- Tests, `course`. Skipped when either entity has no `speed_ms`, as well as
  when either speed is below `min_speed_ms`.
- Tests, course/speed/hae. "Last reported" means the value in the entity's
  most recent report: a later report without the key makes the value absent.
- Association, dissolve. The remaining member keeps its `hold_failures`.
  The spec resets the count only for the entity that leaves.
