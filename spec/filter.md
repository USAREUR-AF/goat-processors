# Filter specification

Status: Written. Version 0.1. Every language's engine implements this document
and passes every vector. Engines are written from this document and the
vectors, never from another engine's source.

## What the filter does

The filter decides, for each report, whether to keep it or drop it. A pack
holds an ordered list of rules. Each rule has an action, `keep` or `drop`, and
one or more conditions. The first rule whose conditions all hold decides the
report; when no rule does, the pack's `default` decides. Every condition the
filter evaluates is a trace record.

An engine has four operations:

| Operation | Returns |
|---|---|
| `load_pack(dir)` | a pack, or an error |
| `ingest(report)` | one event and the trace for that report |
| `tick(now_ms)` | the events and the trace for that time |
| `snapshot()` | the whole state, as a map |

The filter is deterministic. Its only clock is the time carried in the input
(`time_ms` of a report, `now_ms` of a tick). It never reads the wall clock,
never uses randomness, and visits every collection in the orders this document
defines. The same pack and the same sequence of calls give the same events and
trace in every engine.

## Reports

A report is a map from shared-model key to value, as in the Reports section
of [correlate.md](correlate.md). These parts of that section apply unchanged:

- the required keys `track.source_id`, `uid`, `time_ms`, `lat`, `lon`, their
  types, and the order they are checked in;
- the reject event `{"ev":"reject","reason":"missing:<key>"}`, without
  `entity`;
- the optional keys `hae`, `ce`, `course`, `speed_ms`, `type`, `stale_ms`:
  `null` or of the wrong type is absent, and a `ce` of 0 or below is absent;
- `null` for any key is the same as the key being absent;
- what an integer is;
- the entity key `<track.source_id>/<uid>`, compared as byte strings; "key
  order" means ascending byte order.

One part does not apply: the filter never rejects a report as out of order. A
report older than an earlier one of its entity is decided by the rules like
any other report; the `order` condition tests for it.

A rejected report gives no trace and changes no state.

The **environment** of a report is the third `-`-separated element of `type`
(`a-f-A-M-F` gives `A`). It is absent when `type` is absent or has fewer than
three elements. An empty element is an empty string (`a-f--X` gives `""`).

The **affiliation** of a report is the second `-`-separated element of `type`
when the first element is exactly `a` and there are at least two elements
(`a-h-S` gives `h`). It is absent otherwise (`b-m-p`, `a`, no `type`).

## Geometry

- `R = 6371008.8` m, `rad(x) = x * pi / 180`, `deg(x) = x * 180 / pi`.
- `wrap(x)`: add or subtract 360 until `x` is in (-180, 180].

**Distance** from point 1 (`lat1`, `lon1`) to point 2 (`lat2`, `lon2`) is the
great-circle distance on the sphere of radius `R` (haversine), evaluated in
this order:

1. `p1 = rad(lat1)`, `p2 = rad(lat2)`, `dp = rad(lat2 - lat1)`,
   `dl = rad(wrap(lon2 - lon1))`.
2. `s1 = sin(dp / 2)`, `s2 = sin(dl / 2)`.
3. `h = s1 * s1 + cos(p1) * cos(p2) * s2 * s2`, where the second term is
   evaluated left to right: `((cos(p1) * cos(p2)) * s2) * s2`.
4. `d = 2 * R * asin(min(1, sqrt(h)))`, evaluated as `(2 * R) * asin(...)`.

Point 1 is always the report being decided.

**Polygon.** A polygon is a list of `n >= 3` vertices (`lat_i`, `lon_i`), in
pack order, closed from the last vertex back to the first. Either winding is
accepted and gives the same result. The test is done on a flat plane with
`x` = longitude and `y` = latitude in degrees, after taking every longitude
to within 180 degrees of the first vertex:

- `x_0 = lon_0`; for `i >= 1`, `x_i = lon_0 + wrap(lon_i - lon_0)`; `y_i = lat_i`.
- The report: `px = lon_0 + wrap(lon - lon_0)`, `py = lat`.

Edges are straight lines in this plane, not great circles. A polygon that
crosses the antimeridian is written with its vertices on both sides
(`lon=179` and `lon=-179`); the unwrapping places them 2 degrees apart. A
polygon cannot hold a vertex more than 180 degrees of longitude from its first
vertex.

The result is `boundary`, `inside` or `outside`, in this order:

1. **Boundary.** For each edge `i` from 0 to `n-1`, with `j = (i + 1) mod n`:
   `c = (x_j - x_i) * (py - y_i) - (y_j - y_i) * (px - x_i)`. When `c == 0`
   exactly, `min(x_i, x_j) <= px <= max(x_i, x_j)` and
   `min(y_i, y_j) <= py <= max(y_i, y_j)`, the result is `boundary` and no
   later edge is examined. A report on an edge or a vertex is inside the
   polygon.
2. **Crossings.** Otherwise `inside` starts false. For each edge `i` from 0 to
   `n-1`, with `j = (i + 1) mod n`: when `(y_i > py) != (y_j > py)`, compute
   `xc = (x_j - x_i) * (py - y_i) / (y_j - y_i) + x_i`, evaluated left to
   right; when `px < xc`, `inside` becomes `not inside`. The result is
   `inside` or `outside` from the final value. A self-crossing polygon
   follows the same steps (even-odd rule).

**Reference prediction.** The position of a reference entity predicted to
time `t`, from its stored state (Snapshot) with `time_ms`, `lat`, `lon`,
`course`, `speed_ms`:

1. `dt = (t - time_ms) / 1000`, which may be negative.
2. When both `course` and `speed_ms` are present:
   `dn = speed_ms * cos(rad(course)) * dt`,
   `de = speed_ms * sin(rad(course)) * dt`, each evaluated left to right.
   Otherwise `dn = 0`, `de = 0`.
3. `lat_p = lat + deg(dn / R)`,
   `lon_p = wrap(lon + deg(de / (R * cos(rad(lat)))))`.

## Conditions

A condition is evaluated against the report being decided and the state
before that report. It gives one of three results: **true**, **false** or
**unknown**. Unknown means the data the condition needs is absent.

A condition written with `not` is negated: true becomes false and false
becomes true. Unknown stays unknown. The condition **passes** when its result,
after negation, is true. An unknown condition never passes, with or without
`not`.

| Condition | Parameters | `value` | `limit` | True when | Unknown when |
|---|---|---|---|---|---|
| `circle` | `lat`, `lon`, `radius_m` | distance from the report to (`lat`, `lon`), m | `radius_m` | `value <= limit` | never |
| `polygon` | `vertices` | `"boundary"`, `"inside"` or `"outside"` | null | `value` is not `"outside"` | never |
| `near` | `reference`, `radius_m`, `max_age_ms` | distance from the report to the reference predicted to the report's `time_ms`, m | `radius_m` | `value <= limit` | the reference has no state, or is stale (below) |
| `env` | `in` | the environment | the `in` list | `value` is in the list | the environment is absent |
| `affiliation` | `in` | the affiliation | the `in` list | `value` is in the list | the affiliation is absent |
| `source` | `in` | `track.source_id` | the `in` list | `value` is in the list | never |
| `uid` | `in` | `uid` | the `in` list | `value` is in the list | never |
| `key`, form eq | `name`, `eq` | the report's value of key `name` | the `eq` text | the value equals the text (below) | the key is absent |
| `key`, form in | `name`, `in` | the report's value of key `name` | the `in` list | the value equals an item of the list | the key is absent |
| `key`, form range | `name`, `min` and/or `max` | the report's value of key `name` | `[min, max]` | `min <= value <= max` | the key is absent, or its value is not a number |
| `has` | `name` | `true` when key `name` is present, else `false` | null | `value` is `true` | never |
| `speed` | `min` and/or `max` | `speed_ms` | `[min, max]` | `min <= value <= max` | `speed_ms` is absent |
| `altitude` | `min` and/or `max` | `hae`, m | `[min, max]` | `min <= value <= max` | `hae` is absent |
| `interval` | `min_ms` | `time_ms - kept_ms` of the entity, ms; null when the entity has no kept report | `min_ms` | `value < limit`; false when `value` is null | never |
| `order` | none | the report's `time_ms` | `kept_ms` of the entity; null when it has no kept report | `value < limit`; false when `limit` is null | never |

Details that bind every engine:

- **Absent and present.** A key is present when the report, after the
  optional-key rules of Reports, holds it with a value other than `null`.
  `key` and `has` read the report that way, so `ce: "30"` and `ce: 0` are
  absent. `key` may name any key, including a required one.
- **Ranges.** An omitted `min` or `max` is no bound on that side and is null
  in `limit`. Both bounds are inclusive. A value of `true` or `false` is not a
  number.
- **`in` lists** compare strings byte for byte. A list is written as one
  parameter, items separated by `,` (`in=h,s,j,k`), and the trace `limit` is
  the list of items in pack order.
- **`key` equality** between the report's value `v` and a pack text `t`:
  - `v` a string: equal when `v` and `t` are the same bytes;
  - `v` a number (integer or float): equal when `t` is a pack number (Pack)
    and its binary64 value equals `v` (`1`, `1.0` and `1.00` all equal `eq=1`);
  - `v` `true` or `false`: equal when `t` is the text `true` or `false`
    respectively;
  - `v` an array or an object: never equal.
  The trace `limit` of form eq is the text `t` as a string.
- **`near`.** `reference` is an entity key. Its state is the stored state
  before the report being decided, so a report of the reference entity itself
  is compared with that entity's previous state. The reference is stale when
  `abs(time_ms - ref.time_ms) > max_age_ms`, or when `ref.stale_ms` is present
  and `time_ms >= ref.stale_ms`, with `time_ms` the report's. The distance is
  from the report (point 1) to the predicted reference (point 2). When the
  result is unknown, `value` is null.
- **`interval`** thins a feed: a report less than `min_ms` after the last
  kept report of its entity is too soon. A report older than the last kept
  report gives a negative `value`, which is below `min_ms`.
- **`order`** is true for a report older than the entity's last kept report.
  A report at the same `time_ms` is not older.

## Rules

On each report that is not rejected:

1. **Rules** in pack order. For each rule, its conditions in pack order. Each
   condition evaluated is one trace record. The first condition that does not
   pass ends the rule: the rule does not match, and its later conditions are
   not evaluated and have no record. A rule matches when every condition
   passed.
2. **Decision.** The first rule that matches decides, with its action; no
   later rule is evaluated. When no rule matches, `default` decides, with the
   rule name `default`.
3. **Event.** One event, `keep` or `drop` (Events).
4. **State**, after the decision (Snapshot):
   - an entity with no state gets state from this report, with `kept_ms`
     null;
   - otherwise, when the report's `time_ms` is greater than or equal to the
     stored `time_ms`, the stored `time_ms`, `lat`, `lon`, `course`,
     `speed_ms` and `stale_ms` are replaced by the report's (absent keys are
     stored as null); an older report replaces none of them;
   - when the decision is `keep`, `kept_ms` becomes the report's `time_ms`
     if `kept_ms` is null or smaller, and is unchanged otherwise.

State is kept for every entity that has had an accepted report, whatever the
decisions. A pack with no rules decides every report by `default`, with an
empty trace.

## Tick

`tick(now_ms)` drops no report. It removes the state of entities that have not
reported for longer than the pack's `forget_ms`, so the state stays bounded.

Entities in key order. Each entity gives one trace record (Trace) with
`value = now_ms - time_ms` (its stored `time_ms`) and `limit = forget_ms`. The
entity is forgotten when `value > limit`: its state is removed and the event
`forget` is given. A `now_ms` earlier than an entity's `time_ms` gives a
negative `value` and keeps the entity. With no entities, a tick gives no
events and no trace.

After an entity is forgotten, a `near` condition naming it is unknown, and its
next report is decided as its first (`interval` and `order` find no kept
report).

## Events

Each event is a JSON object.

| Event | Fields |
|---|---|
| `reject` | `reason` (`missing:<key>`) |
| `keep` | `entity`, `rule` (the rule name, or `default`) |
| `drop` | `entity`, `rule` (the rule name, or `default`) |
| `forget` | `entity` |

`ingest` gives exactly one event. `tick` gives one `forget` per forgotten
entity, in key order.

## Trace

A condition gives
`{"stage":"rule","rule":<rule name>,"entity":<key>,"test":<condition>,"negated":<bool>,"value":...,"limit":...,"pass":<bool>}`,
plus `"unknown": true` when the result is unknown. `test` is the condition
name as written (`key` for every form of `key`). `negated` is true when the
condition is written with `not`. `value` and `limit` are as in the Conditions
table; numbers from the pack are numbers, and `in` lists are lists of
strings.

A tick gives, per entity,
`{"stage":"forget","entity":<key>,"test":"age","value":<now_ms - time_ms>,"limit":<forget_ms>,"pass":<value > limit>}`.

Records are in the order the conditions and entities are evaluated.

## Snapshot

`snapshot()` returns `{"entities": {...}}`, a map from entity key to
`{"time_ms", "lat", "lon", "course", "speed_ms", "stale_ms", "kept_ms"}`.
`time_ms` is the greatest `time_ms` of any accepted report of the entity, and
`lat`, `lon`, `course`, `speed_ms`, `stale_ms` are from the report that set
it (null when that report did not have them). `kept_ms` is the greatest
`time_ms` of a kept report, or null. The snapshot is the whole state: two
engines with equal snapshots and the same pack decide every later call the
same way.

## Pack

A pack is a directory `packs/<name>/` holding `pack.def` and `vectors/`.
`pack.def` is line-oriented UTF-8; `#` starts a comment; blank lines are
ignored. Each line is a directive followed by its arguments, separated by
spaces or tabs.

```
pack       <name>
version    <semver>
default    keep | drop
forget_ms  <ms>
rule       <name> keep | drop
when       [not] <condition> <param>=<value> ...
```

- `pack`, `version`, `default` and `forget_ms` are required and appear once
  each; `pack` and `version` take one token.
- `rule` takes exactly a name and an action. It starts a rule, and the
  `when` lines after it, up to the next `rule` or the end of the file, are its
  conditions in order. A rule with no `when` line, a `when` before the first
  `rule`, two rules with the same name, and a rule named `default` are load
  errors. A pack may have no rules.
- `when` takes an optional `not`, a condition name, and that condition's
  parameters as `name=value`; the name is the text before the first `=`
  and the value is the rest. A parameter without `=`, a parameter given
  twice, a parameter the condition does not take, and a missing parameter are
  load errors. `order` takes no parameters.
- Other directives may appear in any order relative to the rules.

Parameter sets, exactly:

| Condition | Parameters |
|---|---|
| `circle` | `lat`, `lon`, `radius_m` |
| `polygon` | `vertices` |
| `near` | `reference`, `radius_m`, `max_age_ms` |
| `env`, `affiliation`, `source`, `uid` | `in` |
| `key` | `name` and one of: `eq`; `in`; `min`; `max`; `min` and `max` |
| `has` | `name` |
| `speed`, `altitude` | one of: `min`; `max`; `min` and `max` |
| `interval` | `min_ms` |
| `order` | none |

Values:

| Value | Grammar and limits |
|---|---|
| number (`lat`, `lon`, `radius_m`, `min`, `max`) | `-?[0-9]+(\.[0-9]+)?`, read as the nearest binary64; no exponent, no `+`, no leading `.` |
| integer (`forget_ms`, `max_age_ms`, `min_ms`) | `[0-9]+`, at most 9223372036854775807 |
| `lat` | a number from -90 to 90 |
| `lon` | a number from -180 to 180 |
| `radius_m` | a number 0 or above |
| `min`, `max` | numbers; when both are given, `min <= max` |
| `min_ms`, `forget_ms` | an integer above 0 |
| `max_age_ms` | an integer 0 or above |
| `vertices` | `<lat>,<lon>;<lat>,<lon>;...` with at least three pairs, each a `lat` and a `lon` as above |
| `in` | one or more non-empty items separated by `,` |
| `reference`, `name`, `eq` | a non-empty token |

A value that does not match its grammar or limits is a load error. An unknown
directive, a repeated `pack`, `version`, `default` or `forget_ms`, a missing
required directive, an unknown condition name, a `default` or `rule` action
other than `keep` or `drop`, and a `rule` line without exactly two arguments
are load errors.

## Floats

Engines use IEEE-754 binary64 and the formulas above in the order written.
Vectors compare floats within `1e-6 * max(1, abs(want))`, and place no
float decision within that distance of its threshold. These decisions are
exact, and vectors test their thresholds: those on integers (`interval`,
`order`, the `near` age and `stale_ms`, `forget`), and those that compare a
report's number with a pack number with no arithmetic between them (the
bounds of `speed`, `altitude` and `key` range, `key` eq and in). A JSON number
in a report and a number in a pack are each read as the nearest binary64. Polygon boundary vectors use coordinates whose arithmetic in the
boundary step is exact in binary64.

## Open points

Two cases this version does not decide. No vector covers them, and engines
may differ on them until a later version settles them with vectors.

| Point | Section |
|---|---|
| An integer literal in a report outside the signed 64-bit range, and a `key` eq, in or range, or a `speed` or `altitude` range, on an integer above 2^53 in magnitude | Reports, Conditions |
| A report or reference within 1 m of a pole, where `cos(rad(lat))` in the reference prediction is near 0 | Geometry |
