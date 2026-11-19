# Correlate by assignment specification

Status: Written. Version 0.1. A second method for the correlate function.
Engines implement it from this document, [correlate.md](correlate.md) and the
vectors, never from another engine's source.

## What this method does

Every track a source reports belongs to exactly one **system track**, the
correlator's single picture of one object. At each tick, the tracks that
reported since the previous tick are assigned to system tracks by an exact
minimum-cost assignment, one source at a time, and each system track's
estimate is the uncertainty-weighted combination of its members.

It differs from the `confirm` method of `correlate.md` in four ways:

| | `confirm` | `assign` |
|---|---|---|
| Output | groups of two or more, plus ungrouped tracks | one system track per object, including objects one source sees |
| When it decides | on each report | on each tick, over the reports since the previous tick |
| How it decides | the nearest candidate that passed the tests on `confirm_count` reports in a row | the assignment with the least total cost for all of a source's tracks at once |
| Estimate | one member's filter | every member's filter, weighted by its uncertainty |

## Shared with `correlate.md`

These sections of `correlate.md` apply unchanged: Reports (keys, types,
rejects, entity key), Frame, Track estimate (the per-entity filter, updated on
each accepted report), Tests (every test and its trace record), Floats.

## Assignment

**System tracks** are named `s1`, `s2`, ... in creation order; the counter
never reuses a number. A system track holds one or more entities, at most one
per `track.source_id`.

**Fused estimate.** The estimate of a set of entities M at time `t`, per axis:
predict each member's filter to `t` (Track estimate, prediction), then
`pp = 1 / sum(1/pp_i)`, `p = pp * sum(p_i/pp_i)`,
`vv = 1 / sum(1/vv_i)`, `v = vv * sum(v_i/vv_i)`.

**Cost.** For an entity A and a set M, predicted to A's `last_time_ms`:
`d² = sum over east, north of (pa - p)² / (pp_a + pp)`, where `pa`, `pp_a` are
A's filter and `p`, `pp` the fused estimate of M.

**On each tick** at `now_ms`, after staleness (below), take the entities that
had an accepted report since the previous tick (since the start, for the first
tick). Group them by `track.source_id` and take the sources in key order. For
one source S, with its reported entities R (key order):

1. **Columns.** Every system track whose members, leaving out the entities of
   R, are not empty and include no entity of S. Call those remaining members
   the track's *others*. Columns are in creation order.
2. **Entries.** For each entity A of R and each column T: run the pack's
   `gate` tests between A and each of T's others in key order (as in
   `correlate.md`, the other predicted to A's time; stop at the first failure).
   If every test passed, the entry is `d²` of A against T's others, minus
   `keep_bonus` when A is a member of T; otherwise the entry is forbidden.
   Each A also has its own entry *alone*, cost `new_cost`, minus `keep_bonus`
   when A is now the only member of its system track.
3. **Assignment.** Choose for each A either one column or *alone*, each column
   chosen at most once, with the least total cost. Vectors are written so the
   least total is unique.
4. **Apply**, entities of R in key order:
   - A chose the column it is already in, or chose *alone* and is already
     alone: nothing.
   - Otherwise A leaves its system track if it has one (event `leave`, reason
     `assign`); a system track left empty ends (event `end`). Then A joins the
     chosen column (event `join`), or starts a new system track alone (event
     `start`).

The memberships after one source are the ones the next source sees.

**Staleness**, first in each tick, entities in key order, by the rule of
`correlate.md`: a stale entity leaves its system track (event `leave`, reason
`stale`), a system track left empty ends (event `end`), and the entity is
removed (event `drop`).

**Output**, last in each tick, system tracks in creation order: event
`system` with the fused estimate of all members at `now_ms`, in degrees, with
`course = deg(atan2(v_east, v_north))` in [0, 360) and `speed_ms =
hypot(v_east, v_north)`, plus `hae` from the member with the greatest
`last_time_ms` whose last report has `hae` (ties to key order), when there is
one.

## Events

| Event | Fields |
|---|---|
| `reject`, `new`, `drop` | as in `correlate.md` |
| `start` | `system`, `entity` |
| `join` | `system`, `entity` |
| `leave` | `system`, `entity`, `reason` (`assign` or `stale`) |
| `end` | `system` |
| `system` | `system`, `members`, `lat`, `lon`, `course`, `speed_ms`, `hae` when known |

A report gives only `new` or `reject`. A tick gives, in order: per stale
entity `leave`, `end`, `drop`; then per source the assignment events; then one
`system` per system track.

## Trace

Gate tests give the records of `correlate.md` with stage `gate`. After a
source's entries are computed, each entry is a record
`{"stage":"assign","a":<entity>,"b":<system track or "alone">,"test":"cost","value":<cost or null>,"limit":null,"pass":<true unless forbidden>}`,
entities in key order and, per entity, columns in creation order then
`alone`. After the assignment, each entity of R in key order gets
`{"stage":"assign","a":<entity>,"b":<chosen>,"test":"choice","value":<its cost>,"limit":null,"pass":true}`.

## Snapshot

`{"ref", "entities", "systems", "next_system"}`. Each entity holds
`last_time_ms`, `system` and `filter` as in `correlate.md`; `systems` maps a
system track name to its members in key order.

## Pack

As in `correlate.md`, with `method assign` and these directives only:

```
pack        <name>
version     <semver>
method      assign
filter      accel_var=<q> default_ce_m=<m> vel_sigma_ms=<m/s> unknown_vel_ms=<m/s>
gate        <test> <param>=<value> ...
new_cost    <number>
keep_bonus  <number>
stale_ms    <ms>
```

All but `gate` are required and appear once; `gate` repeats. `confirm`,
`hold`, `confirm_count`, `hold_failures`, `same_source`, `output` and
`priority` are load errors with `method assign`. A pack with no `method` line
uses `method confirm` (`correlate.md`); `method confirm` may also be written.
