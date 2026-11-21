# Disagreements and open points, zig engine

## Vectors that contradict the specification

None. Every load vector (01 to 90) and every scenario vector (the 59 files
numbered 01 to 63 under `packs/correlate-*/vectors/`) agrees with
`spec/correlate.md` 1.0 and `spec/correlate-assign.md` 0.7 as this engine
reads them.

## Filter: vectors that contradict `filter.md` 0.1

None. Every filter load vector (01 to 50) and every filter scenario vector
(01 to 27) agrees with `spec/filter.md` 0.1 as this engine reads it.

## Filter: points `filter.md` 0.1 leaves open

| Point | This engine |
|---|---|
| An integer literal in a report outside the signed 64-bit range | `std.json` keeps it as a number string: the wrong type for `time_ms` and `stale_ms`, a number (read as the nearest binary64) for `lat`, `lon`, `key`, `speed`, `altitude`. |
| `key` and `speed`/`altitude` on an integer above 2^53 | The integer is converted to the nearest binary64 before comparing. |
| A reference within 1 m of a pole | The formula is evaluated as written; no special case. |
| Differences of two times (`near` age, `interval`, tick `age`) that overflow int64 | Computed in i128; a trace value outside int64 is written as a float. |
| `version` | Any single token is accepted (load vector 03 uses `version 1`); no semver check. |

## Points `correlate-assign.md` 0.7 leaves open

None found. (The gate-record order left open in 0.2 is now stated in Trace.)
Readings this engine takes where the text could be read more than one way:

| Point | This engine |
|---|---|
| "among the tick's rows" in the Sensor bias update | The rows of Window step 2: the entities reported since the previous tick, an entity found stale in step 1 not among them. |
| `time` in an entity of the `assign` snapshot | Written as in `correlate.md` Snapshot (the entity's `filter` "as in `correlate.md`"); scenario vector 56 agrees. |
| The bias `offset` record of a pair not accepted, with `time_offset` | `time_offset_ms` is the stored `tau` (0 for a pair with no stored state), the state after step 3 as for `east` and `north`. |
| A restarted entity that is also stale at the tick | It leaves with reason `stale` and gets `drop`; it gives no `leave` with reason `restart` (Window step 1, "that is not stale"). |
| Sensor bias still names "the `distance`, `window` and `mahalanobis` tests" | Editorial, for the spec owner: the `window` test is retired in `correlate.md` 1.0 and does not load (load vector 74), so no assign pack can hold one. The move applies to every test this engine runs, through the method's comparison hook. |

## Points `correlate.md` 1.0 leaves open

| Point | This engine |
|---|---|
| A velocity so large that a prediction lands far outside the plane | The same loop, reached from the output: a `speed_ms` of 1.2e29 (a JSON integer too long for int64, read as a number) gives a prediction about 1e24 m east, and `toDegrees` wraps its longitude for ever. The report fuzzer found it when the 1.0 packs changed which random reports each pack gets; it now gives `speed_ms` no such value, as it already gives `lat` and `lon` none. Same question for proc-coord. |
| A longitude far outside [-180, 180] (found by the refactor's report fuzzer) | "Frame" brings `lon - lon0` into (-180, 180] "by adding or subtracting 360", and this engine does that in a loop, as written: a longitude of 1e12 takes about 3e9 steps, and one of 1e300 never ends (1e300 - 360 is 1e300 in binary64). Every function that uses the Frame (correlate, fuse, quality, and filter's Geometry) shares it. A remainder (`fmod`) would end, but it is not the formula written and could round differently, so the refactor did not change it. For proc-coord: should a report with `abs(lon) > 180` (or not finite) be rejected, or the wrap be defined as a remainder? |
| A `time_error_ms` written as an integer literal outside the signed 64-bit range | `std.json` keeps it as a number string, read as the nearest binary64: a number, so present when finite. |
| A `time_default` source id that holds `=` | Not a source id ("a first token without `=`"): a load error. |
| The prediction a later report's measurement variance and its Restart test read | One prediction of the entity to the report's `time_ms`, taken before the update, serves both. |
| An integer literal outside the signed 64-bit range | `std.json` does not return it as an integer, so it is the wrong type where an integer is required. |
| `same` between booleans, arrays or objects | Compared structurally: equal when of the same kind and equal element by element. |

Readings of `correlate.md` 1.0 the vectors do not fix:

| Point | This engine |
|---|---|
| "above its source's stale time" with `stale_rate` | `now_ms - last_time_ms` converted to binary64 and compared with `k * m` (a binary64); with `stale_ms` the integers are compared, as before. |
| Which reports append an interval | Every accepted report of an entity that already existed, a restarted one included, and an interval of 0 included. A source's list outlives its entities: a source whose entities were all dropped keeps its list, and its snapshot entry. |
| The `llr` record's `increment` | The increment before clamping; `value` is `L` after clamping (scenario vectors 59 to 61 agree). |
| A pair at `lo` or below after an update in "A is not in a group" | Removed at once, a pair just created by this update included; a pair created at `up` by a first update is ready. |
| A in a group whose link pair has no `L` | The update starts from 0 and stores the pair. |
| The `same` tests rerun without trace in "A is not in a group" | All the `same` tests of the `gate` line, in pack order, stopping at the first failure, whichever test failed in the traced run (a `same` test among them included). |
| `output fused` with a member whose predicted `pp` or `vv` is 0 or below (a tick earlier than a member's last report predicts backward) | The formula is evaluated as written, with no special case; IEEE-754 gives what it gives. |

## Quality: vectors that contradict the specification

None. Every quality load vector (01 to 62) and every scenario vector (q01 to
q22) agrees with `spec/quality.md` 0.2 as this engine reads it.

## Points `quality.md` 0.2 leaves open

| Point | This engine |
|---|---|
| An integer literal outside the signed 64-bit range | As for correlate: `std.json` does not give it as an integer, so `time_ms` is missing and `received_ms` absent; a `time_error_ms` so written is a number string, read as the nearest binary64. In `pack.def`, an integer that does not fit `i64` is a load error. |

## Readings of `quality.md` 0.2 the vectors do not fix

| Point | This engine |
|---|---|
| `rule` followed directly by a parameter (`rule scope=entity ...`) | The first token is the name; `=` is not a name character, so it is a load error ("no name"). Load vector 19 agrees. |
| `#` inside a token | Starts a comment anywhere on the line, as the Pack section says. A control character inside a comment is still a load error (Pack step 2 comes before step 3). |
| The source latest when the report's entity was created by another source (colliding keys) | Only entities whose source is the report's `track.source_id` count, so the report's own entity does not; scenario vector q22 agrees (`source_order` inputs `[1000, null]`). |
| A `time_default` source id that holds `=` | Not a source id: a load error, as in correlate. |
| `lateness` when the input clock is a mean of two middle values that is a whole number | Written as a binary64 (the clock is one), compared as a number. |

## `fuse.md` 0.2

### Vectors that contradict the specification

None. Every fuse load vector (01 to 33) and every fuse scenario vector (01 to
16) agrees with `spec/fuse.md` 0.2 as this engine reads it.

### Points `fuse.md` 0.2 leaves open

| Point | This engine |
|---|---|
| An integer literal outside the signed 64-bit range | `std.json` keeps it as a number string: the wrong type where an integer is required (`time_ms`, `stale_ms`), a number where a number is read (`lat`, `hae`, an attribute value). |
| `majority`, `max` and `min` between integers above 2^53 | Compared as binary64. |
| `version` value | Taken as one value with no further check; `fuse.md` gives `version` no rule beyond "one value". |
