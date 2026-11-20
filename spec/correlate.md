# Correlate specification

Status: Written. Version 1.0. Every language's engine implements this document
and passes every vector. Engines are written from this document and the
vectors, never from another engine's source.
Version 1.0 retires the `window` test; adds the `state` test (the full-state
track-to-track statistic), confirmation by sequential test (`sprt`), staleness
from each source's update interval (`stale_rate`) and the `fused` output, which
becomes the default; and states where each default value of the packs comes
from (Methods and sources). A pack that names its directives and uses no
`window` test behaves as in 0.8, except that a pack without an `output` line
now gives the fused output. Version 0.8 added the time quality of a report (Reports, "Time quality") and
the pack directive `time_default`; a report and pack without them behave as
in 0.7. Version 0.7 added the optional `restart` directive (Restart). Version 0.6 spelled the pack line `maneuver` (it was
`manoeuvre` in 0.5).

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
| `time_error_ms` | float, ms | no | error bound of the clock that stamped `time_ms`, against the fabric's common time (Time quality) |
| `time_state` | string | no | state of that clock: `coherent`, `drifting` or `free-running` (Time quality) |
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

### Time quality

`time_ms` comes from the clock of the node that stamped the report. That
clock may be out of step with the other nodes' clocks. Two optional keys
state how far, as the stamping node measured it:

| Key | Meaning |
|---|---|
| `time_error_ms` | the bound, in milliseconds, on how far `time_ms` may be from the common time the nodes keep among themselves (their internal coherence, not their agreement with UTC); 0 or above |
| `time_state` | `coherent`: the clock is in step with the others within `time_error_ms`. `drifting`: the clock is moving away from the others and is being corrected. `free-running`: the clock runs on its own oscillator with no correction, and its error grows with time |

`time_error_ms` is a number, finite and 0 or above; a value of the wrong type,
negative or not finite is treated as absent. `time_state` is one of the three
strings above, compared byte for byte; any other value, or a value of the
wrong type, is treated as absent. Neither key causes a reject.

A pack may give a source defaults with `time_default` (Pack). The **time
error** and **time state** of a report are found per key, independently:

1. the report's own key, when present (not absent by the rules above);
2. otherwise the pack's `time_default` for the report's `track.source_id`,
   when it gives that key;
3. otherwise time error 0 and time state `coherent`: the time is exact, as in
   every version before 0.8.

Correlate uses the time error (Track estimate, Measurement variance; and,
with method `assign`, the time offset of `correlate-assign.md`). It does not
use the time state in this version; it is read by the quality function.
The correlator never reads a clock. Time quality comes only from reports and
the pack, so two runs on the same input decide the same way.

## Frame

All geometry is done in one local plane, meters east and north of a reference
point. The reference is the `lat`/`lon` of the first report the engine
accepts, and it never moves.

- `R = 6371008.8` m, `rad(x) = x * pi / 180`, `deg(x) = x * 180 / pi`.
- `dlon = lon - lon0`, brought into (-180, 180] by adding or subtracting 360.
- `east = R * rad(dlon) * cos(rad(lat0))`, `north = R * rad(lat - lat0)`.
- Back to degrees: `lat = lat0 + deg(north / R)`,
  `lon = lon0 + deg(east / (R * cos(rad(lat0))))`, then `lon` brought into
  (-180, 180].

The plane is accurate within a few hundred kilometers of the reference.

## Track estimate

Each entity keeps a constant-velocity Kalman filter, run as two independent
axes, east and north. Each axis holds position `p`, velocity `v` and the
symmetric covariance `pp`, `pv`, `vv`. Parameters come from the pack's
`filter` line: `accel_var` (q, m²/s⁴), `default_ce_m`, `vel_sigma_ms`,
`unknown_vel_ms`.

Velocity measurement, when the report has both `course` and `speed_ms`:
`ve = speed_ms * sin(rad(course))`, `vn = speed_ms * cos(rad(course))`.

**Measurement variance.** Each report has a position variance per axis,
`r_east` and `r_north`. With `ce` the report's `ce` or `default_ce_m`, and `te`
the report's time error (Reports, Time quality) in milliseconds:

- when `te` is 0, `r_east = r_north = ce²`;
- otherwise, with `ts = te / 1000` and the velocity `(v_e, v_n)` taken from
  the entity's prediction to the report's `time_ms` (for its first report:
  the measured velocity, or 0 without one),
  `r_east = ce² + (v_e*ts)²` and `r_north = ce² + (v_n*ts)²`. A position
  stamped up to `ts` seconds off lies up to `v*ts` along the track from the
  true one.

When `te` is above 0 (and only then), the trace gets
`{"stage":"filter","a":<entity>,"b":null,"test":"time","value":te,"limit":null,"pass":true,"var_east":(v_e*ts)²,"var_north":(v_n*ts)²}`,
before any other record of that report.

The entity keeps its last report's `r_east` and `r_north`, and its **timing
variance** `(v_e*ts)²`, `(v_n*ts)²` (0 and 0 when `te` is 0). A filter's
covariance does not hold the timing error, which displaces every report of a
clock the same way; so wherever another entity B is predicted to be compared
with A (Tests; `correlate-assign.md`, Cost), B's timing variance is added to
the predicted `pp` on each axis, before any other change to that prediction
(such as the move of `correlate-assign.md`, Sensor bias). This includes the
`d²` of the `rank` record. Predictions that are not a comparison with
another entity (Restart, the bias update, output) do not get it.

**First report.** Per axis: `p` = measured position, `v` = measured velocity
or 0, `pp = r` (that axis's measurement variance), `pv = 0`, `vv = vel_sigma_ms²` when a velocity was measured,
else `unknown_vel_ms²`.

**Later reports**, per axis, with `dt = (time_ms - last_time_ms) / 1000`:

1. Predict:
   `p = p + v*dt`;
   `pp = pp + 2*dt*pv + dt²*vv + q*dt⁴/4`;
   `pv = pv + dt*vv + q*dt³/2`;
   `vv = vv + q*dt²`.
2. Position update with measurement `z` and `r` that axis's measurement
   variance:
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

## Two-model filter

A pack may add the directive `maneuver accel_var=<q2> p_enter=<a>
p_leave=<b>`. Each entity then keeps two constant-velocity filters instead of
one, an interacting multiple model filter:

| Model | Index | Acceleration variance |
|---|---|---|
| `quiet` | 1 | `q1`, the `filter` line's `accel_var` |
| `maneuver` | 2 | `q2`, the `maneuver` line's `accel_var`; above `q1` |

`a` is the probability per second of input time that a quiet target starts
to maneuver, `b` the probability per second that a maneuvering target goes
quiet. Each model holds both axes `[p, v, pp, pv, vv]` as in Track estimate.
Both axes share one pair of mode probabilities `mu1`, `mu2`. The entity's
*filter* is the combination of the two models (step 5). Every test, cost,
output and snapshot that this document or `correlate-assign.md` says reads
"the filter" reads this combination, except a prediction, which follows
Prediction below. Without the directive nothing in this
section applies, and an entity has one filter as in Track estimate.

**Switching over `dt` seconds** (`dt` 0 or above), with `pow` the IEEE-754
power function:
`s = a + b`; `l = pow(1 - s, dt)`; `t12 = a / s * (1 - l)`;
`t21 = b / s * (1 - l)`; `t11 = 1 - t12`; `t22 = 1 - t21`.
`tij` is the probability of model `j` at the end of `dt` given model `i` at
its start. With `dt = 0`, `l = 1` and no switching happens.

**First report.** Both models are the first-report filter of Track estimate,
`mu1 = b / s`, `mu2 = a / s` (the long-run share of each model), and the
entity's filter is that same first-report filter. No trace record.

**Later reports**, with `dt = (time_ms - last_time_ms) / 1000`, in this
order. Per-axis formulas apply to east and to north.

1. **Mixing.** Predicted mode probabilities `c1 = t11*mu1 + t21*mu2`,
   `c2 = t12*mu1 + t22*mu2`. For each model `j`: when `cj = 0`, its mixed
   state is its own state. Otherwise `w1 = t1j*mu1 / cj`, `w2 = t2j*mu2 / cj`,
   and per axis, with model 1's state `p1, v1, pp1, pv1, vv1` and model 2's
   `p2, ...`, the mixed state is `blend(w1, w2)`:
   `p = w1*p1 + w2*p2`; `v = w1*v1 + w2*v2`;
   `d1 = p1 - p`, `e1 = v1 - v`, `d2 = p2 - p`, `e2 = v2 - v`;
   `pp = w1*(pp1 + d1*d1) + w2*(pp2 + d2*d2)`;
   `pv = w1*(pv1 + d1*e1) + w2*(pv2 + d2*e2)`;
   `vv = w1*(vv1 + e1*e1) + w2*(vv2 + e2*e2)`.
   Both mixed states are computed from the model states before mixing.
2. **Predict and update**, each model from its mixed state: Track estimate
   steps 1 to 3 with `dt`, the model's own acceleration variance, and the
   report's measurements.
3. **Likelihood**, per model. Each scalar update in step 2 has an innovation
   `y` and its variance `s` (the `y` and `s` of Track estimate steps 2 and 3).
   Its term is `y*y/s + ln(s)`. The terms are taken in the order east
   position, north position, then, when a velocity was measured, east
   velocity, north velocity, and added left to right from 0 to give `g`. The
   model's log-likelihood is `lambda = -0.5 * g`. The constant of the normal
   density is left out; it is the same for both models and cancels in step 4.
4. **Mode probabilities.** `m` is the larger `lambda` of the models with
   `cj` above 0. For each model, `ej = cj * exp(lambdaj - m)` when `cj` is
   above 0, else `ej = 0`; then `muj = ej / (e1 + e2)`. The model whose
   `lambda` is `m` has `ej = cj`, so the sum is above 0. When `lambdaj - m` is
   so far below 0 that `exp` underflows, `ej` is exactly 0 and so is `muj`.
   A model with `muj = 0` is not reset or skipped: on every later report it
   is mixed by step 1 and updated by step 2 like the other. On the next
   report with `dt` above 0, `cj` is above 0 again through switching; with
   `dt = 0`, `cj = 0` and step 1 keeps its own state.
5. **Combination.** Per axis, the entity's filter is `blend(mu1, mu2)` of
   the two updated models, with the formulas of step 1.

**Prediction** of an entity with two models to time `t`: each model is
predicted by Track estimate step 1 with its own acceleration variance (`dt`
may be negative) and the two predictions are combined with `blend(mu1, mu2)`
using the current mode probabilities, unchanged. It never changes the
entity.

**Trace.** Each later report gives four records before any association
record, `"stage":"filter"`, `"a"` the entity, `"limit":null`,
`"pass":true`: `"test":"likelihood"` with `"b":"quiet"` and `value`
`lambda1`, the same with `"b":"maneuver"` and `lambda2`, then
`"test":"mode"` with `"b":"quiet"` and `mu1`, then with `"b":"maneuver"`
and `mu2`.

## Restart

A pack may add the directive `restart gate=<g>`, with either method. It
starts an entity's filter again when a report is far outside the filter's
prediction, as when a sensor's track number moves to another object: without
it, the filter takes the jump into its velocity and its predictions run far
off for many reports.

For each later report of an entity (one that passed every reject check), before
the filter update: predict the entity to the report's `time_ms` (Track
estimate, Prediction; with two models, Two-model filter, Prediction), and
with `e`, `n` the report's position in the plane and `r_east`, `r_north`
its measurement variance (Track estimate):

`d² = (e - pe)² / (pp_e + r_east) + (n - pn)² / (pp_n + r_north)`

where `pe`, `pp_e` and `pn`, `pp_n` are the prediction's east and north `p`
and `pp`. The trace gets
`{"stage":"filter","a":<entity>,"b":null,"test":"restart","value":d²,"limit":g,"pass":<d² < g>}`,
after the `time` record, when there is one, and before any other record of
that report.

When `pass` is true the report updates the filter as in Track estimate (or
Two-model filter). Otherwise the filter starts again from this report as a
first report, with `pp` on each axis this report's measurement variance as
already found above (from the prediction's velocity), and the entity keeps
this report's timing variance: one filter, or both models and the mode probabilities `b / s`,
`a / s`, as in First report. No `new` event is given and the entity keeps
its key, its group, its pair counts and its hold failure count. With method `assign` the entity is also
*restarted* until the next tick ([correlate-assign.md](correlate-assign.md),
Window). The first report of an entity runs no restart test.

## Tests

A test compares entity A, the one just reported, with entity B predicted to
A's `time_ms`. Every test yields `value`, `limit` and `pass`, and is written
to the trace. Distances are in the plane, between A's filtered position and
B's predicted position.

| Test | Parameters | `value` | Passes when |
|---|---|---|---|
| `distance` | `max_m` | distance, m | `value < max_m` |
| `mahalanobis` | `gate` | `d²` (below) | `value < gate` |
| `course` | `max_deg`, `min_speed_ms` | `min(abs(ca-cb), 360-abs(ca-cb))`, deg | `value <= max_deg` |
| `speed` | `max_pct`, `min_speed_ms` | `abs(1 - slow/fast) * 100` | `value <= max_pct` |
| `altitude` | `max_m` | `abs(hae_a - hae_b)`, m | `value <= max_m` |
| `same` | `key` | — | the two values are equal, or both absent |
| `state` | `probability`, `hae_sigma_m` | `d²_state` (below) | `value < limit`, `limit` the chi-square quantile of `probability` for the record's degrees of freedom (table below) |

`d² = sum over east, north of (pa - pb)² / (pp_b + r_a)`, with `pb` and
`pp_b` from B's prediction (with B's timing variance added, Track estimate),
`pa` from A's filter and `r_a` A's measurement variance on that axis, which is
`ce_a²` when A's last report has time error 0.

**The `state` test** compares the two tracks' whole kinematic state, not only
their positions: the track-to-track association test of Bar-Shalom (1981).
Per axis, with A's filter `[pa, va, ppa, pva, vva]` and B's prediction to A's
time `[pb, vb, ppb, pvb, vvb]` (with B's timing variance added to `ppb`, as
for every test):

- `dp = pa - pb`, `dv = va - vb`;
- `spp = ppa + ta + ppb` (`ta` A's timing variance on that axis),
  `spv = pva + pvb`, `svv = vva + vvb`;
- `det = spp*svv - spv*spv`;
- `q = (svv*dp*dp - 2*spv*dp*dv + spp*dv*dv) / det`.

`d²_state` is `q` of east plus `q` of north, 4 degrees of freedom. When both
A's and B's last reports have `hae`, it adds `dh*dh / (2*h*h)`, with
`dh = hae_a - hae_b` and `h` the test's `hae_sigma_m`, for 5 degrees of
freedom. The two tracks' estimates are treated as independent: the
cross-covariance of tracks that share process noise (Bar-Shalom and Campo
1986) is not modeled in this version. A turning or slow target needs no
special case: its velocity covariance is large, and the velocity difference
counts for less. The trace record adds `"dof": 4` or `5`.

`probability` is one of the values of this table, and `limit` is read from
it (Abramowitz and Stegun 1964, table 26.8), so that no engine computes a
quantile:

| `probability` | 4 dof | 5 dof |
|---|---|---|
| 0.95 | 9.4877 | 11.0705 |
| 0.99 | 13.2767 | 15.0863 |
| 0.995 | 14.8603 | 16.7496 |
| 0.999 | 18.4668 | 20.5150 |

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
  test ran and passed, else 0. Counts are kept per unordered pair: every
  pair tested has an entry, 0 included, removed only when one of its
  entities is dropped.
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
   left (as in hold: event `dissolve`, the last member ungrouped with its hold
   failure count set to 0), and the entity is removed (event `drop`), with every pair count that
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

Each test run is one trace record, and so is each filter record of
Two-model filter:
`{"stage", "a", "b", "test", "value", "limit", "pass"}`, plus
`"skipped": true` for a skipped test. `stage` is `gate`, `confirm`, `hold`,
`rank` or `filter`; `a` and `b` are entity keys, except that `b` of a
`filter` record names a model, and is null for the `time` and `restart`
records. A pair's count after its tests is a
record with stage `confirm` (also when a `gate` test failed), `"test":"count"`,
`value` the new count, `limit` the pack's `confirm_count`, and `pass` true
when it has reached it. Records are in the order
the tests run.

## Snapshot

`snapshot()` returns `{"ref": [lat0, lon0] or null, "entities": {...},
"groups": {...}, "counts": {...}, "next_group": n}`. Each entity holds
`last_time_ms`, `group` (or null), `hold_failures` and `filter`
(`{"east": [p, v, pp, pv, vv], "north": [...]}`). An entity whose last
report had a time error above 0 also holds `time`:
`{"var_east", "var_north"}`, its timing variance (Track estimate). With the `maneuver`
directive each entity also holds `models`
(`{"quiet": {"east": [...], "north": [...]}, "maneuver": {...}}`) and
`mode` (`[mu1, mu2]`), and `filter` is their combination; `groups` maps a group name
to its members; `counts` maps `"<key>|<key>"` (keys in order) to the count.

## Pack

A pack is a directory `packs/<name>/` holding `pack.def` and `vectors/`.
`pack.def` is line-oriented UTF-8; `#` starts a comment; blank lines are
ignored. Each line is a directive and `name=value` parameters.

```
pack           <name>
version        <semver>
method         confirm
filter         accel_var=<q> default_ce_m=<m> vel_sigma_ms=<m/s> unknown_vel_ms=<m/s>
maneuver       accel_var=<q2> p_enter=<per s> p_leave=<per s>
restart        gate=<g>
time_default   <source_id> error_ms=<ms> state=<coherent | drifting | free-running>
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

In `filter`, `default_ce_m`, `vel_sigma_ms` and `unknown_vel_ms` must be
above 0 and `accel_var` 0 or above, or the pack does not load.

`maneuver` is optional, appears at most once, takes exactly `accel_var`,
`p_enter` and `p_leave`, and is valid with either method. The pack does not
load unless `p_enter` and `p_leave` are above 0 with a sum below 1, and
`maneuver`'s `accel_var` is above `filter`'s `accel_var`. That last rule is
checked once the whole file is read, so `maneuver` may come before `filter`.

`restart` is optional, appears at most once, takes exactly `gate`, which must
be above 0, and is valid with either method.

`time_default` is optional, valid with either method, and repeats, at most
once per source: a second line for the same `<source_id>` is a load error.
It takes the source id, a first token without `=`, and then `error_ms`,
`state` or both, at least one, each at most once;
`error_ms` is a number 0 or above and `state` one of `coherent`, `drifting`,
`free-running`. Any other parameter or value is a load error.

`gate`, `confirm`, `hold` and `priority` repeat; their order is the order the
tests run. Every other directive appears once, and `pack`, `version`,
`filter`, `confirm_count`, `hold_failures`, `stale_ms` are required;
`same_source` defaults to `forbid` and `output` to `priority`. `method`
is optional and defaults to `confirm`, the method of this document;
`method assign` selects [correlate-assign.md](correlate-assign.md), which has
its own directives. A test name or
parameter not in the tests table, a missing parameter, or a value that does
not parse is a load error. Numbers are decimal; `same` takes a string.

## Floats

Engines use IEEE-754 binary64 and the formulas above in the order written.
`x²` means `x*x`. `sin`, `cos`, `atan2`, `sqrt`, `hypot`, `pow`, `exp` and
`ln` are the platform's binary64 functions. Every other operation is one
correctly rounded binary64 operation: engines do not contract `a*b + c` into
a fused multiply-add and do not keep intermediates in extended precision.
The library functions may differ in the last bit between platforms, which
the tolerance absorbs; vectors never rest a tie on their results. Vectors compare floats within
`1e-6 * max(1, abs(want))`, and place no decision within that distance of a
threshold: the vector generator refuses a test whose `value` is that close to
its `limit`.

## Open points

Cases this version does not decide. No vector covers them, and engines
may differ on them until a later version settles them with vectors.

| Point | Section |
|---|---|
| An integer literal outside the signed 64-bit range | Reports |
| `same` between booleans, arrays or objects | Tests |
| Ranges of `confirm_count`, `hold_failures`, `stale_ms` (0, negative) and of test parameters (negative `max_m`, `err_min_m` above `err_max_m`, `gate` 0 or below) | Pack |
| `priority` listing one source twice | Pack |
| A repeated parameter within one `filter`, `maneuver` or test line | Pack |
| Which decimal spellings a number may take (exponent, leading `+`, `.5`, `inf`, `nan`), and a `#` inside a value | Pack |
