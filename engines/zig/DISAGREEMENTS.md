# Disagreements and open points, zig engine

## Vectors that contradict the specification

None. Every load vector (01 to 73) and every scenario vector (01 to 56)
agrees with `spec/correlate.md` 0.8 and `spec/correlate-assign.md` 0.6 as
this engine reads them.

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

## Points `correlate-assign.md` 0.6 leaves open

None found. (The gate-record order left open in 0.2 is now stated in Trace.)
Readings this engine takes where the text could be read more than one way:

| Point | This engine |
|---|---|
| "among the tick's rows" in the Sensor bias update | The rows of Window step 2: the entities reported since the previous tick, an entity found stale in step 1 not among them. |
| `time` in an entity of the `assign` snapshot | Written as in `correlate.md` Snapshot (the entity's `filter` "as in `correlate.md`"); scenario vector 56 agrees. |
| The bias `offset` record of a pair not accepted, with `time_offset` | `time_offset_ms` is the stored `tau` (0 for a pair with no stored state), the state after step 3 as for `east` and `north`. |
| A restarted entity that is also stale at the tick | It leaves with reason `stale` and gets `drop`; it gives no `leave` with reason `restart` (Window step 1, "that is not stale"). |

## Points `correlate.md` 0.8 leaves open

| Point | This engine |
|---|---|
| A `time_error_ms` written as an integer literal outside the signed 64-bit range | `std.json` keeps it as a number string, read as the nearest binary64: a number, so present when finite. |
| A `time_default` source id that holds `=` | Not a source id ("a first token without `=`"): a load error. |
| The prediction a later report's measurement variance and its Restart test read | One prediction of the entity to the report's `time_ms`, taken before the update, serves both. |
| An integer literal outside the signed 64-bit range | `std.json` does not return it as an integer, so it is the wrong type where an integer is required. |
| `same` between booleans, arrays or objects | Compared structurally: equal when of the same kind and equal element by element. |

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
