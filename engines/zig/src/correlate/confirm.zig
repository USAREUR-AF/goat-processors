// correlate.md 1.0, method `confirm`: the gate, confirm and hold stages
// ("Association"), the pair counts and `confirm_count`, the hold failures, or
// with `sprt` the sequential test on each pair ("Sequential test"); staleness
// (the engine's stale time of a source) and the `fused`, `priority` or
// `latest` output ("On each tick").
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const engine_mod = @import("engine.zig");
const frame = @import("../model/frame.zig");
const kalman = @import("../model/kalman.zig");
const pair_tests = @import("tests.zig");
const sprt_mod = @import("sprt.zig");
const pack_mod = @import("pack.zig");
const Entity = @import("entity.zig").Entity;
const Engine = engine_mod.Engine;
const Result = engine_mod.Result;
const lessKey = engine_mod.lessKey;

pub const Group = struct {
    id: u64,
    members: std.ArrayList([]const u8),
};

const PairCount = struct { a: []const u8, b: []const u8, count: i64 };

// correlate.md 1.0 "Sequential test": a pair's log-likelihood ratio `L`.
pub const PairLlr = struct { a: []const u8, b: []const u8, l: f64 };

// The method's state beyond the entities: the groups in creation order, the
// pair counts (or with `sprt` the pairs' `L`), and the counter that names the
// next group.
pub const State = struct {
    groups: std.ArrayList(Group),
    counts: std.ArrayList(PairCount),
    llr: std.ArrayList(PairLlr),
    next_group: u64 = 1,

    pub fn init(a: Allocator) State {
        return .{
            .groups = std.ArrayList(Group).init(a),
            .counts = std.ArrayList(PairCount).init(a),
            .llr = std.ArrayList(PairLlr).init(a),
        };
    }
};

pub fn initState(a: Allocator) anyerror!*anyopaque {
    const st = try a.create(State);
    st.* = State.init(a);
    return st;
}

pub fn state(eng: *Engine) *State {
    return @ptrCast(@alignCast(eng.method_state));
}

// After an accepted report: hold when A is in a group, otherwise associate;
// with `sprt`, the sequential test of the link pair or of the candidates.
pub fn afterIngest(eng: *Engine, res: *Result, a_key: []const u8) !void {
    const grouped = eng.entities.get(a_key).?.group;
    if (eng.pack.sprt) |s| {
        if (grouped) |gid| try sprtLink(eng, res, s, a_key, gid) else try sprtAssociate(eng, res, s, a_key);
        return;
    }
    if (grouped) |gid| {
        try hold(eng, res, a_key, gid);
    } else {
        try associate(eng, res, a_key);
    }
}

// ---- the sequential test ------------------------------------------------------

fn orderedPair(x: []const u8, y: []const u8) [2][]const u8 {
    return if (lessKey({}, x, y)) .{ x, y } else .{ y, x };
}

fn findLlr(eng: *Engine, x: []const u8, y: []const u8) ?*PairLlr {
    const k = orderedPair(x, y);
    for (state(eng).llr.items) |*pl| {
        if (std.mem.eql(u8, pl.a, k[0]) and std.mem.eql(u8, pl.b, k[1])) return pl;
    }
    return null;
}

fn removeLlr(eng: *Engine, x: []const u8, y: []const u8) void {
    const k = orderedPair(x, y);
    const list = &state(eng).llr;
    for (list.items, 0..) |pl, i| {
        if (std.mem.eql(u8, pl.a, k[0]) and std.mem.eql(u8, pl.b, k[1])) {
            _ = list.orderedRemove(i);
            return;
        }
    }
}

// The `same` tests of the `gate` line, in pack order.
fn sameTests(eng: *Engine) ![]const pack_mod.Test {
    var out = std.ArrayList(pack_mod.Test).init(eng.alloc());
    for (eng.pack.gate) |t| if (std.mem.eql(u8, t.name(), "same")) try out.append(t);
    return out.items;
}

// The `same` tests of the `gate` line run again without trace records.
fn sameTestsPassSilently(eng: *Engine, a_key: []const u8, b_key: []const u8) !bool {
    const a = eng.entities.get(a_key).?;
    const b = eng.entities.get(b_key).?;
    for (try sameTests(eng)) |t| {
        const pr = pair_tests.Pair{ .a = a, .b = b, .b_pred = b.filter, .filter = eng.pack.filter };
        if (!t.run(pr).pass) return false;
    }
    return true;
}

// Update of a pair: `L = min(max(L + increment, lo), up)`, or `L = lo` when
// forced; then the `llr` record. Returns the new `L`.
fn sprtUpdate(eng: *Engine, res: *Result, s: pack_mod.Sprt, a_key: []const u8, b_key: []const u8, forced: bool) !f64 {
    const up = s.upper();
    const lo = s.lower();
    const pl = findLlr(eng, a_key, b_key) orelse blk: {
        const k = orderedPair(a_key, b_key);
        try state(eng).llr.append(.{ .a = k[0], .b = k[1], .l = 0 });
        break :blk &state(eng).llr.items[state(eng).llr.items.len - 1];
    };
    var increment: json.Value = .null;
    var d2: json.Value = .null;
    if (forced) {
        pl.l = lo;
    } else {
        const a = eng.entities.get(a_key).?;
        const b = eng.entities.get(b_key).?;
        const ev = sprt_mod.evidence(a, b, try eng.comparePrediction(a, b), s);
        pl.l = @min(@max(pl.l + ev.increment, lo), up);
        increment = .{ .float = ev.increment };
        d2 = .{ .float = ev.d2 };
    }
    const l = pl.l;
    try res.trace.append(try eng.object(.{
        .{ "stage", "sprt" },
        .{ "a", a_key },
        .{ "b", b_key },
        .{ "test", "llr" },
        .{ "value", l },
        .{ "limit", up },
        .{ "pass", l >= up },
        .{ "lower", lo },
        .{ "increment", increment },
        .{ "d2", d2 },
    }));
    return l;
}

// A is in a group G: only the link pair (greatest `L`, none reads 0, ties to
// key order) is updated, after the `same` tests of the `gate` line. At `lo`
// or below A leaves G (reason `release`), and every pair naming A at `lo` or
// below is removed.
fn sprtLink(eng: *Engine, res: *Result, s: pack_mod.Sprt, a_key: []const u8, gid: u64) !void {
    const g = state(eng).groups.items[groupIndex(eng, gid)];
    var link: ?[]const u8 = null;
    var best: f64 = 0;
    for (g.members.items) |m| {
        if (std.mem.eql(u8, m, a_key)) continue;
        const l = if (findLlr(eng, a_key, m)) |pl| pl.l else 0;
        if (link == null or l > best) {
            link = m;
            best = l;
        }
    }
    const b_key = link.?;
    const ok = try eng.runTests(res, .gate, try sameTests(eng), a_key, b_key);
    const l = try sprtUpdate(eng, res, s, a_key, b_key, !ok);
    if (l > s.lower()) return;
    try leave(eng, res, a_key, "release");
    const lo = s.lower();
    var i: usize = 0;
    const list = &state(eng).llr;
    while (i < list.items.len) {
        const pl = list.items[i];
        if ((std.mem.eql(u8, pl.a, a_key) or std.mem.eql(u8, pl.b, a_key)) and pl.l <= lo) {
            _ = list.orderedRemove(i);
        } else i += 1;
    }
}

// A is not in a group: each candidate's gate and confirm tests, then its
// pair's update; a pair at `lo` or below is removed, one at `up` is ready.
fn sprtAssociate(eng: *Engine, res: *Result, s: pack_mod.Sprt, a_key: []const u8) !void {
    const a = eng.entities.get(a_key).?;
    var ready = std.ArrayList([]const u8).init(eng.alloc());
    for (try eng.sortedKeys()) |b_key| {
        if (!isCandidate(eng, a, b_key)) continue;
        var ok = try eng.runTests(res, .gate, eng.pack.gate, a_key, b_key);
        if (ok) ok = try eng.runTests(res, .confirm, eng.pack.confirm, a_key, b_key);
        var forced = false;
        if (!ok) {
            if (findLlr(eng, a_key, b_key) == null) continue;
            forced = !try sameTestsPassSilently(eng, a_key, b_key);
        }
        const l = try sprtUpdate(eng, res, s, a_key, b_key, forced);
        if (l <= s.lower()) {
            removeLlr(eng, a_key, b_key);
        } else if (l >= s.upper()) {
            try ready.append(b_key);
        }
    }
    _ = try choose(eng, res, a_key, ready.items);
}

fn pairCount(eng: *Engine, x: []const u8, y: []const u8) *PairCount {
    const a, const b = if (lessKey({}, x, y)) .{ x, y } else .{ y, x };
    for (state(eng).counts.items) |*pc| {
        if (std.mem.eql(u8, pc.a, a) and std.mem.eql(u8, pc.b, b)) return pc;
    }
    state(eng).counts.append(.{ .a = a, .b = b, .count = 0 }) catch @panic("out of memory");
    return &state(eng).counts.items[state(eng).counts.items.len - 1];
}

pub fn groupIndex(eng: *Engine, id: u64) usize {
    for (state(eng).groups.items, 0..) |g, i| if (g.id == id) return i;
    unreachable;
}

// Spec "Association": A is in a group G, hold.
fn hold(eng: *Engine, res: *Result, a_key: []const u8, gid: u64) !void {
    const g = state(eng).groups.items[groupIndex(eng, gid)];
    const others = try eng.alloc().dupe([]const u8, g.members.items);
    var any_pass = false;
    for (others) |m| {
        if (std.mem.eql(u8, m, a_key)) continue;
        // Spec 0.2: the hold passes at the first passing member; no later member is tested.
        if (try eng.runTests(res, .hold, eng.pack.hold, a_key, m)) {
            any_pass = true;
            break;
        }
    }
    const a = eng.entities.getPtr(a_key).?;
    if (any_pass) {
        a.hold_failures = 0;
    } else {
        a.hold_failures += 1;
        if (a.hold_failures >= eng.pack.hold_failures) {
            a.hold_failures = 0;
            try leave(eng, res, a_key, "hold");
        }
    }
}

// `leave`, then `dissolve` when one member is left.
fn leave(eng: *Engine, res: *Result, key: []const u8, reason: []const u8) !void {
    const e = eng.entities.getPtr(key).?;
    const gid = e.group.?;
    e.group = null;
    const gi = groupIndex(eng, gid);
    const g = &state(eng).groups.items[gi];
    for (g.members.items, 0..) |m, i| {
        if (std.mem.eql(u8, m, key)) {
            _ = g.members.orderedRemove(i);
            break;
        }
    }
    const name = try eng.groupName(gid);
    try res.events.append(try eng.object(.{ .{ "ev", "leave" }, .{ "group", name }, .{ "entity", key }, .{ "reason", reason } }));
    if (g.members.items.len == 1) {
        const last = g.members.items[0];
        const rest = eng.entities.getPtr(last).?;
        rest.group = null;
        rest.hold_failures = 0;
        _ = state(eng).groups.orderedRemove(gi);
        try res.events.append(try eng.object(.{ .{ "ev", "dissolve" }, .{ "group", name }, .{ "entity", last } }));
    }
}

fn groupHoldsSource(eng: *Engine, gid: u64, source: []const u8) bool {
    for (state(eng).groups.items[groupIndex(eng, gid)].members.items) |m| {
        if (std.mem.eql(u8, eng.entities.get(m).?.source, source)) return true;
    }
    return false;
}

// The candidates of associate: every other entity, excluding (unless
// `same_source allow`) A's source and a group that already holds it.
fn isCandidate(eng: *Engine, a: Entity, b_key: []const u8) bool {
    if (std.mem.eql(u8, b_key, a.key)) return false;
    const b = eng.entities.get(b_key).?;
    if (!eng.pack.same_source_allow) {
        if (std.mem.eql(u8, b.source, a.source)) return false;
        if (b.group) |bg| if (groupHoldsSource(eng, bg, a.source)) return false;
    }
    return true;
}

// Spec "Association": A is not in a group, associate.
fn associate(eng: *Engine, res: *Result, a_key: []const u8) !void {
    const a = eng.entities.get(a_key).?;
    var reached = std.ArrayList([]const u8).init(eng.alloc());

    for (try eng.sortedKeys()) |b_key| {
        if (!isCandidate(eng, a, b_key)) continue;
        var ok = try eng.runTests(res, .gate, eng.pack.gate, a_key, b_key);
        if (ok) ok = try eng.runTests(res, .confirm, eng.pack.confirm, a_key, b_key);
        const pc = pairCount(eng, a_key, b_key);
        pc.count = if (ok) pc.count + 1 else 0;
        const done = pc.count >= eng.pack.confirm_count;
        try res.trace.append(try eng.object(.{
            .{ "stage", "confirm" },
            .{ "a", a_key },
            .{ "b", b_key },
            .{ "test", "count" },
            .{ "value", pc.count },
            .{ "limit", eng.pack.confirm_count },
            .{ "pass", done },
        }));
        if (done) try reached.append(b_key);
    }

    // The chosen pair's count is reset to 0.
    const b_key = try choose(eng, res, a_key, reached.items) orelse return;
    pairCount(eng, a_key, b_key).count = 0;
}

// Of the candidates that reached `confirm_count` (or with `sprt` are ready),
// the smallest position `d²`, ties to key order, with their `rank` records;
// A joins the chosen B's group or correlates with B. Returns the chosen B.
fn choose(eng: *Engine, res: *Result, a_key: []const u8, reached: []const []const u8) !?[]const u8 {
    const a = eng.entities.get(a_key).?;
    var chosen: ?[]const u8 = null;
    var best: f64 = 0;
    for (reached) |b_key| {
        const b = eng.entities.get(b_key).?;
        // correlate.md 0.8: the rank `d²` also adds B's timing variance.
        const d2 = pair_tests.mahalanobis(a, b.predictedForComparison(a.last_time_ms, eng.pack));
        try res.trace.append(try eng.object(.{
            .{ "stage", "rank" },
            .{ "a", a_key },
            .{ "b", b_key },
            .{ "test", "rank" },
            .{ "value", d2 },
            .{ "limit", json.Value{ .null = {} } },
            .{ "pass", true },
        }));
        if (chosen == null or d2 < best) {
            chosen = b_key;
            best = d2;
        }
    }

    const b_key = chosen orelse return null;
    const b = eng.entities.getPtr(b_key).?;
    if (b.group) |gid| {
        const g = &state(eng).groups.items[groupIndex(eng, gid)];
        try Engine.insertSorted(&g.members, a_key);
        eng.entities.getPtr(a_key).?.group = gid;
        try res.events.append(try eng.object(.{ .{ "ev", "join" }, .{ "group", try eng.groupName(gid) }, .{ "entity", a_key } }));
    } else {
        const gid = state(eng).next_group;
        state(eng).next_group += 1;
        var members = std.ArrayList([]const u8).init(eng.alloc());
        try Engine.insertSorted(&members, a_key);
        try Engine.insertSorted(&members, b_key);
        try state(eng).groups.append(.{ .id = gid, .members = members });
        b.group = gid;
        eng.entities.getPtr(a_key).?.group = gid;
        try res.events.append(try eng.object(.{ .{ "ev", "correlate" }, .{ "group", try eng.groupName(gid) }, .{ "members", try eng.stringList(members.items) } }));
    }
    return b_key;
}

// Spec operation `tick(now_ms)`, method confirm.
pub fn tick(eng: *Engine, now_ms: i64) !Result {
    var res = Result.init(eng.alloc());

    // 1. Staleness, entities in key order.
    for (try eng.sortedKeys()) |key| {
        const e = eng.entities.get(key).?;
        if (!eng.isStale(e, now_ms)) continue;
        if (e.group != null) try leave(eng, &res, key, "stale");
        _ = eng.entities.orderedRemove(key);
        // Every pair count and pair `L` that names it.
        var i: usize = 0;
        while (i < state(eng).counts.items.len) {
            const pc = state(eng).counts.items[i];
            if (std.mem.eql(u8, pc.a, key) or std.mem.eql(u8, pc.b, key)) {
                _ = state(eng).counts.orderedRemove(i);
            } else i += 1;
        }
        i = 0;
        while (i < state(eng).llr.items.len) {
            const pl = state(eng).llr.items[i];
            if (std.mem.eql(u8, pl.a, key) or std.mem.eql(u8, pl.b, key)) {
                _ = state(eng).llr.orderedRemove(i);
            } else i += 1;
        }
        try res.events.append(try eng.object(.{ .{ "ev", "drop" }, .{ "entity", key } }));
    }

    // 2. Fused output, groups in creation order.
    for (state(eng).groups.items) |g| {
        if (eng.pack.output == .fused) {
            try res.events.append(try fusedEvent(eng, g, now_ms));
            continue;
        }
        const primary = primaryOf(eng, g);
        const p = eng.entities.get(primary).?;
        const flt = p.predictedTo(now_ms, eng.pack);
        const pos = eng.ref.?.toDegrees(.{ .east = flt.east.p, .north = flt.north.p });
        var course = frame.deg(std.math.atan2(flt.east.v, flt.north.v));
        if (course < 0) course += 360.0;
        if (course >= 360.0) course -= 360.0;
        var ev = try eng.object(.{
            .{ "ev", "fused" },
            .{ "group", try eng.groupName(g.id) },
            .{ "primary", primary },
            .{ "members", try eng.stringList(g.members.items) },
            .{ "lat", pos.lat },
            .{ "lon", pos.lon },
            .{ "course", course },
            .{ "speed_ms", std.math.hypot(flt.east.v, flt.north.v) },
        });
        if (p.number("hae")) |hae| try ev.object.put("hae", .{ .float = hae });
        try res.events.append(ev);
    }
    return res;
}

// correlate.md 1.0 "On each tick", `output fused`: per axis the
// information-weighted combination of every member's filter predicted to
// `now_ms`, members in key order, each sum left to right from 0.
pub const FusedAxis = struct { p: f64, v: f64 };

pub fn fuseAxis(axes: []const kalman.Axis) FusedAxis {
    var sp: f64 = 0;
    var wp: f64 = 0;
    var sv: f64 = 0;
    var wv: f64 = 0;
    for (axes) |x| {
        sp = sp + x.p / x.pp;
        wp = wp + 1.0 / x.pp;
    }
    for (axes) |x| {
        sv = sv + x.v / x.vv;
        wv = wv + 1.0 / x.vv;
    }
    return .{ .p = sp / wp, .v = sv / wv };
}

fn fusedEvent(eng: *Engine, g: Group, now_ms: i64) !json.Value {
    const n = g.members.items.len;
    const east = try eng.alloc().alloc(kalman.Axis, n);
    const north = try eng.alloc().alloc(kalman.Axis, n);
    // The `hae` of the member with the greatest `last_time_ms` whose last
    // report has `hae`, ties to key order.
    var hae: ?f64 = null;
    var hae_time: i64 = 0;
    for (g.members.items, 0..) |m, i| {
        const e = eng.entities.get(m).?;
        const flt = e.predictedTo(now_ms, eng.pack);
        east[i] = flt.east;
        north[i] = flt.north;
        if (e.number("hae")) |h| if (hae == null or e.last_time_ms > hae_time) {
            hae = h;
            hae_time = e.last_time_ms;
        };
    }
    const fe = fuseAxis(east);
    const fnorth = fuseAxis(north);
    const pos = eng.ref.?.toDegrees(.{ .east = fe.p, .north = fnorth.p });
    var course = frame.deg(std.math.atan2(fe.v, fnorth.v));
    if (course < 0) course += 360.0;
    if (course >= 360.0) course -= 360.0;
    var ev = try eng.object(.{
        .{ "ev", "fused" },
        .{ "group", try eng.groupName(g.id) },
        .{ "primary", json.Value{ .null = {} } },
        .{ "members", try eng.stringList(g.members.items) },
        .{ "lat", pos.lat },
        .{ "lon", pos.lon },
        .{ "course", course },
        .{ "speed_ms", std.math.hypot(fe.v, fnorth.v) },
    });
    if (hae) |h| try ev.object.put("hae", .{ .float = h });
    return ev;
}

// Members are in key order, so a strict comparison keeps ties to key order.
fn primaryOf(eng: *Engine, g: Group) []const u8 {
    var best = g.members.items[0];
    for (g.members.items[1..]) |m| {
        const cand = eng.entities.get(m).?;
        const cur = eng.entities.get(best).?;
        const better = switch (eng.pack.output) {
            .priority => eng.pack.priorityOf(cand.source) < eng.pack.priorityOf(cur.source),
            .latest => cand.last_time_ms > cur.last_time_ms,
            .fused => unreachable,
        };
        if (better) best = m;
    }
    return best;
}
