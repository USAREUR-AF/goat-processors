# Fuse specification

Status: Written. Version 0.1. Every language's engine implements this document
and passes every vector. Engines are written from this document,
[correlate.md](correlate.md), [vector-format.md](vector-format.md) and the
vectors, never from another engine's source.

## What fuse does

Fuse combines the reports of entities that are known to describe one object
into one estimate per object. It does not decide which entities belong
together: the key `fuse.group`, written upstream (for example by correlate,
naming the system track), says so. At each tick fuse gives one `fused` event
per group: one position, course, speed, height and one-sigma horizontal
error, and one value for each attribute the pack names, each value with the
member it came from.

How the members' kinematics are combined is the pack's `kinematics` method:

| Method | Use | Estimate |
|---|---|---|
| `inverse_variance` | the members' errors are independent | every member, weighted by the inverse of its variance |
| `covariance_intersection` | the members' errors may be correlated by an unknown amount, for example tracks that share a sensor | every member, weighted so that the result is never more certain than the inputs allow |
| `best` | one member is clearly the better sensor | the member with the smallest position variance |
| `priority` | the pack ranks the sources | the member of the highest-ranked source |
| `latest` | the most recent report is the most useful | the member reported last |

Each attribute (`type`, `callsign`, a flag, any shared-model key) is decided
by its own rule: `priority`, `latest`, `majority`, `max` or `min`.

An engine has four operations:

| Operation | Returns |
|---|---|
| `load_pack(dir)` | a pack, or an error |
| `ingest(report)` | the events and the trace for that report |
| `tick(now_ms)` | the events and the trace for that time |
| `snapshot()` | the whole state, as a map |

Fuse is deterministic. Its only clock is the time carried in the input
(`time_ms` of a report, `now_ms` of a tick). It never reads the wall clock,
never uses randomness, and visits every collection in the orders this
document defines.

## Shared with `correlate.md`

These sections of `correlate.md` apply unchanged: Frame, Track estimate (the
per-entity filter, its update on each accepted report, and its prediction),
Floats. Reports applies with the changes below.

Vectors follow [vector-format.md](vector-format.md): scenario vectors under
`packs/fuse-*/vectors/`, load vectors under `spec/fuse-load-vectors/`. An
engine's fuse runner reads only those.

## Reports

A report is a map from shared-model key to value. Fuse reads the keys of
`correlate.md` Reports, plus these:

| Key | Type | Required | Use |
|---|---|---|---|
| `fuse.group` | string | no | the name of the group the entity belongs to |
| a key named by an `attribute` line | string, number or boolean | no | a candidate for that attribute |

The entity key is `<track.source_id>/<uid>`. Keys and group names are
compared as byte strings; "key order" means ascending byte order.

Validation follows `correlate.md` Reports, with these differences:

- `fuse.group` is absent when it is `null`, not a string, or the empty string.
- A report whose `time_ms` is earlier than its entity's last accepted report
  is ignored with event
  `{"ev":"stale-report","entity":<key>,"time_ms":<its time_ms>,"last_time_ms":<the entity's>}`.
  It changes no state. A report with `time_ms` equal to the last is accepted
  (`dt = 0`). The correlate reason `out-of-order` is not used.
- A report with a missing required key is rejected with
  `{"ev":"reject","reason":"missing:<key>"}` as in `correlate.md`.

The **normalised report** is the report with every key removed that is `null`,
or that `correlate.md` Reports or the first rule above treats as absent (an
optional key of the wrong type, a `ce` of 0 or below, an unusable
`fuse.group`). Every value fuse reads later (`hae`, `stale_ms`, `fuse.group`,
attribute values) comes from the entity's last normalised report. A key absent
from that report is absent, whatever earlier reports held.

## Groups

An entity's group is the `fuse.group` of its last accepted report. An entity
whose last accepted report has no `fuse.group` is its own group, which has no
name (`null`) and only that member.

**A move between groups is applied when the report is accepted**, in `ingest`,
after the filter update. If the entity already existed and its group differs
from the group of its previous accepted report, the event
`{"ev":"move","entity":<key>,"from":<old group or null>,"to":<new group or null>}`
is given. A first report gives `new` with the entity's group and no `move`.
The next `tick` uses the memberships as they are at that tick; fuse keeps no
memory of earlier memberships.

**Output order of groups**, used for events and trace at each tick: named
groups in byte order of their name, then the unnamed groups in key order of
their one member. A named group with no member does not exist.

## On each tick

At `now_ms`:

1. **Staleness**, entities in key order. An entity is stale when
   `now_ms - last_time_ms > stale_ms` of the pack, or when its last report has
   `stale_ms` and `now_ms >= stale_ms` of that report. A stale entity is removed
   with event `{"ev":"drop","entity":<key>,"group":<its group or null>}`.
2. **Fused output**, groups in output order, each group with its members in
   key order. For each group:
   1. Predict every member's filter to `now_ms` (`correlate.md`, Track estimate,
      prediction; `dt` may be negative). Below, `pe`, `ve`, `ppe`, `vve` are a
      member's predicted east position, east velocity, east position variance
      and east velocity variance; `pn`, `vn`, `ppn`, `vvn` the same for north.
   2. Combine them by the pack's kinematics method (next section). This gives
      `p`, `v`, `pp`, `vv` per axis, and the member it came from, or `null`.
   3. Decide every attribute, in pack order (Attributes).
   4. Give the `fused` event.

A tick with no entities gives no events and no trace.

### Fused event

| Field | Value |
|---|---|
| `group` | the group name, or `null` |
| `members` | the members, in key order |
| `from` | the member whose filter gave the kinematics (`best`, `priority`, `latest`), or `null` (`inverse_variance`, `covariance_intersection`) |
| `lat`, `lon` | `p` east and north, to degrees (`correlate.md`, Frame) |
| `course` | `deg(atan2(v_east, v_north))`, plus 360 when below 0, minus 360 when 360 or above |
| `speed_ms` | `hypot(v_east, v_north)` |
| `ce` | `sqrt((pp_east + pp_north) / 2)` |
| `hae`, `hae_from` | the height and the member it came from (below); both absent when no height is known |
| `attributes` | a map from attribute key to `{"value": <value>, "from": <member>}`; an attribute with no candidate is absent; `{}` when the pack names none or none has a candidate |

`ce` is the one-sigma horizontal error in the sense of the input `ce`: a
report with `ce = c` starts both axes at variance `c²`, and a fused estimate
with variance `c²` on both axes has `ce = c`.

**Height.** For `best`, `priority` and `latest`: the `hae` of the member the
kinematics came from, when its last report has one; otherwise no height. For
`inverse_variance` and `covariance_intersection`: the `hae` of the member with
the greatest `last_time_ms` whose last report has `hae`, ties to key order;
no height when no member has one.

## Kinematics

Each method gives, per axis, `p`, `v`, `pp`, `vv`. The east and north axes are
computed by the same formulas, east first. With one member, every method gives
that member's predicted filter; `from` is still `null` for `inverse_variance`
and `covariance_intersection`.

**Position variance** of a member is `var = ppe + ppn`.

**Rank** of a member is the index, from 0, of its `track.source_id` among the
pack's `source` lines; a member whose source is not listed ranks after every
listed source.

### `inverse_variance`

Per axis, members in key order, starting from `ip = 0, sp = 0, iv = 0, sv = 0`,
for each member: `ip = ip + 1/pp`, `sp = sp + p/pp`, `iv = iv + 1/vv`,
`sv = sv + v/vv`. Then `pp = 1/ip`, `p = pp * sp`, `vv = 1/iv`, `v = vv * sv`.
This is the fused estimate of `correlate-assign.md`.

It is correct when the members' errors are independent. When two members
share a sensor, their errors are correlated and the result claims more
certainty than the data holds. Vector `fuse-independent/07`: two trackers
follow one radar whose bias puts both 40 m east of the truth, with `ce` 30 and
40. Inverse variance gives `ce = sqrt(1 / (1/900 + 1/1600)) = 24.0`. Their
errors are one error, so the true one-sigma of the weighted mean is
`0.64 * 30 + 0.36 * 40 = 33.6`. Covariance intersection on the same input
(vector `fuse-shared/08`) gives `ce = 30.0`.

### `covariance_intersection`

Members are folded in key order. The running estimate `X` starts as the first
member's predicted filter. Each later member `Y` is folded into `X` with one
weight `w` in [0, 1], which `X` carries and `1 - w` which `Y` carries, the
same for both axes and for position and velocity.

**Weight.** `w` maximizes `det` of the fused position information
`diag(w/X.ppe + (1-w)/Y.ppe, w/X.ppn + (1-w)/Y.ppn)`, which minimizes the
determinant of the fused position covariance. That determinant is a
quadratic in `w`, so the maximum has a closed form. In this order:

1. `ae = 1 / Y.ppe`, `an = 1 / Y.ppn`
2. `de = 1 / X.ppe - ae`, `dn = 1 / X.ppn - an`
3. `c2 = de * dn`
4. `c1 = ae * dn + an * de`
5. If `c2 < 0`: `w = -c1 / (2 * c2)`, then `w = 0` if `w < 0`, `w = 1` if `w > 1`.
   Otherwise, if `c1 + c2 > 0`: `w = 1`; if `c1 + c2 < 0`: `w = 0`; if
   `c1 + c2 = 0`: `w = 0.5`.

`c1 + c2 = 0` with `c2 >= 0` happens only when `X` and `Y` have the same
position variances on both axes; then every `w` gives the same variance and
`0.5` is used.

The filter of `correlate.md` gives both axes of an entity the same variances
(both start at `ce²` and every update and prediction is the same on both).
Then `de = dn`, `c2 >= 0`, and `w` is 1 when `X` has the smaller position
variance, 0 when `Y` has, and 0.5 when they are equal. The case `c2 < 0` is
stated for a filter with different variances per axis; no vector of this
version reaches it.

**Fold.** When `w = 1` the new `X` is `X` unchanged; when `w = 0` it is `Y`
unchanged. Otherwise, per axis, in this order:
`a = w / X.pp`, `b = (1 - w) / Y.pp`, `pp = 1 / (a + b)`,
`p = pp * (a * X.p + b * Y.p)`;
`c = w / X.vv`, `d = (1 - w) / Y.vv`, `vv = 1 / (c + d)`,
`v = vv * (c * X.v + d * Y.v)`. The result is the new `X`.

Each fold is one trace record (Trace). Whatever the correlation between the
errors of `X` and `Y`, the result's covariance is not smaller than the true
covariance of its error (vector `fuse-shared/08`).

**Why a closed form and a fold.** A closed form gives every engine the same
bits from the same IEEE-754 operations, which a search over a grid does only
when every engine uses the same grid and tie rule, and then with a weight
limited to the grid's resolution. Folding in key order is the stated order;
each fold is itself a valid intersection, so the result is consistent for
every number of members.

### `best`

The member with the smallest `var`, ties to key order.

### `priority`

The member with the smallest rank, ties to key order.

### `latest`

The member with the greatest `last_time_ms`, ties to key order.

For `best`, `priority` and `latest`, `p`, `v`, `pp`, `vv` are that member's
predicted filter on each axis, and `from` is that member.

## Attributes

One `attribute <key> rule=<rule>` line per key. For a group, the
**candidates** are its members in key order whose last report holds `<key>`
with a usable value: a string, a number or a boolean for `priority`, `latest`
and `majority`; a number (not a boolean) for `max` and `min`. A member whose
value is not usable is not a candidate.

| Rule | Winner |
|---|---|
| `priority` | the candidate with the smallest rank, ties to key order |
| `latest` | the candidate with the greatest `last_time_ms`, ties to key order |
| `majority` | values are counted; the value held by the most candidates wins; between values with the same count, the one whose first holder in key order comes first; the winner is that first holder |
| `max` | the candidate with the greatest value, ties to key order |
| `min` | the candidate with the smallest value, ties to key order |

Two values are **equal** for `majority` when both are strings with the same
bytes, both are numbers with the same value (`1` equals `1.0`), or both are
the same boolean. A string, a number and a boolean are never equal to each
other. `max` and `min` compare numbers by value.

The attribute's `value` is the winner's value as its report holds it, and
`from` is the winner. With no candidates the attribute is absent from the
event.

## Events

Each event is a JSON object with `ev` and the fields below. `members` lists are
in key order.

| Event | Fields |
|---|---|
| `reject` | `reason` |
| `stale-report` | `entity`, `time_ms`, `last_time_ms` |
| `new` | `entity`, `group` |
| `move` | `entity`, `from`, `to` |
| `drop` | `entity`, `group` |
| `fused` | `group`, `members`, `from`, `lat`, `lon`, `course`, `speed_ms`, `ce`, `hae` and `hae_from` when known, `attributes` |

A report gives one of: `reject`; `stale-report`; `new`; `move`; nothing.
A tick gives, in order: one `drop` per stale entity, then one `fused` per group.

## Trace

A report gives no trace. A tick gives, per group in output order:

1. For `covariance_intersection`, one record per fold, in fold order:
   `{"stage":"intersect","group":<g>,"member":<Y>,"value":<w>}`.
2. One kinematics record:
   `{"stage":"kinematics","group":<g>,"method":<method>,"candidates":[...],"winner":<member or null>}`.
   Each candidate, members in key order, is
   `{"member":<key>,"var":<var at now_ms>,"time_ms":<last_time_ms>,"rank":<rank or null when unlisted>}`.
   `winner` is `from` of the event.
3. One record per `attribute` line, in pack order:
   `{"stage":"attribute","group":<g>,"key":<key>,"rule":<rule>,"candidates":[...],"winner":<member or null>,"value":<value or null>}`.
   Each candidate, in key order, is
   `{"member":<key>,"value":<its value>,"time_ms":<last_time_ms>,"rank":<rank or null>}`.
   With no candidates, `candidates` is `[]` and `winner` and `value` are `null`.

## Snapshot

`snapshot()` returns `{"ref": [lat0, lon0] or null, "entities": {...}}`. Each
entity, in key order, holds `last_time_ms`, `group` (the name or `null`),
`filter` (`{"east": [p, v, pp, pv, vv], "north": [...]}`) and `report` (its
last normalised report). The snapshot is the whole state: two engines with
equal snapshots decide every later call the same way.

## Pack

A pack is a directory `packs/fuse-<name>/` holding `pack.def` and `vectors/`.
`pack.def` is UTF-8. Lines are separated by LF; a CR at the end of a line is
removed. `#` starts a comment to the end of the line. A line is split on runs
of spaces and tabs; a line with nothing left is ignored. Each line is a
directive and its values.

```
pack        <name>
version     <semver>
filter      accel_var=<q> default_ce_m=<m> vel_sigma_ms=<m/s> unknown_vel_ms=<m/s>
kinematics  inverse_variance | covariance_intersection | best | priority | latest
attribute   <key> rule=priority | latest | majority | max | min
source      <source_id>
stale_ms    <ms>
```

| Directive | Count | Rule |
|---|---|---|
| `pack`, `version` | exactly once | one value |
| `filter` | exactly once | exactly the four parameters, each `name=value`, each a number; `default_ce_m`, `vel_sigma_ms`, `unknown_vel_ms` above 0, `accel_var` 0 or above |
| `kinematics` | exactly once | one of the five methods |
| `stale_ms` | exactly once | one integer, 0 or above |
| `attribute` | any number | a key, then exactly `rule=<rule>`; a key on two `attribute` lines is an error |
| `source` | any number | one value; a source on two `source` lines is an error; line order is rank order |

A **number** is an optional `-`, one or more digits, optionally `.` and one or
more digits, optionally `e` or `E`, an optional sign and one or more digits.
An **integer** is one or more digits.

The pack does not load when: a directive is unknown; a once-only directive is
missing or repeated; a directive has the wrong number of values; a parameter
has no `=`, is unknown, is repeated or is missing; a value does not parse or
breaks its rule; an attribute key holds `=`. An attribute key cannot hold `#`,
a space or a tab, since those end the key.

## Floats

As in `correlate.md`: IEEE-754 binary64 and every formula in the order
written. Vectors compare floats within `1e-6 * max(1, abs(want))` and place no
decision within that distance of a threshold. A tie a vector decides (equal
variances, equal times) is exact: both sides come from the same operations on
the same values.

## Open points

Cases this version does not decide. No vector covers them.

| Point | Section |
|---|---|
| An integer literal outside the signed 64-bit range (as `correlate.md`) | Reports |
| `majority`, `max` and `min` between integers whose magnitude is above 2^53, where an engine that compares as binary64 and one that compares exactly can differ | Attributes |
