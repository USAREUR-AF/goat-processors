// spec/quality.md 0.2 "Samples" (the record), "Window", "Entity measures" and
// "Source measures".
//
// The registration point of a quality measure: `table` below. A measure is a
// name, whether it is a source measure only, its entity measure (a pure
// function of the entity's window) and how a source aggregates it from its
// entities. The `Measure` enum, the order of the `measures` object of a
// `quality` event and the names a rule may use all come from the table.
const std = @import("std");
const qpack = @import("pack.zig");
const TimeState = qpack.TimeState;

// "Order".
pub const Order = enum {
    first,
    advance,
    duplicate,
    out_of_order,

    pub fn name(o: Order) []const u8 {
        return switch (o) {
            .first => "first",
            .advance => "advance",
            .duplicate => "duplicate",
            .out_of_order => "out-of-order",
        };
    }
};

// "Samples": a report's record. Samples are null when not taken.
pub const Record = struct {
    wt: i64,
    time_ms: i64,
    order: Order,
    interval: ?i64,
    latency: ?i64,
    // `clock - t`: an integer when the input clock is one, else binary64.
    lateness: ?Num,
    nis: ?f64,
    speed_err: ?f64,
    time_error: ?f64,
    time_state: ?TimeState,
    // True when the `source_order` sample is `out-of-order`.
    source_out_of_order: bool,
    ce: bool,
    vel: bool,
    hae: bool,
};

// A measure value: counts, ages and intervals are integers, means and fractions are binary64.
pub const Num = union(enum) {
    int: i64,
    float: f64,

    pub fn toJson(n: Num) @import("std").json.Value {
        return switch (n) {
            .int => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
        };
    }

    pub fn toF64(n: Num) f64 {
        return switch (n) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
        };
    }
};

// "Window": drop the records with `wt <= now_ms - window_ms`, keeping arrival order.
pub fn dropOld(window: *std.ArrayList(Record), now_ms: i64, window_ms: i64) void {
    const cutoff = now_ms - window_ms;
    var kept: usize = 0;
    for (window.items) |r| {
        if (r.wt > cutoff) {
            window.items[kept] = r;
            kept += 1;
        }
    }
    window.shrinkRetainingCapacity(kept);
}

// A mean is `s / n`, `s` starting at 0.0 and adding each value in order.
fn mean(values: []const f64) f64 {
    var s: f64 = 0.0;
    for (values) |v| s += v;
    return s / @as(f64, @floatFromInt(values.len));
}

// "Entity measures": a statistic over one integer sample (`interval` or
// `latency`), from the records of the window that hold it, in window order.
const IntStat = struct { last: ?Num, mean: ?Num, max: ?Num };

fn intStat(buf: []f64, window: []const Record, k: usize, comptime field: []const u8) IntStat {
    var n: usize = 0;
    var last: i64 = 0;
    var max: i64 = 0;
    for (window) |r| {
        if (@field(r, field)) |x| {
            if (n == 0 or x > max) max = x;
            last = x;
            buf[n] = @floatFromInt(x);
            n += 1;
        }
    }
    if (n < k) return .{ .last = null, .mean = null, .max = null };
    return .{ .last = .{ .int = last }, .mean = .{ .float = mean(buf[0..n]) }, .max = .{ .int = max } };
}

// "Entity measures": `lateness_mean`, `lateness_max`, `lateness_min`, a
// statistic over the `lateness` samples. Each sample keeps its own type, so the
// largest and smallest are written as they were taken.
const LatenessStat = struct { mean: ?Num, max: ?Num, min: ?Num };

fn latenessStat(buf: []f64, window: []const Record, k: usize) LatenessStat {
    var n: usize = 0;
    var max: Num = undefined;
    var min: Num = undefined;
    for (window) |r| {
        if (r.lateness) |x| {
            if (n == 0 or x.toF64() > max.toF64()) max = x;
            if (n == 0 or x.toF64() < min.toF64()) min = x;
            buf[n] = x.toF64();
            n += 1;
        }
    }
    if (n < k) return .{ .mean = null, .max = null, .min = null };
    return .{ .mean = .{ .float = mean(buf[0..n]) }, .max = max, .min = min };
}

// "Entity measures": `time_error_mean` and `time_error_max`, a statistic over
// the `time_error` samples.
const TimeErrorStat = struct { mean: ?Num, max: ?Num };

fn timeErrorStat(buf: []f64, window: []const Record, k: usize) TimeErrorStat {
    var n: usize = 0;
    var max: f64 = 0;
    for (window) |r| {
        if (r.time_error) |x| {
            if (n == 0 or x > max) max = x;
            buf[n] = x;
            n += 1;
        }
    }
    if (n < k) return .{ .mean = null, .max = null };
    return .{ .mean = .{ .float = mean(buf[0..n]) }, .max = .{ .float = max } };
}

// "Entity measures": `time_state_last` and `time_state_worst`, the code of the
// last `time_state` sample and the largest code; a statistic.
const TimeStateStat = struct { last: ?Num, worst: ?Num };

fn timeStateStat(window: []const Record, k: usize) TimeStateStat {
    var n: usize = 0;
    var last: i64 = 0;
    var worst: i64 = 0;
    for (window) |r| {
        if (r.time_state) |state| {
            const code = qpack.timeStateCode(state);
            if (n == 0 or code > worst) worst = code;
            last = code;
            n += 1;
        }
    }
    if (n < k) return .{ .last = null, .worst = null };
    return .{ .last = .{ .int = last }, .worst = .{ .int = worst } };
}

// The mean of one float sample (`nis` or `speed_err`); a statistic.
fn floatMean(buf: []f64, window: []const Record, k: usize, comptime field: []const u8) ?Num {
    var n: usize = 0;
    for (window) |r| {
        if (@field(r, field)) |x| {
            buf[n] = x;
            n += 1;
        }
    }
    if (n < k) return null;
    return .{ .float = mean(buf[0..n]) };
}

// `missing_<flag>`: records without the flag divided by `reports`; null when `reports < k`.
fn missing(window: []const Record, k: usize, comptime flag: []const u8) ?Num {
    if (window.len < k) return null;
    var count: usize = 0;
    for (window) |r| {
        if (!@field(r, flag)) count += 1;
    }
    return .{ .float = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(window.len)) };
}

// `missing_time`: records without a `time_state` sample divided by `reports`;
// null when `reports < k`.
fn missingTimeOf(window: []const Record, k: usize) ?Num {
    if (window.len < k) return null;
    var count: usize = 0;
    for (window) |r| {
        if (r.time_state == null) count += 1;
    }
    return .{ .float = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(window.len)) };
}

// ---- the registry -------------------------------------------------------------

// What an entity measure reads: the window `W` with `min_samples` `k`, at
// `now_ms`, for an entity whose latest accepted time is `last`. `buf` holds at
// least `W.len` values.
pub const Window = struct {
    buf: []f64,
    records: []const Record,
    k: usize,
    now_ms: i64,
    last: i64,
};

// "Source measures": how a source's value comes from its entities' values.
pub const Aggregate = enum {
    // Sum of the integers, always present.
    sum,
    // Mean of the present values; null when none.
    mean,
    // Largest present value, keeping its type; null when none.
    max,
    // Smallest present value, keeping its type; null when none.
    min,
    // Smallest integer, always present (`age`: the freshest entity).
    min_int,
    // The number of entities.
    count,
};

pub const Entry = struct {
    name: [:0]const u8,
    source_only: bool = false,
    entity: ?*const fn (w: Window) ?Num,
    source: Aggregate,
};

// "Entity measures" and "Source measures", in the order of their tables.
// Adding a measure is one entry here.
pub const table = [_]Entry{
    .{ .name = "reports", .entity = reports, .source = .sum },
    .{ .name = "interval_last", .entity = intervalLast, .source = .mean },
    .{ .name = "interval_mean", .entity = intervalMean, .source = .mean },
    .{ .name = "interval_max", .entity = intervalMax, .source = .max },
    .{ .name = "age", .entity = age, .source = .min_int },
    .{ .name = "latency_mean", .entity = latencyMean, .source = .mean },
    .{ .name = "latency_max", .entity = latencyMax, .source = .max },
    .{ .name = "lateness_mean", .entity = latenessMean, .source = .mean },
    .{ .name = "lateness_max", .entity = latenessMax, .source = .max },
    .{ .name = "lateness_min", .entity = latenessMin, .source = .min },
    .{ .name = "nis_mean", .entity = nisMean, .source = .mean },
    .{ .name = "speed_err_mean", .entity = speedErrMean, .source = .mean },
    .{ .name = "out_of_order", .entity = outOfOrder, .source = .sum },
    .{ .name = "duplicate", .entity = duplicate, .source = .sum },
    .{ .name = "source_out_of_order", .entity = sourceOutOfOrder, .source = .sum },
    .{ .name = "missing_ce", .entity = missingCe, .source = .mean },
    .{ .name = "missing_vel", .entity = missingVel, .source = .mean },
    .{ .name = "missing_hae", .entity = missingHae, .source = .mean },
    .{ .name = "time_error_mean", .entity = timeErrorMean, .source = .mean },
    .{ .name = "time_error_max", .entity = timeErrorMax, .source = .max },
    .{ .name = "time_state_last", .entity = timeStateLast, .source = .max },
    .{ .name = "time_state_worst", .entity = timeStateWorst, .source = .max },
    .{ .name = "missing_time", .entity = missingTime, .source = .mean },
    .{ .name = "entities", .source_only = true, .entity = null, .source = .count },
};

// One tag per entry of `table`, in its order.
pub const Measure = blk: {
    var fields: [table.len]std.builtin.Type.EnumField = undefined;
    for (table, 0..) |e, i| fields[i] = .{ .name = e.name, .value = i };
    break :blk @Type(.{ .Enum = .{
        .tag_type = std.math.IntFittingRange(0, table.len),
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

pub fn entry(m: Measure) Entry {
    return table[@intFromEnum(m)];
}

// Every measure of a scope; null is absent.
pub const Measures = std.EnumArray(Measure, ?Num);

// ---- entity measures -------------------------------------------------------------

fn reports(w: Window) ?Num {
    return .{ .int = @intCast(w.records.len) };
}
fn intervalLast(w: Window) ?Num {
    return intStat(w.buf, w.records, w.k, "interval").last;
}
fn intervalMean(w: Window) ?Num {
    return intStat(w.buf, w.records, w.k, "interval").mean;
}
fn intervalMax(w: Window) ?Num {
    return intStat(w.buf, w.records, w.k, "interval").max;
}
fn age(w: Window) ?Num {
    return .{ .int = w.now_ms - w.last };
}
fn latencyMean(w: Window) ?Num {
    return intStat(w.buf, w.records, w.k, "latency").mean;
}
fn latencyMax(w: Window) ?Num {
    return intStat(w.buf, w.records, w.k, "latency").max;
}
fn latenessMean(w: Window) ?Num {
    return latenessStat(w.buf, w.records, w.k).mean;
}
fn latenessMax(w: Window) ?Num {
    return latenessStat(w.buf, w.records, w.k).max;
}
fn latenessMin(w: Window) ?Num {
    return latenessStat(w.buf, w.records, w.k).min;
}
fn nisMean(w: Window) ?Num {
    return floatMean(w.buf, w.records, w.k, "nis");
}
fn speedErrMean(w: Window) ?Num {
    return floatMean(w.buf, w.records, w.k, "speed_err");
}
fn countOrder(w: Window, o: Order) ?Num {
    var n: i64 = 0;
    for (w.records) |r| {
        if (r.order == o) n += 1;
    }
    return .{ .int = n };
}
fn outOfOrder(w: Window) ?Num {
    return countOrder(w, .out_of_order);
}
fn duplicate(w: Window) ?Num {
    return countOrder(w, .duplicate);
}
fn sourceOutOfOrder(w: Window) ?Num {
    var n: i64 = 0;
    for (w.records) |r| {
        if (r.source_out_of_order) n += 1;
    }
    return .{ .int = n };
}
fn missingCe(w: Window) ?Num {
    return missing(w.records, w.k, "ce");
}
fn missingVel(w: Window) ?Num {
    return missing(w.records, w.k, "vel");
}
fn missingHae(w: Window) ?Num {
    return missing(w.records, w.k, "hae");
}
fn timeErrorMean(w: Window) ?Num {
    return timeErrorStat(w.buf, w.records, w.k).mean;
}
fn timeErrorMax(w: Window) ?Num {
    return timeErrorStat(w.buf, w.records, w.k).max;
}
fn timeStateLast(w: Window) ?Num {
    return timeStateStat(w.records, w.k).last;
}
fn timeStateWorst(w: Window) ?Num {
    return timeStateStat(w.records, w.k).worst;
}
fn missingTime(w: Window) ?Num {
    return missingTimeOf(w.records, w.k);
}

// "Entity measures", over the window `W` with `min_samples` `k`, at `now_ms`
// for an entity whose latest accepted time is `last`. `buf` holds at least `W.len` values.
pub fn entityMeasures(buf: []f64, window: []const Record, k_i: i64, now_ms: i64, last: i64) Measures {
    const w = Window{ .buf = buf, .records = window, .k = @intCast(k_i), .now_ms = now_ms, .last = last };
    var m = Measures.initFill(null);
    inline for (table, 0..) |e, i| {
        if (e.entity) |f| m.set(@enumFromInt(i), f(w));
    }
    return m;
}

// "Source measures": aggregates of its entities' measures, given in entity key order.
pub fn sourceMeasures(buf: []f64, entities: []const Measures) Measures {
    var m = Measures.initFill(null);
    inline for (table, 0..) |e, i| {
        const name: Measure = @enumFromInt(i);
        m.set(name, aggregate(e.source, buf, entities, name));
    }
    return m;
}

fn aggregate(how: Aggregate, buf: []f64, entities: []const Measures, name: Measure) ?Num {
    switch (how) {
        .sum => {
            var s: i64 = 0;
            for (entities) |e| s += e.get(name).?.int;
            return .{ .int = s };
        },
        .mean => {
            var n: usize = 0;
            for (entities) |e| {
                if (e.get(name)) |v| {
                    buf[n] = v.toF64();
                    n += 1;
                }
            }
            return if (n == 0) null else .{ .float = mean(buf[0..n]) };
        },
        .max => {
            var best: ?Num = null;
            for (entities) |e| {
                if (e.get(name)) |v| {
                    if (best == null or v.toF64() > best.?.toF64()) best = v;
                }
            }
            return best;
        },
        .min => {
            var least: ?Num = null;
            for (entities) |e| {
                if (e.get(name)) |v| {
                    if (least == null or v.toF64() < least.?.toF64()) least = v;
                }
            }
            return least;
        },
        .min_int => {
            var x: i64 = entities[0].get(name).?.int;
            for (entities[1..]) |e| x = @min(x, e.get(name).?.int);
            return .{ .int = x };
        },
        .count => return .{ .int = @intCast(entities.len) },
    }
}

test "the table gives the names, their order and the scopes" {
    try std.testing.expectEqualStrings("reports", @tagName(@as(Measure, @enumFromInt(0))));
    try std.testing.expect(std.meta.stringToEnum(Measure, "time_state_worst") != null);
    try std.testing.expect(entry(.entities).source_only);
    try std.testing.expect(!entry(.age).source_only);
}

test "entity and source measures of two small windows" {
    var buf: [8]f64 = undefined;
    const base = Record{ .wt = 0, .time_ms = 0, .order = .first, .interval = null, .latency = null, .lateness = null, .nis = null, .speed_err = null, .time_error = null, .time_state = null, .source_out_of_order = false, .ce = true, .vel = false, .hae = true };
    var r2 = base;
    r2.order = .advance;
    r2.interval = 1000;
    r2.nis = 2;
    var r3 = r2;
    r3.interval = 3000;
    r3.nis = 4;
    r3.order = .duplicate;
    const w = [_]Record{ base, r2, r3 };
    const m = entityMeasures(&buf, &w, 2, 5000, 4000);
    try std.testing.expectEqual(@as(i64, 3), m.get(.reports).?.int);
    try std.testing.expectEqual(@as(f64, 2000), m.get(.interval_mean).?.float);
    try std.testing.expectEqual(@as(i64, 3000), m.get(.interval_max).?.int);
    try std.testing.expectEqual(@as(i64, 1000), m.get(.age).?.int);
    try std.testing.expectEqual(@as(f64, 3), m.get(.nis_mean).?.float);
    try std.testing.expectEqual(@as(i64, 1), m.get(.duplicate).?.int);
    try std.testing.expectEqual(@as(f64, 1), m.get(.missing_vel).?.float);
    try std.testing.expect(m.get(.latency_mean) == null);
    try std.testing.expect(m.get(.entities) == null);
    const m1 = entityMeasures(&buf, w[0..1], 2, 5000, 0);
    const s = sourceMeasures(&buf, &.{ m, m1 });
    try std.testing.expectEqual(@as(i64, 4), s.get(.reports).?.int);
    try std.testing.expectEqual(@as(i64, 1000), s.get(.age).?.int);
    try std.testing.expectEqual(@as(i64, 2), s.get(.entities).?.int);
    try std.testing.expectEqual(@as(f64, 2000), s.get(.interval_mean).?.float);
}
