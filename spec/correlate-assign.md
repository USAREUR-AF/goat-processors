# Correlate by assignment specification

Status: Written. Version 0.6. A second method for the correlate function.
Engines implement it from this document, [correlate.md](correlate.md) and the
vectors, never from another engine's source.
Version 0.6 adds the time offset of Sensor bias (directive `time_offset`) and
takes `time_default` and the measurement variance of `correlate.md` 0.8; a
pack without them behaves as in 0.5. Version 0.5 added three optional
directives, each without effect when absent:
`bias` (Sensor bias), `margin` (Window) and, from `correlate.md` 0.7,
`restart`. "Why a window without a margin adds errors" (in Window) states
the fault they correct. Version 0.4 took the pack line `maneuver` (it was
`manoeuvre` in 0.3).

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
each accepted report), Two-model filter (when the pack has `maneuver`),
Restart (when the pack has `restart`), Tests (every test and its trace
record, with the change of Sensor bias when the pack has `bias`), Floats.

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
A's filter and `p`, `pp` the fused estimate of M. Each member's predicted
`pp` has its timing variance added (`correlate.md`, Track estimate) before
the fused estimate is formed, and `pp_a` is A's filter `pp` plus A's timing
variance. With `bias`, each member of M is then moved into A's frame (Sensor
bias), also before the fused estimate is formed.

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

## Sensor bias

A pack may add `bias sigma_m=<s> floor_m=<f> gate=<g>`. The correlator then
keeps one position **offset** per unordered pair of sources: how far the
second source's positions, in key order of the two source names, sit east
and north of the first's. A sensor with a fixed position error is then
compared with the others with its offset taken out, and the uncertainty of
the offset is added to the comparison.

**State.** For a pair key `"<S>|<T>"` (`S` before `T` in key order): per axis
the offset `o` and the weight sum `w`; one variance `var` for both axes; and
`n`, the count of accepted pairs. A pair with no stored state reads as
`o = 0`, `w = 0`, `var = s²`, `n = 0`; its state is stored when its first
pair is accepted.

**Moving B into A's frame.** Let `a_src` be A's source and `b_src` B's, and
let them differ. B's predicted position on each axis becomes `p + o` with
`pp + var`, from pair `"<b_src>|<a_src>"`, when `b_src` is before `a_src` in
key order; or `p - o` with `pp + var`, from pair `"<a_src>|<b_src>"`, when
`a_src` is before `b_src`. Two
entities of one source are never moved. This applies wherever B is
predicted to be compared with A: the `distance`, `window` and `mahalanobis`
tests of `correlate.md` (to B's prediction, before the test formula;
`distance` and `window` read no `pp`, so only the offset changes them), and
each member of M in Cost. A system track's estimate for output moves no
member.

**Update.** At each tick, after the commit (Window step 4): for each committed
system track in creation order, its members that are not retiring, in key
order, and each pair `X`, `Y` of them (`X` before `Y` in key order) from two
different sources, at least one of which is among the tick's rows (Window
step 2):

1. Of the two, call `ES` the entity whose source is first in key order and
   `ET` the other. Predict both to `now_ms` (not moved). Per axis
   `y = p_ET - p_ES` and `r = pp_ES + pp_ET`.
2. `d² = sum over east, north of (y - o)² / (var + r)`, with the pair's state.
3. When `d² < g` the pair is accepted: `n = n + 1`; `var = s² / (n + 1)`, or
   `f²` when that is below `f²`; per axis `w = w_before + 1/r` and
   `o = o_before + ((1/r) / w) * (y - o_before)`. The state is stored.
   Otherwise nothing changes.
4. Trace:
   `{"stage":"bias","a":<X>,"b":<Y>,"test":"offset","value":d²,"limit":g,"pass":<accepted>,"east":<o>,"north":<o>,"var":<var>,"pairs":<n>}`,
   with the state after step 3.

**Time offset.** With `time_offset sigma_ms=<t>` (it needs `bias`), each pair
of sources also has a clock offset `tau`, in seconds: how far `T`'s clock is
ahead of `S`'s. A report stamped `tau` seconds late gives where the object was
`tau` seconds earlier, so the observed offset is `y = o - v*tau` per axis,
with `v` the object's velocity. An offset that grows with speed along the
track is then read as a clock error, not as a position offset; without
`time_offset`, `o` absorbs it.

The state adds `tau` and eight sums `S1` to `S8`, all 0 when no state is
stored, and `o` is no longer a running mean:

- Moving B into A's frame uses `o - v*tau` in place of `o` on each axis, with
  `v` B's predicted velocity on that axis.
- In the update, per axis `v = (v_ES + v_ET) / 2` from the two predictions to
  `now_ms`, and step 2 uses `(y - (o - v*tau))²` in place of `(y - o)²`.
- When the pair is accepted, `n` and `var` change as in step 3, and with
  `we = 1/r_east`, `wn = 1/r_north`, `ve`, `vn`, `ye`, `yn` of this pair:
  `S1 += we`; `S2 += wn`; `S3 += we*ve`; `S4 += wn*vn`;
  `S5 += we*ve*ve + wn*vn*vn`; `S6 += we*ye`; `S7 += wn*yn`;
  `S8 += we*ve*ye + wn*vn*yn` (each `+=` one addition of the whole
  right-hand side). Then, with `po = 1/s²` and `pt = 1/(t/1000)²`:
  `a11 = po + S1`; `a22 = po + S2`; `a13 = -S3`; `a23 = -S4`;
  `a33 = pt + S5`; `b1 = S6`; `b2 = S7`; `b3 = -S8`;
  `tau = (b3 - a13*b1/a11 - a23*b2/a22) / (a33 - a13*a13/a11 - a23*a23/a22)`;
  `o_east = (b1 - a13*tau) / a11`; `o_north = (b2 - a23*tau) / a22`.
  This is the weighted least-squares fit of `y = o - v*tau` over every
  accepted pair, with priors of 0 for `o` (standard deviation `s`) and for
  `tau` (standard deviation `t` ms). The weight sum `w` of each axis is `S1`
  and `S2`.
- The trace record adds `"time_offset_ms": tau*1000`.

The update reads the committed membership, also with `margin`: an offset is
learned only from memberships the window has committed.

The offset is the mean of the observed offsets weighted by `1/r`. Only the
ratio of weights matters, so a sensor that understates its error does not
drive the estimate, and `var` falls with the count of accepted pairs, not
with the reported errors.

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
number of ticks a history spans and the number of histories kept. The
optional `margin <m>` keeps only histories whose total is within `m` of the
best, and makes `system` report the best history's latest membership.

**On each tick** at `now_ms`, in this order:

1. **Staleness.** The stale entities are found by the rule of
   `correlate.md`, among entities that are not retiring, in key order. Every
   history gets a new record whose membership is a copy of its latest
   membership, with cost 0 and no choices. In that copy, each stale entity in
   key order leaves its system track if it has one (event `leave`, reason
   `stale`; event `end` if that empties it), and gets event `drop`. Then
   each *restarted* entity (`correlate.md`, Restart: its filter started again
   since the previous tick) that is not stale, in key order, leaves its
   system track if it has one (event `leave`, reason `restart`; event `end`
   if that empties it). The events go to the new record, and no entity is
   restarted after this step. Each stale entity is now *retiring*: it is in
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
   as in Memberships (not the parent's total plus the assignment total).
   Candidates are ordered by their total, then by `h`, then by `r`. The first
   `k` are the histories for the next source, in that order. With `margin`,
   of those only the ones whose total is at most `cut = best + m` are kept,
   where `best` is the first candidate's total.
4. **Commit**, when the best history (rank 0) has `n` records. Its oldest
   record is committed: its events are emitted, the committed membership
   becomes that record's membership, and each entity with a `drop` event in
   it is removed. Each entity's `system` becomes its system track in the
   committed membership, or null. Every history whose oldest record's
   `choices` differ from the committed record's is pruned. Each kept history
   loses its oldest record and keeps its rank order.
5. **Bias.** With `bias`, the update of Sensor bias.
6. **Output.** One event `system` per committed system track in creation
   order (with `margin`: per system track of the best history's latest
   membership), with the fused estimate of all its members at `now_ms`, in
   degrees, with `course = deg(atan2(v_east, v_north))` in [0, 360) and
   `speed_ms = hypot(v_east, v_north)`, plus `hae` from the member with the
   greatest `last_time_ms` whose last report has `hae` (ties to key order),
   when there is one. Retiring members of the committed membership are included; with `margin`,
   the best history's latest membership holds none. Then, when `n` is above
   1, one event `provisional` per system track of the best history's latest
   membership, in creation order.

Every history has the same number of records, one per tick not yet
committed, so the commit happens on every tick from the `n`-th on. With
`window 1`, step 4 commits the tick at once: the committed membership is
the best assignment of each source in turn, as in version 0.2 with the tie
rule of Ranking.

**Why a window without a margin adds errors.** On the benchmark's random set,
with the two-model filter, a window of 2 with 3 histories makes more errors
than no window: identity swaps rise from 160 to 275 and false merges from 12
to 72. Two faults cause it.

1. The output lags. `system` reports the committed membership, `n - 1`
   ticks old. When a sensor moves a track number to another object, or
   drops a track, the newest reports already split the pair, but the output
   keeps it in one system track for `n - 1` more ticks. Scored on the best
   history's latest membership instead, the same run has 15 false merges.
2. Alternatives overtake on accumulated cost. A history that moved a track
   at one tick holds its new system track at the next, where `keep_bonus`
   now favors the new place. Over the window the move gives up `keep_bonus`
   once while its cost advantage counts on every tick, and every kept
   history can overtake the best this way. A track of middle uncertainty
   between two system tracks of one object (one offset by a sensor bias)
   then moves between them on most of its reports.

`margin` corrects both: `system` reports the best history's latest
membership, so nothing lags, and only near-ties stay as alternatives. The
commit still waits `n - 1` ticks; it fixes the committed membership, the
events, the drops and the histories kept.

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
| `leave` | `system`, `entity`, `reason` (`assign`, `stale` or `restart`) |
| `end` | `system` |
| `system` | `system`, `members`, `lat`, `lon`, `course`, `speed_ms`, `hae` when known |
| `provisional` | `system`, `members` |

A report gives only `new` or `reject`. A tick gives, in order: the committed
record's events, when a record is committed (per stale entity `leave`,
`end`, `drop`; per restarted entity `leave`, `end`; then per source the
assignment events); then one `system` per committed system track (with
`margin`, per system track of the best history's latest membership); then, when `window` is above 1, one `provisional`
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
`{"stage":"history","a":<h>,"b":<r>,"test":"total","value":<candidate total>,"limit":<cut, or null without margin>,"pass":<true when kept>}`.
When a tick is committed: one record per history in rank order before
pruning,
`{"stage":"history","a":<rank>,"b":null,"test":"commit","value":<its total>,"limit":null,"pass":<true when kept>}`,
the total still including the record being committed.
The two-model filter and restart records of `correlate.md` come from
`ingest`. With `bias`, the `bias` records of Sensor bias follow the commit
records of the tick (or the sources' records when nothing is committed).

## Snapshot

`{"ref", "entities", "systems", "next_system", "reported"}`. Each entity
holds `last_time_ms`, `system` (its committed system track, or null) and
`filter` as in `correlate.md` (with `models` and `mode` when the pack has
`maneuver`); `systems` maps each committed system track name to its
members in key order; `next_system` is the committed counter; `reported`
lists, in key order, the entities that reported since the previous tick.
With `restart` the snapshot also holds `restarted`, the restarted entities in
key order. With `bias` it holds `bias`, mapping each stored pair key to
`{"east", "weight_east", "north", "weight_north", "var", "pairs"}` (`o` and
`w` per axis, `var`, `n`), keys in order; with `time_offset` each also has
`"time_offset_ms"` (`tau*1000`) and `"sums"` (`[S1, ..., S8]`).

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
maneuver   accel_var=<q2> p_enter=<per s> p_leave=<per s>
gate        <test> <param>=<value> ...
new_cost    <number>
keep_bonus  <number>
stale_ms    <ms>
restart     gate=<g>
time_default <source_id> error_ms=<ms> state=<state>
bias        sigma_m=<s> floor_m=<f> gate=<g>
time_offset sigma_ms=<t>
window      <n>
hypotheses  <k>
margin      <m>
```

`pack`, `version`, `filter`, `new_cost`, `keep_bonus` and `stale_ms` are
required and appear once; `maneuver`, `window` and `hypotheses` are optional
and appear at most once; `gate` repeats and may be absent, in which case every
column entry passes. `new_cost` must be above 0 and `keep_bonus` 0 or above.
`window` and `hypotheses` are integers, 1 or above, written as one value.
`hypotheses` above 1 needs `window` above 1. `restart`, `bias` and `margin`
are optional and appear at most once. `bias` takes exactly `sigma_m`,
`floor_m` and `gate`, with `sigma_m` and `gate` above 0 and `floor_m` above 0
and at most `sigma_m`. `margin` is one number above 0 and needs `hypotheses`
above 1. `time_offset` is optional, appears at most once, takes exactly
`sigma_ms`, above 0, and needs `bias`. Otherwise the pack does not load. `maneuver`, `restart` and `time_default`
follow `correlate.md`.

A `method` value other than `confirm` or `assign` does not load. `method`
may appear anywhere in the file; which directives are required or refused is
checked once the whole file is read. `confirm`, `hold`, `confirm_count`,
`hold_failures`, `same_source`, `output` and `priority` are load errors with
`method assign`; `new_cost`, `keep_bonus`, `window`, `hypotheses`, `margin`,
`bias` and `time_offset` are load errors with `method confirm`. A pack with no `method` line uses `method
confirm` (`correlate.md`); `method confirm` may also be written.

## Open points

None for this method beyond those of `correlate.md` (the Pack rows there
apply to the shared directives).
