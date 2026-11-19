# Correlate by assignment specification

Status: Written. Version 0.3. A second method for the correlate function.
Engines implement it from this document, [correlate.md](correlate.md) and the
vectors, never from another engine's source.

## What this method does

Every track a source reports belongs to exactly one **system track**, the
correlator's single picture of one object. At each tick, the tracks that
reported since the previous tick are assigned to system tracks by an exact
minimum-cost assignment, one source at a time, and each system track's
estimate is the uncertainty-weighted combination of its members.

With a window of `n` ticks, the correlator keeps the best `k` joint
assignment histories over the last `n` ticks instead of committing each
tick's best assignment at once. It commits a tick only when `n - 1` later
ticks have been seen, and commits it from the history that is best over all
of them. A decision that looks best at one tick and is contradicted by the
next reports is then never committed.

It differs from the `confirm` method of `correlate.md` in four ways:

| | `confirm` | `assign` |
|---|---|---|
| Output | groups of two or more, plus ungrouped tracks | one system track per object, including objects one source sees |
| When it decides | on each report | on each tick, over the reports since the previous tick; with a window, `n - 1` ticks later |
| How it decides | the nearest candidate that passed the tests on `confirm_count` reports in a row | the assignment with the least total cost for all of a source's tracks at once; with a window, the least total over the window |
| Estimate | one member's filter | every member's filter, weighted by its uncertainty |

## Shared with `correlate.md`

These sections of `correlate.md` apply unchanged: Reports (keys, types,
rejects, entity key), Frame, Track estimate (the per-entity filter, updated on
each accepted report), Two-model filter (when the pack has `manoeuvre`),
Tests (every test and its trace record), Floats.

## Memberships

A **membership** is one picture of the system tracks: the system tracks
`s1`, `s2`, ... with their members, their creation order, and the counter
that names the next one. The counter never reuses a number, so creation
order is the order of the numbers. A system track holds one or more
entities, at most one per `track.source_id` once a source's events are all
applied.

The **committed** membership is the one the output reports. A **history** is
a list of pending ticks, oldest first, each a **record** holding:

| Field | Meaning |
|---|---|
| `cost` | the sum, left to right from 0, of the assignment totals of that tick's sources in key order |
| `choices` | `[entity, chosen]` per entity assigned at that tick, sources in key order, entities in key order; `chosen` is a system track name or `"alone"` |
| `events` | the membership events that tick produced in this history |
| `systems`, `next_system` | the membership after that tick |

A history's **total** is the sum, left to right from 0, of its records'
`cost`, oldest first. A history's *latest membership* is that of its newest
record, or the committed membership when it has none. Every history extends
the committed membership: the oldest record of each was decided from it.

At the start there is one history with no records.

## Assignment of one source

**Fused estimate.** The estimate of a set of entities M at time `t`, per axis:
predict each member's filter to `t` (Track estimate, prediction; Two-model
filter, prediction), then, summing over members in key order,
`pp = 1 / sum(1/pp_i)`, `p = pp * sum(p_i/pp_i)`,
`vv = 1 / sum(1/vv_i)`, `v = vv * sum(v_i/vv_i)`.

**Cost.** For an entity A and a set M, predicted to A's `last_time_ms`:
`d² = sum over east, north of (pa - p)² / (pp_a + pp)`, where `pa`, `pp_a` are
A's filter and `p`, `pp` the fused estimate of M.

For one source S, its reported entities R (key order) and one membership:

1. **Columns.** Every system track of the membership whose members, leaving
   out the entities of R, are not empty and include no entity of S. Call
   those remaining members the track's *others*. Columns are in creation
   order.
2. **Entries.** For each entity A of R and each column T: run the pack's
   `gate` tests between A and each of T's others in key order (as in
   `correlate.md`, the other predicted to A's time). The first failing test
   ends the entry: no further test runs against that other or against T's
   later others.
   If every test passed, the entry is `d²` of A against T's others, minus
   `keep_bonus` when A is a member of T in this membership; otherwise the
   entry is forbidden.
   Each A also has its own entry *alone*, cost `new_cost`, minus `keep_bonus`
   when A is now the only member of its system track.
3. **Assignments.** An assignment chooses for each A either one column or
   *alone*, each column chosen at most once, no forbidden entry chosen. One
   always exists: every A alone. The assignments are ranked as in Ranking.
4. **Apply** an assignment to the membership, entities of R in key order:
   - A chose the column it is already in, or chose *alone* and is already
     alone: nothing.
   - Otherwise A leaves its system track if it has one (event `leave`, reason
     `assign`); a system track left empty ends (event `end`). Then A joins the
     chosen column (event `join`), or starts a new system track alone (event
     `start`), named by the membership's counter.

Between two events of one source a system track may briefly hold two
entities of one source.

## Ranking

The **choice vector** of an assignment lists, per entity of R in key order,
the index of its choice: a column's position in creation order (0 for the
first), and for *alone* the number of columns, so *alone* comes after every
column.

The **total** of an assignment is the sum of its chosen entries, taken in
ascending order of value and added left to right from 0. Two assignments
that choose the same values in any arrangement therefore have the same total,
bit for bit.

Assignment X ranks before assignment Y when X's total is below Y's, or the
totals are equal and X's choice vector comes first: at the first entity
where the two differ, X's index is the smaller. Equal means equal as binary64
values. This is a strict order, so the ranking is unique. The first
assignment in this order is the least-cost assignment; with equal least
totals it is the one with the smaller choice vector.

The **ranked assignments** of a source are the first `k` assignments in this
order (fewer when fewer exist). An engine may find them by any exact method.
The reference partitions the remaining assignments around each one found
(Murty's method). Each part's first assignment comes from the exact
assignment, and rows are fixed one at a time in key order to apply the
choice-vector rule.

Vectors never hold two assignment totals, or two history totals, that are
within the float tolerance of each other without being equal. The vector
generator refuses them.

## Window

The pack's `window <n>` (default 1) and `hypotheses <k>` (default 1) set the
number of ticks a history spans and the number of histories kept.

**On each tick** at `now_ms`, in this order:

1. **Staleness.** The stale entities are found by the rule of
   `correlate.md`, among entities that are not retiring, in key order. Every
   history gets a new record whose membership is a copy of its latest
   membership, with cost 0 and no choices. In that copy, each stale entity in
   key order leaves its system track if it has one (event `leave`, reason
   `stale`; event `end` if that empties it), and gets event `drop`. The
   events go to the new record. Each stale entity is now *retiring*: it is in
   no history's latest membership, it keeps its filter and its place in the
   committed membership, and it is removed when its drop is committed.
2. **Rows.** The entities that had an accepted report since the previous
   `tick` call (since the start, for the first), by call order and whatever
   their `time_ms`. An entity counts once however many reports it had, and an
   entity found stale in step 1 is not among them. They are grouped by
   `track.source_id`.
3. **Sources**, in key order. For each history `h` in rank order (0 first),
   with its newest record's membership: compute S's columns and entries,
   rank its assignments, and take the first `k`. Each ranked assignment `r`
   gives one candidate history: `h` with its newest record replaced by a
   copy that has the assignment applied to its membership. The copy's events
   are the record's events followed by the apply events. Its choices are the
   record's choices followed by this source's. Its cost is the record's cost
   plus the assignment total, and its total is recomputed from its records
   as in Memberships (not the parent's total plus the assignment total). Candidates are ordered by their total, then by
   `h`, then by `r`. The first `k` are the histories for the next source,
   in that order.
4. **Commit**, when the best history (rank 0) has `n` records. Its oldest
   record is committed: its events are emitted, the committed membership
   becomes that record's membership, and each entity with a `drop` event in
   it is removed. Each entity's `system` becomes its system track in the
   committed membership, or null. Every history whose oldest record's
   `choices` differ from the committed record's is pruned. Each kept history
   loses its oldest record and keeps its rank order.
5. **Output.** One event `system` per committed system track in creation
   order, with the fused estimate of all its members at `now_ms`, in
   degrees, with `course = deg(atan2(v_east, v_north))` in [0, 360) and
   `speed_ms = hypot(v_east, v_north)`, plus `hae` from the member with the
   greatest `last_time_ms` whose last report has `hae` (ties to key order),
   when there is one. Retiring members are included. Then, when `n` is above
   1, one event `provisional` per system track of the best history's latest
   membership, in creation order.

Every history has the same number of records, one per tick not yet
committed, so the commit happens on every tick from the `n`-th on. With
`window 1`, step 4 commits the tick at once: the committed membership is
the best assignment of each source in turn, as in version 0.2 with the tie
rule of Ranking.

**Reports for a retiring entity.** A report whose entity key is retiring is
rejected with `{"ev":"reject","entity":<key>,"reason":"retiring"}` and changes
no state. This check comes after the required keys and before the
out-of-order check. After the drop is committed, a report for that key is a
new entity. With `window 1` no entity is retiring between calls.

## Events

| Event | Fields |
|---|---|
| `reject`, `new`, `drop` | as in `correlate.md`; `reject` also has reason `retiring`, with `entity` |
| `start` | `system`, `entity` |
| `join` | `system`, `entity` |
| `leave` | `system`, `entity`, `reason` (`assign` or `stale`) |
| `end` | `system` |
| `system` | `system`, `members`, `lat`, `lon`, `course`, `speed_ms`, `hae` when known |
| `provisional` | `system`, `members` |

A report gives only `new` or `reject`. A tick gives, in order: the committed
record's events, when a record is committed (per stale entity `leave`,
`end`, `drop`; then per source the assignment events); then one `system` per
committed system track; then, when `window` is above 1, one `provisional`
per system track of the best history.

## Trace

With `window 1` the trace of a source is:

- Gate tests: the records of `correlate.md` with stage `gate`, in the order
  they run: entities of R in key order, per entity the columns in creation
  order, per column the others in key order.
- After the source's entries are computed, each entry is a record
  `{"stage":"assign","a":<entity>,"b":<system track or "alone">,"test":"cost","value":<cost or null>,"limit":null,"pass":<true unless forbidden>}`,
  entities in key order and, per entity, columns in creation order then
  `alone`.
- After the assignment, each entity of R in key order gets
  `{"stage":"assign","a":<entity>,"b":<chosen>,"test":"choice","value":<its entry>,"limit":null,"pass":true}`.

With `window` above 1, per source, for each history `h` in rank order, all
of `h`'s records before the next history's: its gate and cost records as
above, each with the added key `"h":<h>`, then, per ranked assignment `r` in
rank order, its choice records with the added keys `"h":<h>` and `"r":<r>`.
After every history of the source: one record per
candidate in candidate order,
`{"stage":"history","a":<h>,"b":<r>,"test":"total","value":<candidate total>,"limit":null,"pass":<true when kept>}`.
When a tick is committed: one record per history in rank order before
pruning,
`{"stage":"history","a":<rank>,"b":null,"test":"commit","value":<its total>,"limit":null,"pass":<true when kept>}`,
the total still including the record being committed.
The two-model filter records of `correlate.md` come from `ingest`.

## Snapshot

`{"ref", "entities", "systems", "next_system", "reported"}`. Each entity
holds `last_time_ms`, `system` (its committed system track, or null) and
`filter` as in `correlate.md` (with `models` and `mode` when the pack has
`manoeuvre`); `systems` maps each committed system track name to its
members in key order; `next_system` is the committed counter; `reported`
lists, in key order, the entities that reported since the previous tick.

With `window` above 1 the snapshot also holds `retiring`, the retiring
entities in key order, and `histories`, the histories in rank order, each
`{"total", "records": [{"cost", "choices", "events", "systems",
"next_system"}, ...]}` with records oldest first. The snapshot is the whole
state: two engines with equal snapshots decide every later call the same
way.

## Pack

As in `correlate.md`, with `method assign` and these directives only:

```
pack        <name>
version     <semver>
method      assign
filter      accel_var=<q> default_ce_m=<m> vel_sigma_ms=<m/s> unknown_vel_ms=<m/s>
manoeuvre   accel_var=<q2> p_enter=<per s> p_leave=<per s>
gate        <test> <param>=<value> ...
new_cost    <number>
keep_bonus  <number>
stale_ms    <ms>
window      <n>
hypotheses  <k>
```

`pack`, `version`, `filter`, `new_cost`, `keep_bonus` and `stale_ms` are
required and appear once; `manoeuvre`, `window` and `hypotheses` are optional
and appear at most once; `gate` repeats and may be absent, in which case every
column entry passes. `new_cost` must be above 0 and `keep_bonus` 0 or above.
`window` and `hypotheses` are integers, 1 or above, written as one value.
`hypotheses` above 1 needs `window` above 1. Otherwise the pack does not
load. `manoeuvre` follows `correlate.md`.

A `method` value other than `confirm` or `assign` does not load. `method`
may appear anywhere in the file; which directives are required or refused is
checked once the whole file is read. `confirm`, `hold`, `confirm_count`,
`hold_failures`, `same_source`, `output` and `priority` are load errors with
`method assign`; `new_cost`, `keep_bonus`, `window` and `hypotheses` are load
errors with `method confirm`. A pack with no `method` line uses `method
confirm` (`correlate.md`); `method confirm` may also be written.

## Open points

None for this method beyond those of `correlate.md` (the Pack rows there
apply to the shared directives).
