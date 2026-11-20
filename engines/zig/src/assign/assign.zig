// spec/correlate-assign.md (version 0.6): system tracks, per-source ranked
// assignments at each tick, a window of `n` ticks over the best `k` histories
// (kept within `margin` of the best), the inverse-variance fused estimate, the
// leave of a restarted entity (correlate.md 0.7 "Restart") and the update of
// the sensor bias offsets with their clock offsets (`bias.zig`), and the
// timing variance of correlate.md 0.8 in the Cost.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const engine_mod = @import("../correlate/engine.zig");
const frame = @import("../model/frame.zig");
const kalman = @import("../model/kalman.zig");
const bias_mod = @import("bias.zig");
const pack_mod = @import("../correlate/pack.zig");
const membership = @import("membership.zig");
const ranking = @import("ranking.zig");
const Membership = membership.Membership;
const System = membership.System;
const leave = membership.leave;
const join = membership.join;
const start = membership.start;
const Column = ranking.Column;
const Entries = ranking.Entries;
const Assignment = ranking.Assignment;
const ranked = ranking.ranked;
const Engine = engine_mod.Engine;
const Entity = @import("../correlate/entity.zig").Entity;
const Result = engine_mod.Result;
const lessKey = engine_mod.lessKey;

// `[entity, chosen]`; `chosen` null is `alone`.
pub const Choice = struct { entity: []const u8, chosen: ?u64 };

// One pending tick of a history.
pub const Record = struct {
    cost: f64,
    choices: std.ArrayList(Choice),
    events: std.ArrayList(json.Value),
    membership: Membership,

    fn clone(self: Record, alloc: Allocator) !Record {
        var choices = std.ArrayList(Choice).init(alloc);
        try choices.appendSlice(self.choices.items);
        var events = std.ArrayList(json.Value).init(alloc);
        try events.appendSlice(self.events.items);
        return .{ .cost = self.cost, .choices = choices, .events = events, .membership = try self.membership.clone(alloc) };
    }
};

pub const History = struct {
    records: std.ArrayList(Record),

    // The sum, left to right from 0, of the records' `cost`, oldest first.
    pub fn total(self: History) f64 {
        var t: f64 = 0;
        for (self.records.items) |r| t += r.cost;
        return t;
    }

    fn newest(self: History) *Record {
        return &self.records.items[self.records.items.len - 1];
    }
};

fn choicesEqual(x: []const Choice, y: []const Choice) bool {
    if (x.len != y.len) return false;
    for (x, y) |a, b| {
        if (!std.mem.eql(u8, a.entity, b.entity)) return false;
        if (a.chosen != b.chosen) return false;
    }
    return true;
}

// The method's state beyond the entities: the committed membership, the
// histories in rank order, and the retiring entities.
pub const State = struct {
    committed: Membership,
    histories: std.ArrayList(History),
    retiring: std.StringArrayHashMap(void),
    // "Sensor bias": the stored offsets, used only with `bias`.
    bias: bias_mod.State,
    // The entities with an accepted report since the previous tick.
    reported: std.StringArrayHashMap(void),
    // correlate.md 0.7 "Restart": the entities whose filter started again
    // since the previous tick.
    restarted: std.StringArrayHashMap(void),

    pub fn init(alloc: Allocator) !State {
        // At the start there is one history with no records.
        var histories = std.ArrayList(History).init(alloc);
        try histories.append(.{ .records = std.ArrayList(Record).init(alloc) });
        return .{
            .committed = Membership.init(alloc),
            .histories = histories,
            .retiring = std.StringArrayHashMap(void).init(alloc),
            .bias = bias_mod.State.init(alloc),
            .reported = std.StringArrayHashMap(void).init(alloc),
            .restarted = std.StringArrayHashMap(void).init(alloc),
        };
    }

    // A history's latest membership: its newest record's, or the committed one.
    fn latest(self: *State, h: History) Membership {
        return if (h.records.items.len == 0) self.committed else h.newest().membership;
    }
};

pub fn state(eng: *Engine) *State {
    return @ptrCast(@alignCast(eng.method_state));
}

pub fn initState(a: Allocator) anyerror!*anyopaque {
    const st = try a.create(State);
    st.* = try State.init(a);
    return st;
}

// correlate-assign.md "Window": a report of a retiring entity is rejected.
pub fn rejectRetiring(eng: *Engine, key: []const u8) ?[]const u8 {
    return if (state(eng).retiring.contains(key)) "retiring" else null;
}

// correlate.md 0.7 "Restart", method assign: the entity leaves at the next tick.
pub fn markRestarted(eng: *Engine, key: []const u8) anyerror!void {
    try state(eng).restarted.put(key, {});
}

// A report gives only `new` or `reject`; the tick decides.
pub fn markReported(eng: *Engine, _: *Result, key: []const u8) anyerror!void {
    try state(eng).reported.put(key, {});
}

// correlate-assign.md 0.5 "Sensor bias": with `bias`, B is moved into A's
// frame before the test formula.
pub fn moveIntoFrame(eng: *Engine, a: Entity, b: Entity, b_pred: kalman.Filter) anyerror!kalman.Filter {
    const bp = eng.pack.bias orelse return b_pred;
    return bias_mod.moveInto(eng.alloc(), &state(eng).bias, bp, eng.pack.time_offset, a.source, b.source, b_pred);
}

// correlate-assign.md "Pack": the ranges, after the required and refused directives.
pub fn checkPack(pack: pack_mod.Pack) pack_mod.Error!void {
    // correlate-assign.md 0.2 "Pack": ranges of `new_cost` and `keep_bonus`.
    if (!(pack.new_cost > 0 and pack.keep_bonus >= 0)) return error.BadValue;
    // correlate-assign.md 0.4 "Pack": `window` and `hypotheses` 1 or above;
    // `hypotheses` above 1 needs `window` above 1.
    if (pack.window < 1 or pack.hypotheses < 1) return error.BadValue;
    if (pack.hypotheses > 1 and pack.window == 1) return error.BadValue;
    // correlate-assign.md 0.5 "Pack": `bias` with `sigma_m` and `gate` above 0
    // and `floor_m` above 0 and at most `sigma_m`.
    if (pack.bias) |b| {
        if (!(b.sigma_m > 0 and b.gate > 0 and b.floor_m > 0 and b.floor_m <= b.sigma_m)) return error.BadValue;
    }
    // correlate-assign.md 0.6 "Pack": `time_offset`'s `sigma_ms` above 0, and
    // only with `bias`.
    if (pack.time_offset) |t| {
        if (!(t.sigma_ms > 0) or pack.bias == null) return error.BadValue;
    }
    // `margin` above 0, and only with `hypotheses` above 1.
    if (pack.margin) |m| {
        if (!(m > 0) or pack.hypotheses <= 1) return error.BadValue;
    }
}

// ---- Assignment of one source -------------------------------------------------

// "Fused estimate", one axis: inverse-variance weights of the members' predictions.
pub const FusedAxis = struct { p: f64, v: f64, pp: f64, vv: f64 };
pub const Fused = struct { east: FusedAxis, north: FusedAxis };

pub fn fuseAxis(axes: []const kalman.Axis) FusedAxis {
    var ipp: f64 = 0;
    var ivv: f64 = 0;
    var sp: f64 = 0;
    var sv: f64 = 0;
    for (axes) |a| {
        ipp += 1.0 / a.pp;
        sp += a.p / a.pp;
        ivv += 1.0 / a.vv;
        sv += a.v / a.vv;
    }
    const pp = 1.0 / ipp;
    const vv = 1.0 / ivv;
    return .{ .p = pp * sp, .v = vv * sv, .pp = pp, .vv = vv };
}

// Members in key order, each predicted to `t_ms`. With `frame_of` (an entity's
// source) the estimate is for a comparison ("Cost"): each member's predicted
// `pp` gets its timing variance (correlate.md 0.8), then, with the pack's
// `bias`, the member is moved into that source's frame ("Sensor bias"). An
// estimate for output (`frame_of` null) does neither.
fn fused(eng: *Engine, members: []const []const u8, t_ms: i64, frame_of: ?[]const u8) !Fused {
    const a = eng.alloc();
    const east = try a.alloc(kalman.Axis, members.len);
    const north = try a.alloc(kalman.Axis, members.len);
    for (members, 0..) |m, i| {
        const e = eng.entities.get(m).?;
        var f = if (frame_of != null) e.predictedForComparison(t_ms, eng.pack) else e.predictedTo(t_ms, eng.pack);
        if (eng.pack.bias) |bp| {
            if (frame_of) |src| f = try bias_mod.moveInto(a, &state(eng).bias, bp, eng.pack.time_offset, src, e.source, f);
        }
        east[i] = f.east;
        north[i] = f.north;
    }
    return .{ .east = fuseAxis(east), .north = fuseAxis(north) };
}

// "Cost": d² of A against the fused estimate of M, both at A's `last_time_ms`;
// `pp_a` is A's filter `pp` plus A's timing variance (0.6).
fn cost(eng: *Engine, a_key: []const u8, members: []const []const u8) !f64 {
    const a = eng.entities.get(a_key).?;
    return costOf(a.filter, a.time_var_east, a.time_var_north, try fused(eng, members, a.last_time_ms, a.source));
}

// The Cost formula, pure: A's filter with its timing variance against the fused estimate.
pub fn costOf(a: kalman.Filter, time_var_east: f64, time_var_north: f64, m: Fused) f64 {
    const pp_a_east = a.east.pp + time_var_east;
    const pp_a_north = a.north.pp + time_var_north;
    const de = a.east.p - m.east.p;
    const dn = a.north.p - m.north.p;
    return de * de / (pp_a_east + m.east.pp) + dn * dn / (pp_a_north + m.north.pp);
}

fn contains(list: []const []const u8, key: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, key)) return true;
    return false;
}

fn entries(eng: *Engine, res: *Result, m: Membership, source: []const u8, rows: []const []const u8) !Entries {
    const a = eng.alloc();

    // 1. Columns: R left out, not empty, no entity of S; creation order.
    var cols = std.ArrayList(Column).init(a);
    for (m.systems.items) |s| {
        var others = std.ArrayList([]const u8).init(a);
        var has_s = false;
        for (s.members.items) |x| {
            if (contains(rows, x)) continue;
            if (std.mem.eql(u8, eng.entities.get(x).?.source, source)) has_s = true;
            try others.append(x);
        }
        if (others.items.len == 0 or has_s) continue;
        try cols.append(.{ .id = s.id, .others = others.items });
    }

    // 2. Entries, with the gate records in the order the tests run.
    const width = cols.items.len + 1;
    const values = try a.alloc(?f64, rows.len * width);
    for (rows, 0..) |r, i| {
        const own = m.systemOf(r);
        for (cols.items, 0..) |c, j| {
            values[i * width + j] = null;
            var ok = true;
            for (c.others) |o| {
                if (!try eng.runTests(res, .gate, eng.pack.gate, r, o)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;
            var d2 = try cost(eng, r, c.others);
            if (own != null and own.? == c.id) d2 -= eng.pack.keep_bonus;
            values[i * width + j] = d2;
        }
        var alone = eng.pack.new_cost;
        if (own) |id| {
            if (m.members(id).len == 1) alone -= eng.pack.keep_bonus;
        }
        values[i * width + cols.items.len] = alone;
    }
    const e = Entries{ .cols = cols.items, .rows = rows, .values = values };

    // The cost records, entities in key order, columns in creation order then `alone`.
    for (rows, 0..) |r, i| {
        for (cols.items, 0..) |c, j| try assignRecord(eng, res, r, try eng.groupName(c.id), "cost", e.at(i, j));
        try assignRecord(eng, res, r, "alone", "cost", e.at(i, cols.items.len));
    }
    return e;
}

fn assignRecord(eng: *Engine, res: *Result, a: []const u8, b: []const u8, test_name: []const u8, value: ?f64) !void {
    try res.trace.append(try eng.object(.{
        .{ "stage", "assign" },
        .{ "a", a },
        .{ "b", b },
        .{ "test", test_name },
        .{ "value", value },
        .{ "limit", json.Value{ .null = {} } },
        .{ "pass", value != null },
    }));
}

// Step 4, apply: entities of R in key order. Adds the choices, events and cost to `rec`.
fn apply(eng: *Engine, rec: *Record, e: Entries, asg: Assignment) !void {
    const m = &rec.membership;
    for (e.rows, asg.choice) |r, j| {
        const chosen = e.chosenId(j);
        try rec.choices.append(.{ .entity = r, .chosen = chosen });
        const own = m.systemOf(r);
        if (chosen) |target| {
            if (own != null and own.? == target) continue;
            if (own != null) try leave(eng, m, &rec.events, r, "assign");
            try join(eng, m, &rec.events, target, r);
        } else {
            if (own) |id| {
                if (m.members(id).len == 1) continue;
                try leave(eng, m, &rec.events, r, "assign");
            }
            try start(eng, m, &rec.events, r);
        }
    }
    rec.cost += asg.total;
}

// ---- Window -------------------------------------------------------------------

// With `window` above 1, the trace records from `from` on get `"h"` and, when given, `"r"`.
fn tag(res: *Result, from: usize, h: usize, r: ?usize) !void {
    for (res.trace.items[from..]) |*rec| {
        try rec.object.put("h", .{ .integer = @intCast(h) });
        if (r) |x| try rec.object.put("r", .{ .integer = @intCast(x) });
    }
}

const Candidate = struct { history: History, total: f64, h: usize, r: usize };

fn candidateBefore(_: void, x: Candidate, y: Candidate) bool {
    if (x.total != y.total) return x.total < y.total;
    if (x.h != y.h) return x.h < y.h;
    return x.r < y.r;
}

// Step 3, one source S with its rows R (key order), over every history.
fn assignSource(eng: *Engine, res: *Result, source: []const u8, rows: []const []const u8) !void {
    const a = eng.alloc();
    const st = state(eng);
    const windowed = eng.pack.window > 1;
    const k: usize = @intCast(eng.pack.hypotheses);

    var candidates = std.ArrayList(Candidate).init(a);
    for (st.histories.items, 0..) |hist, h| {
        const rec = hist.newest().*;
        const from = res.trace.items.len;
        const e = try entries(eng, res, rec.membership, source, rows);
        if (windowed) try tag(res, from, h, null);

        for (try ranked(a, e, k), 0..) |asg, r| {
            const choice_from = res.trace.items.len;
            for (rows, asg.choice, 0..) |row, j, i| {
                const b = if (e.chosenId(j)) |id| try eng.groupName(id) else "alone";
                try assignRecord(eng, res, row, b, "choice", e.at(i, j));
            }
            if (windowed) try tag(res, choice_from, h, r);

            // The candidate: `h` with its newest record replaced by a copy with `r` applied.
            var records = std.ArrayList(Record).init(a);
            try records.appendSlice(hist.records.items[0 .. hist.records.items.len - 1]);
            var copy = try rec.clone(a);
            try apply(eng, &copy, e, asg);
            try records.append(copy);
            const cand = History{ .records = records };
            try candidates.append(.{ .history = cand, .total = cand.total(), .h = h, .r = r });
        }
    }

    // Candidates by total, then h, then r; the first k are the histories. With
    // `margin`, of those only the ones with total at most `cut = best + margin`.
    std.mem.sort(Candidate, candidates.items, {}, candidateBefore);
    const cut: ?f64 = if (eng.pack.margin) |m| candidates.items[0].total + m else null;
    st.histories.clearRetainingCapacity();
    for (candidates.items, 0..) |c, i| {
        var kept = i < k;
        if (cut) |limit| kept = kept and c.total <= limit;
        if (kept) try st.histories.append(c.history);
        if (windowed) try historyRecord(eng, res, .{ .integer = @intCast(c.h) }, .{ .integer = @intCast(c.r) }, "total", c.total, if (cut) |x| json.Value{ .float = x } else .null, kept);
    }
}

fn historyRecord(eng: *Engine, res: *Result, a: json.Value, b: json.Value, test_name: []const u8, value: f64, limit: json.Value, pass: bool) !void {
    try res.trace.append(try eng.object(.{
        .{ "stage", "history" },
        .{ "a", a },
        .{ "b", b },
        .{ "test", test_name },
        .{ "value", value },
        .{ "limit", limit },
        .{ "pass", pass },
    }));
}

fn isStale(eng: *Engine, key: []const u8, now_ms: i64) bool {
    const e = eng.entities.get(key).?;
    const own_stale = if (e.integer("stale_ms")) |s| now_ms >= s else false;
    return now_ms - e.last_time_ms > eng.pack.stale_ms or own_stale;
}

// "Window", on each tick.
pub fn tick(eng: *Engine, now_ms: i64) !Result {
    const a = eng.alloc();
    const st = state(eng);
    const windowed = eng.pack.window > 1;
    var res = Result.init(a);

    // 1. Staleness, among entities not retiring, in key order.
    const restarted = try a.dupe([]const u8, st.restarted.keys());
    std.mem.sort([]const u8, restarted, {}, lessKey);
    var stale = std.ArrayList([]const u8).init(a);
    for (try eng.sortedKeys()) |key| {
        if (!st.retiring.contains(key) and isStale(eng, key, now_ms)) try stale.append(key);
    }
    for (st.histories.items) |*hist| {
        var rec = Record{
            .cost = 0,
            .choices = std.ArrayList(Choice).init(a),
            .events = std.ArrayList(json.Value).init(a),
            .membership = try st.latest(hist.*).clone(a),
        };
        for (stale.items) |key| {
            if (rec.membership.systemOf(key) != null) try leave(eng, &rec.membership, &rec.events, key, "stale");
            try rec.events.append(try eng.object(.{ .{ "ev", "drop" }, .{ "entity", key } }));
        }
        // Each restarted entity that is not stale leaves its system track.
        for (restarted) |key| {
            if (contains(stale.items, key)) continue;
            if (rec.membership.systemOf(key) != null) try leave(eng, &rec.membership, &rec.events, key, "restart");
        }
        try hist.records.append(rec);
    }
    // No entity is restarted after this step.
    st.restarted.clearRetainingCapacity();
    for (stale.items) |key| {
        try st.retiring.put(key, {});
        _ = st.reported.orderedRemove(key);
    }

    // 2. Rows: the entities reported since the previous tick, grouped by source.
    const reported = try a.dupe([]const u8, st.reported.keys());
    std.mem.sort([]const u8, reported, {}, lessKey);
    st.reported.clearRetainingCapacity();
    var sources = std.ArrayList([]const u8).init(a);
    for (reported) |key| {
        const src = eng.entities.get(key).?.source;
        if (!contains(sources.items, src)) try sources.append(src);
    }
    std.mem.sort([]const u8, sources.items, {}, lessKey);

    // 3. Sources, in key order.
    for (sources.items) |src| {
        var rows = std.ArrayList([]const u8).init(a);
        for (reported) |key| if (std.mem.eql(u8, eng.entities.get(key).?.source, src)) try rows.append(key);
        try assignSource(eng, &res, src, rows.items);
    }

    // 4. Commit, when the best history has `window` records.
    const best = st.histories.items[0];
    if (best.records.items.len == @as(usize, @intCast(eng.pack.window))) {
        const done = best.records.items[0];
        var kept = std.ArrayList(History).init(a);
        for (st.histories.items, 0..) |hist, rank| {
            const keep = choicesEqual(hist.records.items[0].choices.items, done.choices.items);
            if (windowed) try historyRecord(eng, &res, .{ .integer = @intCast(rank) }, .null, "commit", hist.total(), .null, keep);
            if (!keep) continue;
            var records = std.ArrayList(Record).init(a);
            try records.appendSlice(hist.records.items[1..]);
            try kept.append(.{ .records = records });
        }
        try res.events.appendSlice(done.events.items);
        st.committed = done.membership;
        for (done.events.items) |ev| {
            if (!std.mem.eql(u8, ev.object.get("ev").?.string, "drop")) continue;
            const key = ev.object.get("entity").?.string;
            _ = eng.entities.orderedRemove(key);
            _ = st.retiring.orderedRemove(key);
        }
        st.histories = kept;
    }

    // 5. Bias: the update of Sensor bias, from the committed membership.
    if (eng.pack.bias) |bp| try updateBias(eng, &res, bp, reported, now_ms);

    // 6. Output: one `system` per committed system track, retiring members
    // included; with `margin`, per system track of the best history's latest membership.
    const reported_systems = if (eng.pack.margin != null) st.latest(st.histories.items[0]) else st.committed;
    for (reported_systems.systems.items) |s| try res.events.append(try systemEvent(eng, s, now_ms));
    // Then, with a window, one `provisional` per system track of the best history.
    if (windowed) {
        for (st.latest(st.histories.items[0]).systems.items) |s| {
            try res.events.append(try eng.object(.{
                .{ "ev", "provisional" },
                .{ "system", try eng.groupName(s.id) },
                .{ "members", try eng.stringList(s.members.items) },
            }));
        }
    }
    return res;
}

// "Sensor bias", Update: committed system tracks in creation order, their members
// not retiring in key order, each pair X before Y of two sources with at least
// one of them among the tick's rows.
fn updateBias(eng: *Engine, res: *Result, bp: pack_mod.Bias, rows: []const []const u8, now_ms: i64) !void {
    const a = eng.alloc();
    const st = state(eng);
    for (st.committed.systems.items) |s| {
        var members = std.ArrayList([]const u8).init(a);
        for (s.members.items) |m| if (!st.retiring.contains(m)) try members.append(m);
        for (members.items, 0..) |x, i| {
            for (members.items[i + 1 ..]) |y| {
                const ex = eng.entities.get(x).?;
                const ey = eng.entities.get(y).?;
                if (std.mem.eql(u8, ex.source, ey.source)) continue;
                if (!contains(rows, x) and !contains(rows, y)) continue;
                // 1. ES is the entity whose source is first in key order, ET the other.
                const es, const et = if (lessKey({}, ex.source, ey.source)) .{ ex, ey } else .{ ey, ex };
                const key = try bias_mod.pairKey(a, es.source, et.source);
                // 2 and 3.
                const o = bias_mod.update(st.bias.get(bp, key), bp, eng.pack.time_offset, es.predictedTo(now_ms, eng.pack), et.predictedTo(now_ms, eng.pack));
                if (o.accepted) try st.bias.store(a, key, o.after);
                // 4. Trace, with the state after step 3.
                var rec = try eng.object(.{
                    .{ "stage", "bias" },
                    .{ "a", x },
                    .{ "b", y },
                    .{ "test", "offset" },
                    .{ "value", o.d2 },
                    .{ "limit", bp.gate },
                    .{ "pass", o.accepted },
                    .{ "east", o.after.east },
                    .{ "north", o.after.north },
                    .{ "var", o.after.variance },
                    .{ "pairs", o.after.pairs },
                });
                // "Time offset": the record adds `time_offset_ms`, tau*1000.
                if (eng.pack.time_offset != null) try rec.object.put("time_offset_ms", .{ .float = o.after.tau * 1000.0 });
                try res.trace.append(rec);
            }
        }
    }
}

fn systemEvent(eng: *Engine, s: System, now_ms: i64) !json.Value {
    const f = try fused(eng, s.members.items, now_ms, null);
    const pos = eng.ref.?.toDegrees(.{ .east = f.east.p, .north = f.north.p });
    var course = frame.deg(std.math.atan2(f.east.v, f.north.v));
    if (course < 0) course += 360.0;
    if (course >= 360.0) course -= 360.0;
    var ev = try eng.object(.{
        .{ "ev", "system" },
        .{ "system", try eng.groupName(s.id) },
        .{ "members", try eng.stringList(s.members.items) },
        .{ "lat", pos.lat },
        .{ "lon", pos.lon },
        .{ "course", course },
        .{ "speed_ms", std.math.hypot(f.east.v, f.north.v) },
    });
    // `hae` from the member with the greatest `last_time_ms` that has one; ties to key order.
    var top: ?struct { t: i64, hae: f64 } = null;
    for (s.members.items) |mk| {
        const e = eng.entities.get(mk).?;
        const hae = e.number("hae") orelse continue;
        if (top == null or e.last_time_ms > top.?.t) top = .{ .t = e.last_time_ms, .hae = hae };
    }
    if (top) |b| try ev.object.put("hae", .{ .float = b.hae });
    return ev;
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "the fused estimate weights by inverse variance; the cost is d2" {
        const x = kalman.Axis{ .p = 0, .v = 0, .pp = 1, .pv = 0, .vv = 1 };
        var y = x;
        y.p = 10;
        y.pp = 3;
        const f = fuseAxis(&.{ x, y });
        try std.testing.expectEqual(@as(f64, 0.75), f.pp);
        try std.testing.expectEqual(@as(f64, 2.5), f.p);
        const m = Fused{ .east = f, .north = fuseAxis(&.{ x, x }) };
        const c = costOf(.{ .east = x, .north = x }, 0.25, 0, m);
        try std.testing.expectEqual(@as(f64, 2.5 * 2.5 / 2.0), c);
    }
};
