// spec/correlate-assign.md (version 0.5) "Sensor bias": one position offset per
// unordered pair of sources, learned from the committed membership at each tick.
const std = @import("std");
const Allocator = std.mem.Allocator;
const pack_mod = @import("pack.zig");
const kalman = @import("kalman.zig");

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

    // A pair with no stored state.
    pub fn initial(b: pack_mod.Bias) Pair {
        return .{ .east = 0, .weight_east = 0, .north = 0, .weight_north = 0, .variance = b.sigma_m * b.sigma_m, .pairs = 0 };
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
// axis. Two entities of one source are never moved.
pub fn moveInto(alloc: Allocator, st: *const State, b: pack_mod.Bias, a_src: []const u8, b_src: []const u8, b_pred: kalman.Filter) !kalman.Filter {
    if (std.mem.eql(u8, a_src, b_src)) return b_pred;
    const b_first = lessKey(b_src, a_src);
    const key = if (b_first) try pairKey(alloc, b_src, a_src) else try pairKey(alloc, a_src, b_src);
    const pair = st.get(b, key);
    var out = b_pred;
    if (b_first) {
        out.east.p = b_pred.east.p + pair.east;
        out.north.p = b_pred.north.p + pair.north;
    } else {
        out.east.p = b_pred.east.p - pair.east;
        out.north.p = b_pred.north.p - pair.north;
    }
    out.east.pp = b_pred.east.pp + pair.variance;
    out.north.pp = b_pred.north.pp + pair.variance;
    return out;
}

pub const Outcome = struct { d2: f64, accepted: bool, after: Pair };

// "Update", steps 1 to 3 for one pair: `es` and `et` are the predictions to
// `now_ms` (not moved) of the entities of the first and the second source.
pub fn update(alloc: Allocator, st: *State, b: pack_mod.Bias, key: []const u8, es: kalman.Filter, et: kalman.Filter) !Outcome {
    const before = st.get(b, key);

    // 1. Per axis the observed offset `y` and its variance `r`.
    const y_e = et.east.p - es.east.p;
    const y_n = et.north.p - es.north.p;
    const r_e = es.east.pp + et.east.pp;
    const r_n = es.north.pp + et.north.pp;

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
