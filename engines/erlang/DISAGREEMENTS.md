# Disagreements

None. No vector contradicts the specification.

## Points the specification leaves open

The engine resolves these as below. Where a vector settles the point, it is named.

| Point | Spec section | Engine behaviour | Settled by |
|---|---|---|---|
| Whether a stage keeps running after a test fails | Association, Trace | Tests in a stage stop at the first failure; the `count` record follows | gnn 02, 09, 10 |
| `stage` of the `count` record when a gate test failed | Trace | Always `confirm` | gnn 02, 10 |
| `entity` on a `missing:<key>` reject | Reports, Events | Omitted; only `out-of-order` carries `entity` | gnn 08 |
| Hold tests after one member's test fails | Association (hold) | Stop for that member, as in gate and confirm; every member is still tried | no vector (each hold has one test) |
| `course` test when `course` is present but `speed_ms` absent | Tests | Skipped, as is `speed` when `course` is absent | no vector |
| "Last reported" `course`, `speed_ms`, `hae`, `ce`, `stale_ms` | Tests, Association | Taken from the entity's last accepted report; absent there means absent | no vector |
| `hold_failures` of the remaining member after a dissolve | Association (hold) | Unchanged | no vector |
| A required key present with value `null` | Reports | Treated as missing | no vector |
