# Quality specification

Status: Written. Version 0.1. Every language's engine implements this document
and passes every vector. Engines are written from this document,
[correlate.md](correlate.md) (for the sections it names) and the vectors,
never from another engine's source.

## What quality does

Quality measures every entity and every source from the reports alone, and
applies the actions that a pack's rules attach to those measures. It forwards
every accepted report, changed by the actions in force: marked, with its
error inflated, or withheld.

| Measures | From |
|---|---|
| how often an entity reports, and its largest gap | report times |
| how old its last report is | report time and tick time |
| how late its reports arrive | `received_ms` against `time_ms` |
| whether its reported error is honest | each report's distance from the entity's predicted position, against the predicted plus the reported variance |
| whether its reported speed agrees with its movement | successive positions against `speed_ms` |
| how many reports are out of order or repeat a time | report times |
| how often optional keys are missing | `ce`, `course` with `speed_ms`, `hae` |

An engine has four operations:

| Operation | Returns |
|---|---|
| `load_pack(dir)` | a pack, or an error |
| `ingest(report)` | the events and the trace for that report |
| `tick(now_ms)` | the events and the trace for that time |
| `snapshot()` | the whole state, as a map |

Quality is deterministic. Its only clock is the time carried in the input
(`time_ms` and `received_ms` of a report, `now_ms` of a tick). It never reads
the wall clock, never uses randomness, and visits every collection in the
orders this document defines.

## Reports

A report is a map from shared-model key to value. Quality reads these keys:

| Key | Type | Required | Use |
|---|---|---|---|
| `track.source_id` | string | yes | the source |
| `uid` | string | yes | the source's identifier for the track |
| `time_ms` | int | yes | time the report is valid, epoch ms |
| `lat`, `lon` | number, deg | yes | position |
| `ce` | number, m | no | one-sigma horizontal error; the pack's `default_ce_m` when absent |
| `course` | number, deg | no | with `speed_ms`, a velocity measurement |
| `speed_ms` | number, m/s | no | reported speed; with `course`, a velocity measurement |
| `hae` | number, m | no | read only for the missing-key rate |
| `received_ms` | int | no | time the report reached the system that produced it, epoch ms |
| `quality.marks` | list of strings | no | marks from an earlier quality stage; extended on output |

The entity key is `<track.source_id>/<uid>`. Keys are compared as byte
strings; "key order" means ascending byte order. The source of an entity is
the `track.source_id` of its first accepted report.

Types, missing required keys and the `reject` event follow
[correlate.md](correlate.md), section Reports: the required keys are checked
in the order of the table; a missing one gives
`{"ev":"reject","reason":"missing:<key>"}` and changes no state. An optional
key that is `null` or of the wrong type is absent, and so is a `ce` of 0 or
below. `received_ms` must be an integer. A boolean is never a number.

Unlike correlate, a report earlier than its entity's latest report is **not**
rejected: quality counts it (see Order).

## Order

Each accepted report has an *order*, from its `time_ms` `t` and the entity's
latest accepted time `last` before it:

| Order | When | Moves the filter and `last` |
|---|---|---|
| `first` | the entity has no report yet | yes: creates them |
| `advance` | `t > last` | yes |
| `duplicate` | `t == last` | no |
| `out-of-order` | `t < last` | no |

Each accepted report has a *window time* `wt`: `t` for `first` and `advance`,
`last` for `duplicate` and `out-of-order`. A late report is therefore counted
in the window of the time it arrived, not of the time it describes.

## Frame and filter

Positions are converted to the local plane of [correlate.md](correlate.md),
section Frame. The reference is the `lat`/`lon` of the first report the engine
accepts, of any order, and it never moves.

Each entity keeps the filter of [correlate.md](correlate.md), section Track
estimate, with the pack's `filter` parameters: created by its `first` report,
predicted and updated by each `advance` report, untouched by `duplicate` and
`out-of-order` reports. The measurement error is the report's `ce` (or
`default_ce_m`). Measures always use the report as received; an action never
changes what quality measures.

Each entity also keeps `last_pos`, the plane position of its latest `first`
or `advance` report as reported (not filtered).

## Samples

On each accepted report, with `t`, `last` and the plane position `(e, n)` of
the report, these samples are taken:

| Sample | Taken when | Value |
|---|---|---|
| `interval` | order `advance` | `t - last`, ms (an integer) |
| `latency` | `received_ms` present, any order | `received_ms - t`, ms (an integer; may be negative) |
| `nis` | order `advance` | below |
| `speed_err` | order `advance` and `speed_ms` present | below |

**`nis`**, the normalized innovation squared. Predict the entity's filter to
`t` (correlate.md, prediction, `dt = (t - last) / 1000`), giving per axis the
predicted position `p` and variance `pp`. With `r = ce * ce`:
`de = e - p_east`, `dn = n - p_north`, `se = pp_east + r`, `sn = pp_north + r`,
`nis = de * de / se + dn * dn / sn`, evaluated left to right. The filter is
then updated from that prediction as correlate.md states. When the report's
error is honest, `nis` follows a chi-square distribution with two degrees of
freedom, mean 2; a mean well above 2 means the source understates its error.

**`speed_err`**. `dt = (t - last) / 1000`,
`implied = hypot(e - last_pos_e, n - last_pos_n) / dt`,
`speed_err = abs(implied - speed_ms)`, m/s. `last_pos` is the value before
this report.

Each report also records three presence flags: `ce` (a valid `ce`), `vel`
(valid `course` and valid `speed_ms`), `hae` (a valid `hae`).

The report's *record* holds `wt`, `time_ms`, `order`, the four samples (null
when not taken) and the three flags. It is appended to the entity's window in
arrival order.

## Window

At each tick, before measuring, every entity's window drops the records with
`wt <= now_ms - window_ms`. The window at that tick is the records left, in
arrival order: every record with `wt > now_ms - window_ms`. There is no upper
bound: a record with `wt > now_ms` is in the window.

A record is dropped only by a tick; between ticks the window grows.

## Entity measures

Computed at each tick, per entity, over its window `W` with the pack's
`min_samples` `k`. A *statistic* over a sample is computed from the records of
`W` that hold that sample, in window order; it is `null` (absent) when fewer
than `k` records hold it. Absent is never written as 0.

| Measure | Value | Unit |
|---|---|---|
| `reports` | number of records in `W` | count |
| `interval_last` | the `interval` of the last record in `W` that holds one; statistic | ms |
| `interval_mean` | mean of the `interval` samples; statistic | ms |
| `interval_max` | largest `interval` sample; statistic | ms |
| `age` | `now_ms - last`, the entity's latest accepted time; always present, may be negative | ms |
| `latency_mean` | mean of the `latency` samples; statistic | ms |
| `latency_max` | largest `latency` sample; statistic | ms |
| `nis_mean` | mean of the `nis` samples; statistic | none |
| `speed_err_mean` | mean of the `speed_err` samples; statistic | m/s |
| `out_of_order` | records in `W` with order `out-of-order`; always present | count |
| `duplicate` | records in `W` with order `duplicate`; always present | count |
| `missing_ce` | records in `W` without `ce`, divided by `reports`; null when `reports < k` | fraction |
| `missing_vel` | the same for `vel` | fraction |
| `missing_hae` | the same for `hae` | fraction |

A mean is `s / n` where `s` starts at 0.0 and adds each sample in window order
in binary64, and `n` is the number of samples. A fraction is `count / reports`
in binary64.

## Source measures

A source exists while it has at least one entity. At each tick its measures
aggregate its entities' measures from the same tick. "Present" values are the
non-null values of that measure across the source's entities; they are taken
in entity key order.

| Measure | Aggregate | Empty (no present value) |
|---|---|---|
| `reports`, `out_of_order`, `duplicate` | sum | — (always present) |
| `interval_last`, `interval_mean`, `latency_mean`, `nis_mean`, `speed_err_mean`, `missing_ce`, `missing_vel`, `missing_hae` | mean over entities: `s / n` as above, in key order | null |
| `interval_max`, `latency_max` | largest | null |
| `age` | smallest (the freshest entity) | — (always present) |
| `entities` | number of entities of the source | — |

A source mean is the mean of its entities' values, not a mean over all their
records: each entity counts once.

## Rules

A rule names one measure of one scope, a condition on it, and an action.

```
rule <name> scope=entity|source measure=<m> op=<op> limit=<x> for=<n> clear=<x> action=<a> [factor=<f>]
```

The *subjects* of a rule are the entities (scope `entity`) or the sources
(scope `source`). Each rule keeps, per subject, a state `{count, active}`,
created as `{0, false}` the first time the rule is evaluated for that subject.

**Evaluation**, once per tick per rule per subject, with `v` the subject's
measure:

- Not active. The condition is met when `v` is present and `v op limit` holds
  (`<`, `<=`, `>`, `>=`). Met: `count = count + 1`; not met: `count = 0`.
  When `count` reaches `for`, the rule becomes active (event `action-start`)
  and `count` is set to 0.
- Active. The rule clears when `v` is present and, for op `>` or `>=`,
  `v < clear`; for op `<` or `<=`, `v > clear`. Cleared: the rule becomes
  inactive (event `action-end`, reason `clear`); `count` stays 0. An absent
  `v` never clears a rule.

`clear` gives hysteresis: between `clear` and `limit` an active rule stays
active and an inactive one does not start. Measures are compared as binary64
values; an integer measure equal to `limit` is compared exactly.

**Actions** in force for a report: every active rule of scope `entity` for
the report's entity and every active rule of scope `source` for its source.

| Action | Effect on later reports |
|---|---|
| `mark` | the forwarded report carries the rule name in `quality.marks` |
| `downgrade` | the forwarded `ce` is multiplied by `factor` |
| `drop` | the report is withheld |
| `alert` | none: the `action-start` and `action-end` events are the alert |

An action applies to reports ingested after the tick that starts it and
before the tick that ends it. It never changes an earlier event.

## Forwarding

Every accepted report gives one `pass` event. Take the actions in force other
than `alert`, in pack order; their rule names are the event's `rules`.

- When any of them is `drop`, the event has `"withheld": true` and no
  `report`.
- Otherwise `"withheld": false` and `report` is the report exactly as
  received (every key, including keys quality does not read and optional keys
  it treated as absent), with these changes:
  - **`ce`**, when at least one `downgrade` is in force: `x` is the report's
    valid `ce`, or `default_ce_m` when it has none; `x = x * factor` for each
    `downgrade` in pack order; the forwarded `ce` is `x`.
  - **`quality.marks`**, when at least one `mark` is in force: start from the
    received `quality.marks` when it is a list whose items are all strings,
    else from an empty list; append each `mark` rule name in pack order that
    the list does not already hold. Without a `mark` in force,
    `quality.marks` is forwarded as received.

## Tick

`tick(now_ms)`, in this order:

1. **Order.** When an earlier tick had a greater `now_ms`, the tick is
   rejected with `{"ev":"reject","reason":"tick-out-of-order"}` and changes
   no state. A tick equal to the previous one runs.
2. **Forget entities**, key order. An entity with
   `now_ms - last > forget_ms` is forgotten: each active rule of scope
   `entity` for it, in pack order, ends (event `action-end`, reason `forget`,
   `value` null); every rule state for it is removed; the entity is removed
   (event `forget` with `entity`).
3. **Forget sources**, key order. A source that had entities at the start of
   the tick and has none now is forgotten in the same way, with scope
   `source` (event `forget` with `source`).
4. **Window.** Every entity's window drops its old records.
5. **Entities**, key order: compute the measures; event `quality`; evaluate
   each rule of scope `entity` in pack order.
6. **Sources**, key order: compute the measures; event `quality`; evaluate
   each rule of scope `source` in pack order.

A tick with no entities gives no events.

## Ingest

`ingest(report)`, in this order: check the required keys (reject ends it);
set the reference if there is none; find the order; take the samples
(`interval`, `latency`, `nis`, `speed_err`, in that order, each only when its
table row says); create the entity (event `new`) or update its filter,
`last` and `last_pos` as the order says; append the record; emit `pass`.

## Events

Each event is a JSON object with `ev` and the fields below. A `null` field is
present with value `null`.

| Event | Fields |
|---|---|
| `reject` | `reason`: `missing:<key>` or `tick-out-of-order` |
| `new` | `entity` |
| `pass` | `entity`, `rules` (list), `withheld` (boolean), `report` (only when not withheld) |
| `quality` | `scope` (`entity` or `source`), `subject`, `measures`: every measure of the scope's table as a key, `null` when absent |
| `action-start` | `rule`, `scope`, `subject`, `action`, `value` (the measure that started it) |
| `action-end` | `rule`, `scope`, `subject`, `action`, `reason` (`clear` or `forget`), `value` (the measure; null for `forget`) |
| `forget` | `entity`, or `source` |

Event order for a report: `reject`, or `new` (first report only) then `pass`.
For a tick: the forget events of step 2, then of step 3, then per entity its
`quality` followed by the `action-start`/`action-end` of its rules in pack
order, then the same per source.

## Trace

On ingest, one record per sample, in the order taken, preceded by the order:
`{"stage":"sample","entity":<key>,"sample":<name>,"value":<v>,"inputs":[...]}`.

| `sample` | `value` | `inputs` |
|---|---|---|
| `order` | the order | `[t, last]`, `last` null for `first` |
| `interval` | `t - last` | `[t, last]` |
| `latency` | `received_ms - t` | `[received_ms, t]` |
| `nis` | `nis` | `[de, dn, se, sn]` |
| `speed_err` | `speed_err` | `[implied, speed_ms]` |

A rejected report has no trace.

On tick, one record per rule evaluation, in evaluation order:
`{"stage":"rule","rule":<name>,"subject":<key or source>,"measure":<m>,"value":<v or null>,"limit":<x>,"pass":<bool>,"count":<n>,"active":<bool>}`.
For a rule not active before the evaluation, `limit` is the rule's `limit` and
`pass` whether the condition was met; for one active before it, `limit` is
the rule's `clear` and `pass` whether it cleared. `count` and `active` are the
state after the evaluation.

## Snapshot

```
{"ref": [lat0, lon0] or null,
 "last_tick": <now_ms of the last tick that ran> or null,
 "entities": {<key>: {"source", "last_time_ms", "last_pos": [e, n],
                      "filter": {"east": [p, v, pp, pv, vv], "north": [...]},
                      "window": [<record>, ...]}},
 "rules": {<rule name>: {<subject>: {"count": n, "active": bool}}}}
```

A record is `{"wt", "time_ms", "order", "interval", "latency", "nis",
"speed_err", "ce", "vel", "hae"}`, the samples null when not taken and the
flags booleans. `rules` holds every rule of the pack, with `{}` when it has no
state. The snapshot is the whole state: two engines with equal snapshots
decide every later call the same way.

## Pack

A pack is a directory `packs/quality-<name>/` holding `pack.def` and
`vectors/`. `pack.def` is line-oriented UTF-8; `#` starts a comment; blank
lines are ignored; tokens are separated by spaces or tabs. Each line is a
directive and its values.

```
pack     <name>
version  <semver>
filter   accel_var=<q> default_ce_m=<m> vel_sigma_ms=<m/s> unknown_vel_ms=<m/s>
window   window_ms=<ms> min_samples=<n> forget_ms=<ms>
rule     <name> scope=<s> measure=<m> op=<op> limit=<x> for=<n> clear=<x> action=<a> [factor=<f>]
```

`pack`, `version`, `filter` and `window` are required and appear once. `rule`
repeats, may be absent, and its order is pack order.

**Values.** A *number* is written `-?[0-9]+(\.[0-9]+)?` and read as the
nearest binary64. An *integer* is written `[0-9]+`. A rule name is one or more
of `A-Z a-z 0-9 . _ -`.

Any of these is a load error:

| Directive | Error |
|---|---|
| any | an unknown directive; `pack`, `version`, `filter` or `window` repeated or missing |
| `pack`, `version` | not exactly one value |
| `filter`, `window`, `rule` | a parameter without `=`; a repeated, unknown or missing parameter |
| `filter` | a value that is not a number; `accel_var` below 0; `default_ce_m`, `vel_sigma_ms` or `unknown_vel_ms` 0 or below |
| `window` | a value that is not an integer; any value below 1 |
| `rule` | no name, or a name with another character; a name used by an earlier rule |
| `rule` | `scope` not `entity` or `source`; `measure` not in the scope's measures table (`entities` is a source measure only) |
| `rule` | `op` not `<`, `<=`, `>` or `>=`; `action` not `mark`, `downgrade`, `drop` or `alert` |
| `rule` | `limit` or `clear` not a number; `for` not an integer or below 1 |
| `rule` | `clear` above `limit` for op `>` or `>=`; `clear` below `limit` for op `<` or `<=` |
| `rule` | `downgrade` without `factor`; `factor` with another action; `factor` not a number or below 1 |

## Packs

| Pack | Rules | Use |
|---|---|---|
| `quality-feed` | `silent` (age, alert), `slow` (mean interval, mark), `late` (worst latency, drop), `source-latent` (source mean latency, alert), `disorder` (out-of-order reports, mark) | feed health: freshness, regularity, latency, order |
| `quality-consistency` | `overconfident` (source `nis_mean`, downgrade ×2), `no-error` (source `missing_ce`, alert), `speed-mismatch` (`speed_err_mean`, mark) | reported against observed error |

## Vectors

Scenario vectors are under `packs/quality-*/vectors/` and load vectors under
`spec/quality-load-vectors/`, both in the format of
[vector-format.md](vector-format.md). An engine's quality runner reads only
those. `tools/make-quality-vectors.py` states each scenario's events by hand
and refuses to write a vector that differs.

## Floats

Engines use IEEE-754 binary64 and the formulas above in the order written.
Vectors compare floats within `1e-6 * max(1, abs(want))` (vector-format.md).
No vector places a decision on a float measure within that distance of a
`limit` or `clear`; vectors do test integer measures (`age`, counts,
intervals) exactly at a `limit`.

## Open points

Cases this version does not decide. No vector covers them, and engines may
differ on them until a later version settles them with vectors.

| Point | Section |
|---|---|
| An integer literal outside the signed 64-bit range | Reports (as correlate.md) |
| Two sources whose key strings collide (`a/b` with uid `c` and `a` with uid `b/c`) | Reports |
| A forwarded `ce` that overflows binary64 after many `downgrade` factors | Forwarding |
| Whitespace other than space and tab inside a `pack.def` line | Pack |
