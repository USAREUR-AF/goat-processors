# Correlate specification

Status: Written. Version 0.3. Every language's engine implements this document
and passes every vector. Engines are written from this document and the
vectors, never from another engine's source.

## What the correlator does

The correlator decides when reports about tracks from different sources
describe the same object, groups them, and keeps one estimate per group. It
does this with a small number of fixed, named tests whose parameters come from
a pack, and it records every test it runs.

An engine has four operations:

| Operation | Returns |
|---|---|
| `load_pack(dir)` | a pack, or an error |
| `ingest(report)` | the events and the trace for that report |
| `tick(now_ms)` | the events and the trace for that time |
| `snapshot()` | the whole state, as a map |

The correlator is deterministic. Its only clock is the time carried in the
input (`time_ms` of a report, `now_ms` of a tick). It never reads the wall
clock, never uses randomness, and visits every collection in the orders this
document defines. The same pack and the same sequence of calls give the same
events and trace in every engine.

## Reports

A report is a map from shared-model key to value, the entity
`goat-transformers` decodes from any format. The correlator reads these keys:

| Key | Type | Required | Use |
|---|---|---|---|
| `track.source_id` | string | yes | which source reported the track |
| `uid` | string | yes | the source's identifier for the track |
| `time_ms` | int | yes | time the report is valid, epoch ms |
| `lat`, `lon` | float, deg | yes | position |
| `hae` | float, m | no | height, for the `altitude` test and output |
| `ce` | float, m | no | one-sigma horizontal error; the pack's `default_ce_m` when absent |
| `course` | float, deg | no | with `speed_ms`, a velocity measurement |
| `speed_ms` | float, m/s | no | with `course`, a velocity measurement |
| `type` | string | no | CoT type token; its third `-`-separated element is the environment `@env` (`a-f-A-M-F` gives `A`) |
| `stale_ms` | int | no | absolute time after which the report is stale |
| any other key | | no | read only by a `same` test that names it |

The entity key is `<track.source_id>/<uid>`. Keys are compared as byte
strings, and "key order" below means ascending byte order.

A required key is missing when it is absent, `null`, or of the wrong type:
`track.source_id` and `uid` must be strings, `time_ms` an integer, `lat` and
`lon` numbers. A report with a missing required key is rejected with event
`{"ev":"reject","reason":"missing:<key>"}`, checking keys in the order of the
table; this event never carries `entity`, even when the key could be built.
An optional key that is `null` or of the wrong type (`hae`, `ce`, `course`,
`speed_ms` must be numbers, `type` a string, `stale_ms` an integer) is treated
as absent, and so is a `ce` of 0 or below. An integer is a JSON number written
without a fraction or an exponent (`1000`, not `1000.0` or `1e3`); an integer
is accepted where a number is required. A `null` value for any key is the
same as the key being absent. A report whose `time_ms` is earlier than its entity's last report is
rejected with `{"ev":"reject","entity":<key>,"reason":"out-of-order"}`.
A rejected report changes no state.

## Frame

All geometry is done in one local plane, metres east and north of a reference
point. The reference is the `lat`/`lon` of the first report the engine
accepts, and it never moves.

- `R = 6371008.8` m, `rad(x) = x * pi / 180`, `deg(x) = x * 180 / pi`.
- `dlon = lon - lon0`, brought into (-180, 180] by adding or subtracting 360.
- `east = R * rad(dlon) * cos(rad(lat0))`, `north = R * rad(lat - lat0)`.
- Back to degrees: `lat = lat0 + deg(north / R)`,
  `lon = lon0 + deg(east / (R * cos(rad(lat0))))`, then `lon` brought into
  (-180, 180].

The plane is accurate within a few hundred kilometres of the reference.

## Track estimate

Each entity keeps a constant-velocity Kalman filter, run as two independent
axes, east and north. Each axis holds position `p`, velocity `v` and the
symmetric covariance `pp`, `pv`, `vv`. Parameters come from the pack's
`filter` line: `accel_var` (q, m²/s⁴), `default_ce_m`, `vel_sigma_ms`,
`unknown_vel_ms`.

Velocity measurement, when the report has both `course` and `speed_ms`:
`ve = speed_ms * sin(rad(course))`, `vn = speed_ms * cos(rad(course))`.

**First report.** Per axis: `p` = measured position, `v` = measured velocity
or 0, `pp = ce²`, `pv = 0`, `vv = vel_sigma_ms²` when a velocity was measured,
else `unknown_vel_ms²`.

**Later reports**, per axis, with `dt = (time_ms - last_time_ms) / 1000`:

1. Predict:
   `p = p + v*dt`;
   `pp = pp + 2*dt*pv + dt²*vv + q*dt⁴/4`;
   `pv = pv + dt*vv + q*dt³/2`;
   `vv = vv + q*dt²`.
2. Position update with measurement `z` and `r = ce²`:
   `s = pp + r`, `k1 = pp/s`, `k2 = pv/s`, `y = z - p`;
   `p = p + k1*y`, `v = v + k2*y`;
   `pp = (1-k1)*pp`, `pv = (1-k1)*pv`, `vv = vv - k2*pv_before`.
3. Velocity update, only when a velocity was measured, with `z` and
   `r = vel_sigma_ms²`:
   `s = vv + r`, `k1 = pv/s`, `k2 = vv/s`, `y = z - v`;
   `p = p + k1*y`, `v = v + k2*y`;
   `pp = pp - k1*pv_before`, `pv = (1-k2)*pv`, `vv = (1-k2)*vv`.

`_before` is the value at the start of that step. Every right-hand side in a
step uses the values from the start of the step.

**Prediction** of an entity to time `t` applies step 1 with
`dt = (t - last_time_ms) / 1000` to a copy, which may be negative, and never
changes the entity.

## Tests

A test compares entity A, the one just reported, with entity B predicted to
A's `time_ms`. Every test yields `value`, `limit` and `pass`, and is written
to the trace. Distances are in the plane, between A's filtered position and
B's predicted position.

| Test | Parameters | `value` | Passes when |
|---|---|---|---|
| `distance` | `max_m` | distance, m | `value < max_m` |
| `window` | `multiplier`, `window_m`, `err_min_m`, `err_max_m` | distance, m | `value < multiplier * sqrt(ea² + eb²) + window_m`, where `e` is the entity's last `ce` (or `default_ce_m`) clamped to [`err_min_m`, `err_max_m`]; `limit` is that right-hand side |
| `mahalanobis` | `gate` | `d²` (below) | `value < gate` |
| `course` | `max_deg`, `min_speed_ms` | `min(abs(ca-cb), 360-abs(ca-cb))`, deg | `value <= max_deg` |
| `speed` | `max_pct`, `min_speed_ms` | `abs(1 - slow/fast) * 100` | `value <= max_pct` |
| `altitude` | `max_m` | `abs(hae_a - hae_b)`, m | `value <= max_m` |
| `same` | `key` | — | the two values are equal, or both absent |

`d² = sum over east, north of (pa - pb)² / (pp_b + ce_a²)`, with `pb` and
`pp_b` from B's prediction and `pa` from A's filter.

Within a stage (`gate`, `confirm`, or `hold` against one member), tests run
in pack order and stop at the first that fails; the tests after it are not
run and have no trace record.

Every value a test reads (`course`, `speed_ms`, `hae`, `ce`, `type`, a `same`
key) comes from the entity's last accepted report; a key absent from that
report is absent, whatever earlier reports held. A `course` test is skipped,
and passes, when either entity lacks `course` or `speed_ms`, or either speed
is below `min_speed_ms`. A `speed` test is skipped, and passes, when either
entity lacks `speed_ms` or either speed is below `min_speed_ms`; when the
faster speed is 0 its `value` is 0. An `altitude`
test is skipped, and passes, when either entity lacks `hae`. A skipped test
has trace `value` and `limit` null and `"skipped":true`. For `same`, the trace
`value` and `limit` are the two values (null when absent). `@env` as a `same`
key names the environment taken from `type`, and is absent when `type` is
absent or has fewer than three elements. `same` compares strings byte for
byte and numbers by value (`1` equals `1.0`); a string never equals a number.

## Association

**Groups.** A group is a set of two or more entities believed to be one
object. Groups are named `g1`, `g2`, ... in the order they are created; the
counter never reuses a number. An entity is in at most one group. Unless the
pack says `same_source allow`, a group never holds two entities with the same
`track.source_id`.

**On each accepted report** for entity A, after its filter is updated:

- **A is in a group G: hold.** Take the other members of G in key order and
  run the pack's `hold` tests between A and each in turn. The hold passes at
  the first member for which every test passes, and no later member is tested. A pass sets A's hold failure count to 0; a failure adds 1.
  When the count reaches `hold_failures`, A leaves G (event `leave`, reason
  `hold`) with its count reset. If G is left with one member, G is dissolved
  (event `dissolve`) and its last member is ungrouped with its hold failure
  count set to 0. An entity that leaves a
  group runs no association on the same report.
- **A is not in a group: associate.** The candidates are every other entity B
  in key order, excluding B with A's `track.source_id`, and excluding B in a
  group that already holds an entity with A's `track.source_id` (both unless
  `same_source allow`). For each candidate, run the `gate` tests, then, if all
  passed, the `confirm` tests. The pair's count becomes count + 1 when every
  test ran and passed, else 0. Counts are kept per unordered pair.
  Of the candidates whose count has reached `confirm_count`, the one with the
  smallest `d²` is chosen, ties to key order. `d²` is computed for this choice
  whether or not a `mahalanobis` test is in the pack. After every candidate
  has been tested, each candidate whose count has reached `confirm_count` gets
  one trace record, in key order: stage and test `rank`, `value` its `d²`,
  `limit` null, `pass` true. If the chosen B is in a group, A joins it (event `join`);
  otherwise a new group of A and B is created (event `correlate`). The chosen
  pair's count is reset to 0.

**On each tick** at `now_ms`:

1. **Staleness**, entities in key order. An entity is stale when
   `now_ms - last_time_ms > stale_ms` of the pack, or when its last report had
   `stale_ms` and `now_ms >= stale_ms`. A stale entity in a group leaves it
   (event `leave`, reason `stale`), the group is dissolved if one member is
   left, and the entity is removed (event `drop`), with every pair count that
   names it.
2. **Fused output**, groups in creation order. The primary member is chosen by
   the pack's `output` line: `priority` takes the lowest `priority` number for
   the member's source (100 for a source the pack does not list), ties to key
   order; `latest` takes the greatest `last_time_ms`, ties to key order. The
   event `fused` gives the primary's filter predicted to `now_ms`, in degrees,
   with `course = deg(atan2(ve, vn))` in [0, 360) and `speed_ms = hypot(ve,
   vn)`, plus the primary's last `hae` when it has one.

## Events

Each event is a JSON object. `members` lists are in key order.

| Event | Fields |
|---|---|
| `reject` | `reason`; `entity` only with reason `out-of-order` |
| `new` | `entity` |
| `correlate` | `group`, `members` |
| `join` | `group`, `entity` |
| `leave` | `group`, `entity`, `reason` (`hold` or `stale`) |
| `dissolve` | `group`, `entity` (the remaining member) |
| `drop` | `entity` |
| `fused` | `group`, `primary`, `members`, `lat`, `lon`, `course`, `speed_ms`, `hae` when known |

Event order for a report: `new` (first report only), then the association
events in the order they happen. For a tick: per stale entity `leave`,
`dissolve`, `drop`, then one `fused` per group.

## Trace

Each test run is one trace record:
`{"stage", "a", "b", "test", "value", "limit", "pass"}`, plus
`"skipped": true` for a skipped test. `stage` is `gate`, `confirm`, `hold` or
`rank`; `a` and `b` are entity keys. A pair's count after its tests is a
record with stage `confirm` (also when a `gate` test failed), `"test":"count"`,
`value` the new count, `limit` the pack's `confirm_count`, and `pass` true
when it has reached it. Records are in the order
the tests run.

## Snapshot

`snapshot()` returns `{"ref": [lat0, lon0] or null, "entities": {...},
"groups": {...}, "counts": {...}, "next_group": n}`. Each entity holds
`last_time_ms`, `group` (or null), `hold_failures` and `filter`
(`{"east": [p, v, pp, pv, vv], "north": [...]}`); `groups` maps a group name
to its members; `counts` maps `"<key>|<key>"` (keys in order) to the count.

## Pack

A pack is a directory `packs/<name>/` holding `pack.def` and `vectors/`.
`pack.def` is line-oriented UTF-8; `#` starts a comment; blank lines are
ignored. Each line is a directive and `name=value` parameters.

```
pack           <name>
version        <semver>
filter         accel_var=<q> default_ce_m=<m> vel_sigma_ms=<m/s> unknown_vel_ms=<m/s>
gate           <test> <param>=<value> ...
confirm        <test> <param>=<value> ...
hold           <test> <param>=<value> ...
confirm_count  <n>
hold_failures  <n>
stale_ms       <ms>
same_source    forbid | allow
output         priority | latest
priority       <source_id> <n>
```

`gate`, `confirm`, `hold` and `priority` repeat; their order is the order the
tests run. Every other directive appears once, and `pack`, `version`,
`filter`, `confirm_count`, `hold_failures`, `stale_ms` are required;
`same_source` defaults to `forbid` and `output` to `priority`. A test name or
parameter not in the tests table, a missing parameter, or a value that does
not parse is a load error. Numbers are decimal; `same` takes a string.

## Floats

Engines use IEEE-754 binary64 and the formulas above in the order written.
Vectors compare floats within `1e-6 * max(1, abs(want))`, and place no
decision within that distance of a threshold.

## Open points

Two cases this version does not decide. No vector covers them, and engines
may differ on them until a later version settles them with vectors.

| Point | Section |
|---|---|
| An integer literal outside the signed 64-bit range | Reports |
| `same` between booleans, arrays or objects | Tests |
