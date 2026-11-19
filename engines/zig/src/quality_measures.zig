// spec/quality.md 0.2 "Samples" (the record), "Window", "Entity measures" and
// "Source measures".
const std = @import("std");
const qpack = @import("quality_pack.zig");
const Measure = qpack.Measure;
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

    pub fn toF64(n: Num) f64 {
        return switch (n) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
        };
    }
};

// Every measure of a scope; null is absent.
pub const Measures = std.EnumArray(Measure, ?Num);

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
fn missingTime(window: []const Record, k: usize) ?Num {
    if (window.len < k) return null;
    var count: usize = 0;
    for (window) |r| {
        if (r.time_state == null) count += 1;
    }
    return .{ .float = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(window.len)) };
}

// "Entity measures", over the window `W` with `min_samples` `k`, at `now_ms`
// for an entity whose latest accepted time is `last`. `buf` holds at least `W.len` values.
pub fn entityMeasures(buf: []f64, window: []const Record, k_i: i64, now_ms: i64, last: i64) Measures {
    const k: usize = @intCast(k_i);
    var m = Measures.initFill(null);
    m.set(.reports, .{ .int = @intCast(window.len) });

    const interval = intStat(buf, window, k, "interval");
    m.set(.interval_last, interval.last);
    m.set(.interval_mean, interval.mean);
    m.set(.interval_max, interval.max);

    m.set(.age, .{ .int = now_ms - last });

    const latency = intStat(buf, window, k, "latency");
    m.set(.latency_mean, latency.mean);
    m.set(.latency_max, latency.max);

    const lateness = latenessStat(buf, window, k);
    m.set(.lateness_mean, lateness.mean);
    m.set(.lateness_max, lateness.max);
    m.set(.lateness_min, lateness.min);

    m.set(.nis_mean, floatMean(buf, window, k, "nis"));
    m.set(.speed_err_mean, floatMean(buf, window, k, "speed_err"));

    var out_of_order: i64 = 0;
    var duplicate: i64 = 0;
    var source_out_of_order: i64 = 0;
    for (window) |r| {
        switch (r.order) {
            .out_of_order => out_of_order += 1,
            .duplicate => duplicate += 1,
            else => {},
        }
        if (r.source_out_of_order) source_out_of_order += 1;
    }
    m.set(.out_of_order, .{ .int = out_of_order });
    m.set(.duplicate, .{ .int = duplicate });
    m.set(.source_out_of_order, .{ .int = source_out_of_order });

    m.set(.missing_ce, missing(window, k, "ce"));
    m.set(.missing_vel, missing(window, k, "vel"));
    m.set(.missing_hae, missing(window, k, "hae"));

    const time_error = timeErrorStat(buf, window, k);
    m.set(.time_error_mean, time_error.mean);
    m.set(.time_error_max, time_error.max);
    const time_state = timeStateStat(window, k);
    m.set(.time_state_last, time_state.last);
    m.set(.time_state_worst, time_state.worst);
    m.set(.missing_time, missingTime(window, k));
    return m;
}

// "Source measures": aggregates of its entities' measures, given in entity key order.
pub fn sourceMeasures(buf: []f64, entities: []const Measures) Measures {
    var m = Measures.initFill(null);

    // Sums, always present.
    for ([_]Measure{ .reports, .out_of_order, .duplicate, .source_out_of_order }) |name| {
        var s: i64 = 0;
        for (entities) |e| s += e.get(name).?.int;
        m.set(name, .{ .int = s });
    }

    // Means over the entities with a present value; null when none.
    for ([_]Measure{ .interval_last, .interval_mean, .latency_mean, .lateness_mean, .nis_mean, .speed_err_mean, .missing_ce, .missing_vel, .missing_hae, .time_error_mean, .missing_time }) |name| {
        var n: usize = 0;
        for (entities) |e| {
            if (e.get(name)) |v| {
                buf[n] = v.toF64();
                n += 1;
            }
        }
        m.set(name, if (n == 0) null else .{ .float = mean(buf[0..n]) });
    }

    // Largest present value; null when none. Each value keeps its own type.
    for ([_]Measure{ .interval_max, .latency_max, .lateness_max, .time_error_max, .time_state_last, .time_state_worst }) |name| {
        var best: ?Num = null;
        for (entities) |e| {
            if (e.get(name)) |v| {
                if (best == null or v.toF64() > best.?.toF64()) best = v;
            }
        }
        m.set(name, best);
    }

    // `lateness_min`: smallest present value; null when none.
    var least: ?Num = null;
    for (entities) |e| {
        if (e.get(.lateness_min)) |v| {
            if (least == null or v.toF64() < least.?.toF64()) least = v;
        }
    }
    m.set(.lateness_min, least);

    // `age`: smallest, the freshest entity.
    var age: i64 = entities[0].get(.age).?.int;
    for (entities[1..]) |e| age = @min(age, e.get(.age).?.int);
    m.set(.age, .{ .int = age });

    m.set(.entities, .{ .int = @intCast(entities.len) });
    return m;
}
