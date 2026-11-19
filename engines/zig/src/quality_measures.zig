// spec/quality.md "Samples" (the record), "Window", "Entity measures" and
// "Source measures".
const std = @import("std");
const Measure = @import("quality_pack.zig").Measure;

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
    nis: ?f64,
    speed_err: ?f64,
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

    m.set(.nis_mean, floatMean(buf, window, k, "nis"));
    m.set(.speed_err_mean, floatMean(buf, window, k, "speed_err"));

    var out_of_order: i64 = 0;
    var duplicate: i64 = 0;
    for (window) |r| switch (r.order) {
        .out_of_order => out_of_order += 1,
        .duplicate => duplicate += 1,
        else => {},
    };
    m.set(.out_of_order, .{ .int = out_of_order });
    m.set(.duplicate, .{ .int = duplicate });

    m.set(.missing_ce, missing(window, k, "ce"));
    m.set(.missing_vel, missing(window, k, "vel"));
    m.set(.missing_hae, missing(window, k, "hae"));
    return m;
}

// "Source measures": aggregates of its entities' measures, given in entity key order.
pub fn sourceMeasures(buf: []f64, entities: []const Measures) Measures {
    var m = Measures.initFill(null);

    // Sums, always present.
    for ([_]Measure{ .reports, .out_of_order, .duplicate }) |name| {
        var s: i64 = 0;
        for (entities) |e| s += e.get(name).?.int;
        m.set(name, .{ .int = s });
    }

    // Means over the entities with a present value; null when none.
    for ([_]Measure{ .interval_last, .interval_mean, .latency_mean, .nis_mean, .speed_err_mean, .missing_ce, .missing_vel, .missing_hae }) |name| {
        var n: usize = 0;
        for (entities) |e| {
            if (e.get(name)) |v| {
                buf[n] = v.toF64();
                n += 1;
            }
        }
        m.set(name, if (n == 0) null else .{ .float = mean(buf[0..n]) });
    }

    // Largest present value; null when none.
    for ([_]Measure{ .interval_max, .latency_max }) |name| {
        var best: ?i64 = null;
        for (entities) |e| {
            if (e.get(name)) |v| {
                if (best == null or v.int > best.?) best = v.int;
            }
        }
        m.set(name, if (best) |b| .{ .int = b } else null);
    }

    // `age`: smallest, the freshest entity.
    var age: i64 = entities[0].get(.age).?.int;
    for (entities[1..]) |e| age = @min(age, e.get(.age).?.int);
    m.set(.age, .{ .int = age });

    m.set(.entities, .{ .int = @intCast(entities.len) });
    return m;
}
