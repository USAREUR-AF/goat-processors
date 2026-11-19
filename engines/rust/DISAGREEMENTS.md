# Disagreements with the vectors

No vector contradicts `spec/correlator-spec.md` as this engine reads it. The
points below are places where the specification is silent or admits two
readings. The engine follows the vectors where they decide the point. None of
these is a spec or vector change; they are listed so the specification can
state them.

| # | Where | Spec section | What the spec says | What the vectors show, and what the engine does |
|---|---|---|---|---|
| 1 | `gnn/02-far-apart-stay-separate` step 1; `gnn/09-opposite-courses-refused` step 1; `gnn/10-environment-differs` step 1 | Association, "associate" | "run the `gate` tests, then, if all passed, the `confirm` tests" | Within a stage, tests stop at the first failing test: a failed `mahalanobis` is not followed by the `same` tests, and a failed `course` is not followed by `speed` or `altitude`. The engine stops each stage at the first failure. |
| 2 | no vector decides it | Association, "hold" | "Run the pack's `hold` tests between A and each other member" | The engine applies the rule of point 1 to each member (stops that member's hold tests at the first failure) and still runs every member. Both shipped packs have one hold test, so no vector distinguishes. |
| 3 | `gnn/02-far-apart-stay-separate` step 1 | Trace | The count record's `stage` is not named | The count record has `"stage":"confirm"` even when the gate failed and no confirm test ran. The engine writes `confirm`. |
| 4 | `gnn/08-rejections` step 0 | Reports; Events | Reports gives `{"ev":"reject","reason":"missing:<key>"}`; the Events table says `entity` "when the key is known" | Step 0 has both `track.source_id` and `uid` but lacks `lon`, and the expected event has no `entity`. The engine follows the Reports form: a `missing:` reject never carries `entity`. |
| 5 | `gnn/06-third-source-joins` step 4; `gnn/07-nearest-candidate-wins` step 3 | Association, "associate"; Trace | `d²` "is in the trace as test `rank`"; its `limit` and `pass` are not given | One `rank` record per candidate whose count reached `confirm_count`, in key order, after all candidates' tests, with `limit` null and `pass` true. The engine does the same. |
| 6 | no vector decides it | Association, "hold" | A leaving entity's hold failure count is reset; the remaining member of a dissolved group is "ungrouped" | The engine leaves the remaining member's `hold_failures` unchanged. |
