// spec/correlate-assign.md (version 0.6) "Sensor bias": one position offset per
// unordered pair of sources, learned from the committed membership at each tick;
// with `time_offset` ("Time offset"), a clock offset `tau` fitted with it.
const std = @import("std");
const Allocator = std.mem.Allocator;
const pack_mod = @import("../correlate/pack.zig");
const kalman = @import("../model/kalman.zig");

fn lessKey(a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// "State", per axis the offset `o` and the weight sum `w`; one `var` for both
// axes; `n` the count of accepted pairs. For pair key "<S>|<T>" (S before T),
// the offset is how far T's positions sit east and north of S's.
pub const Pair = struct {
    east: f64,
    weight_east: f64,
    north: f64,
    weight_north: f64,
    variance: f64,
    pairs: i64,
    // "Time offset": `tau`, in seconds, how far T's clock is ahead of S's, and
    // the sums `S1` to `S8` (`sums[0]` to `sums[7]`); all 0 with no state stored.
    tau: f64,
    sums: [8]f64,

    // A pair with no stored state.
    pub fn initial(b: pack_mod.Bias) Pair {
        return .{
            .east = 0,
            .weight_east = 0,
            .north = 0,
            .weight_north = 0,
            .variance = b.sigma_m * b.sigma_m,
            .pairs = 0,
            .tau = 0,
            .sums = [_]f64{0} ** 8,
        };
    }
};

// The stored pairs, by pair key.
pub const State = struct {
    pairs: std.StringArrayHashMap(Pair),

    pub fn init(alloc: Allocator) State {
        return .{ .pairs = std.StringArrayHashMap(Pair).init(alloc) };
    }

    // The pair's state, or the state of a pair with none stored.
    pub fn get(self: *const State, b: pack_mod.Bias, key: []const u8) Pair {
        return self.pairs.get(key) orelse Pair.initial(b);
    }
};

pub fn pairKey(alloc: Allocator, first: []const u8, second: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}|{s}", .{ first, second });
}

// "Moving B into A's frame": B's prediction `b_pred` gets `p + o` (B's source
// first in key order) or `p - o` (A's source first), and `pp + var`, on each
// axis. With `time_offset`, `o - v*tau` takes the place of `o`, `v` B's
// predicted velocity on that axis. Two entities of one source are never moved.
pub fn moveInto(alloc: Allocator, st: *const State, b: pack_mod.Bias, time_offset: ?pack_mod.TimeOffset, a_src: []const u8, b_src: []const u8, b_pred: kalman.Filter) !kalman.Filter {
    if (std.mem.eql(u8, a_src, b_src)) return b_pred;
    const b_first = lessKey(b_src, a_src);
    const key = if (b_first) try pairKey(alloc, b_src, a_src) else try pairKey(alloc, a_src, b_src);
    const pair = st.get(b, key);
    var o_east = pair.east;
    var o_north = pair.north;
    if (time_offset != null) {
        o_east = pair.east - b_pred.east.v * pair.tau;
        o_north = pair.north - b_pred.north.v * pair.tau;
    }
    var out = b_pred;
    if (b_first) {
        out.east.p = b_pred.east.p + o_east;
        out.north.p = b_pred.north.p + o_north;
    } else {
        out.east.p = b_pred.east.p - o_east;
        out.north.p = b_pred.north.p - o_north;
    }
    out.east.pp = b_pred.east.pp + pair.variance;
    out.north.pp = b_pred.north.pp + pair.variance;
    return out;
}

pub const Outcome = struct { d2: f64, accepted: bool, after: Pair };

// "Update", steps 1 to 3 for one pair: `es` and `et` are the predictions to
// `now_ms` (not moved) of the entities of the first and the second source.
pub fn update(alloc: Allocator, st: *State, b: pack_mod.Bias, time_offset: ?pack_mod.TimeOffset, key: []const u8, es: kalman.Filter, et: kalman.Filter) !Outcome {
    const before = st.get(b, key);

    // 1. Per axis the observed offset `y` and its variance `r`.
    const y_e = et.east.p - es.east.p;
    const y_n = et.north.p - es.north.p;
    const r_e = es.east.pp + et.east.pp;
    const r_n = es.north.pp + et.north.pp;

    if (time_offset) |t| return updateWithTime(alloc, st, b, t, key, before, es, et, y_e, y_n, r_e, r_n);

    // 2. d² of the observed offset against the pair's state.
    const de = y_e - before.east;
    const dn = y_n - before.north;
    const d2 = de * de / (before.variance + r_e) + dn * dn / (before.variance + r_n);

    // 3. Accepted when d² < gate: count, variance (no less than floor²), weighted mean.
    if (!(d2 < b.gate)) return .{ .d2 = d2, .accepted = false, .after = before };
    var after = before;
    after.pairs = before.pairs + 1;
    after.variance = b.sigma_m * b.sigma_m / @as(f64, @floatFromInt(after.pairs + 1));
    if (after.variance < b.floor_m * b.floor_m) after.variance = b.floor_m * b.floor_m;
    after.weight_east = before.weight_east + 1.0 / r_e;
    after.east = before.east + ((1.0 / r_e) / after.weight_east) * (y_e - before.east);
    after.weight_north = before.weight_north + 1.0 / r_n;
    after.north = before.north + ((1.0 / r_n) / after.weight_north) * (y_n - before.north);
    const gop = try st.pairs.getOrPut(key);
    if (!gop.found_existing) gop.key_ptr.* = try alloc.dupe(u8, key);
    gop.value_ptr.* = after;
    return .{ .d2 = d2, .accepted = true, .after = after };
}

// "Time offset": steps 2 and 3 of the update with the fit of `y = o - v*tau`.
// `y_e`, `y_n`, `r_e`, `r_n` are step 1's.
fn updateWithTime(
    alloc: Allocator,
    st: *State,
    b: pack_mod.Bias,
    t: pack_mod.TimeOffset,
    key: []const u8,
    before: Pair,
    es: kalman.Filter,
    et: kalman.Filter,
    y_e: f64,
    y_n: f64,
    r_e: f64,
    r_n: f64,
) !Outcome {
    // Per axis the object's velocity, the mean of the two predictions.
    const v_e = (es.east.v + et.east.v) / 2.0;
    const v_n = (es.north.v + et.north.v) / 2.0;

    // 2. d² with `(y - (o - v*tau))²` in place of `(y - o)²`.
    const de = y_e - (before.east - v_e * before.tau);
    const dn = y_n - (before.north - v_n * before.tau);
    const d2 = de * de / (before.variance + r_e) + dn * dn / (before.variance + r_n);
    if (!(d2 < b.gate)) return .{ .d2 = d2, .accepted = false, .after = before };

    // 3. Accepted: `n` and `var` as without `time_offset`.
    var after = before;
    after.pairs = before.pairs + 1;
    after.variance = b.sigma_m * b.sigma_m / @as(f64, @floatFromInt(after.pairs + 1));
    if (after.variance < b.floor_m * b.floor_m) after.variance = b.floor_m * b.floor_m;

    // The sums, each `+=` one addition of the whole right-hand side.
    const we = 1.0 / r_e;
    const wn = 1.0 / r_n;
    var sm = before.sums;
    sm[0] += we; // S1
    sm[1] += wn; // S2
    sm[2] += we * v_e; // S3
    sm[3] += wn * v_n; // S4
    sm[4] += we * v_e * v_e + wn * v_n * v_n; // S5
    sm[5] += we * y_e; // S6
    sm[6] += wn * y_n; // S7
    sm[7] += we * v_e * y_e + wn * v_n * y_n; // S8
    after.sums = sm;

    // The closed-form weighted least-squares fit, with priors po = 1/s² on `o`
    // and pt = 1/(t/1000)² on `tau`.
    const po = 1.0 / (b.sigma_m * b.sigma_m);
    const t_s = t.sigma_ms / 1000.0;
    const pt = 1.0 / (t_s * t_s);
    const a11 = po + sm[0];
    const a22 = po + sm[1];
    const a13 = -sm[2];
    const a23 = -sm[3];
    const a33 = pt + sm[4];
    const b1 = sm[5];
    const b2 = sm[6];
    const b3 = -sm[7];
    const tau = (b3 - a13 * b1 / a11 - a23 * b2 / a22) / (a33 - a13 * a13 / a11 - a23 * a23 / a22);
    after.tau = tau;
    after.east = (b1 - a13 * tau) / a11;
    after.north = (b2 - a23 * tau) / a22;
    // The weight sum `w` of each axis is `S1` and `S2`.
    after.weight_east = sm[0];
    after.weight_north = sm[1];

    const gop = try st.pairs.getOrPut(key);
    if (!gop.found_existing) gop.key_ptr.* = try alloc.dupe(u8, key);
    gop.value_ptr.* = after;
    return .{ .d2 = d2, .accepted = true, .after = after };
}
