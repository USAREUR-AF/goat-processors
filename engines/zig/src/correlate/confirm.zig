// correlate.md, method `confirm`: the gate, confirm and hold stages
// ("Association"), the pair counts and `confirm_count`, the hold failures,
// fixed staleness and the `priority`/`latest` output ("On each tick"). Moved
// here unchanged from the engine; correlate 1.0 replaces it.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const engine_mod = @import("engine.zig");
const frame = @import("../model/frame.zig");
const pair_tests = @import("tests.zig");
const Engine = engine_mod.Engine;
const Result = engine_mod.Result;
const lessKey = engine_mod.lessKey;

pub const Group = struct {
    id: u64,
    members: std.ArrayList([]const u8),
};

const PairCount = struct { a: []const u8, b: []const u8, count: i64 };

// The method's state beyond the entities: the groups in creation order, the
// pair counts, and the counter that names the next group.
pub const State = struct {
    groups: std.ArrayList(Group),
    counts: std.ArrayList(PairCount),
    next_group: u64 = 1,

    pub fn init(a: Allocator) State {
        return .{ .groups = std.ArrayList(Group).init(a), .counts = std.ArrayList(PairCount).init(a) };
    }
};

// After an accepted report: hold when A is in a group, otherwise associate.
pub fn afterIngest(eng: *Engine, res: *Result, a_key: []const u8) !void {
    if (eng.entities.get(a_key).?.group) |gid| {
        try hold(eng, res, a_key, gid);
    } else {
        try associate(eng, res, a_key);
    }
}

fn pairCount(eng: *Engine, x: []const u8, y: []const u8) *PairCount {
    const a, const b = if (lessKey({}, x, y)) .{ x, y } else .{ y, x };
    for (eng.confirm_state.counts.items) |*pc| {
        if (std.mem.eql(u8, pc.a, a) and std.mem.eql(u8, pc.b, b)) return pc;
    }
    eng.confirm_state.counts.append(.{ .a = a, .b = b, .count = 0 }) catch @panic("out of memory");
    return &eng.confirm_state.counts.items[eng.confirm_state.counts.items.len - 1];
}

pub fn groupIndex(eng: *Engine, id: u64) usize {
    for (eng.confirm_state.groups.items, 0..) |g, i| if (g.id == id) return i;
    unreachable;
}

// Spec "Association": A is in a group G, hold.
fn hold(eng: *Engine, res: *Result, a_key: []const u8, gid: u64) !void {
    const g = eng.confirm_state.groups.items[groupIndex(eng, gid)];
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
    const g = &eng.confirm_state.groups.items[gi];
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
        _ = eng.confirm_state.groups.orderedRemove(gi);
        try res.events.append(try eng.object(.{ .{ "ev", "dissolve" }, .{ "group", name }, .{ "entity", last } }));
    }
}

fn groupHoldsSource(eng: *Engine, gid: u64, source: []const u8) bool {
    for (eng.confirm_state.groups.items[groupIndex(eng, gid)].members.items) |m| {
        if (std.mem.eql(u8, eng.entities.get(m).?.source, source)) return true;
    }
    return false;
}

// Spec "Association": A is not in a group, associate.
fn associate(eng: *Engine, res: *Result, a_key: []const u8) !void {
    const a = eng.entities.get(a_key).?;
    var reached = std.ArrayList([]const u8).init(eng.alloc());

    for (try eng.sortedKeys()) |b_key| {
        if (std.mem.eql(u8, b_key, a_key)) continue;
        const b = eng.entities.get(b_key).?;
        if (!eng.pack.same_source_allow) {
            if (std.mem.eql(u8, b.source, a.source)) continue;
            if (b.group) |bg| if (groupHoldsSource(eng, bg, a.source)) continue;
        }
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

    // Smallest `d²` among those reaching `confirm_count`, ties to key order.
    var chosen: ?[]const u8 = null;
    var best: f64 = 0;
    for (reached.items) |b_key| {
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

    const b_key = chosen orelse return;
    const b = eng.entities.getPtr(b_key).?;
    if (b.group) |gid| {
        const g = &eng.confirm_state.groups.items[groupIndex(eng, gid)];
        try Engine.insertSorted(&g.members, a_key);
        eng.entities.getPtr(a_key).?.group = gid;
        try res.events.append(try eng.object(.{ .{ "ev", "join" }, .{ "group", try eng.groupName(gid) }, .{ "entity", a_key } }));
    } else {
        const gid = eng.confirm_state.next_group;
        eng.confirm_state.next_group += 1;
        var members = std.ArrayList([]const u8).init(eng.alloc());
        try Engine.insertSorted(&members, a_key);
        try Engine.insertSorted(&members, b_key);
        try eng.confirm_state.groups.append(.{ .id = gid, .members = members });
        b.group = gid;
        eng.entities.getPtr(a_key).?.group = gid;
        try res.events.append(try eng.object(.{ .{ "ev", "correlate" }, .{ "group", try eng.groupName(gid) }, .{ "members", try eng.stringList(members.items) } }));
    }
    pairCount(eng, a_key, b_key).count = 0;
}

// Spec operation `tick(now_ms)`, method confirm.
pub fn tick(eng: *Engine, now_ms: i64) !Result {
    var res = Result.init(eng.alloc());

    // 1. Staleness, entities in key order.
    for (try eng.sortedKeys()) |key| {
        const e = eng.entities.get(key).?;
        const own_stale = if (e.integer("stale_ms")) |s| now_ms >= s else false;
        if (!(now_ms - e.last_time_ms > eng.pack.stale_ms or own_stale)) continue;
        if (e.group != null) try leave(eng, &res, key, "stale");
        _ = eng.entities.orderedRemove(key);
        var i: usize = 0;
        while (i < eng.confirm_state.counts.items.len) {
            const pc = eng.confirm_state.counts.items[i];
            if (std.mem.eql(u8, pc.a, key) or std.mem.eql(u8, pc.b, key)) {
                _ = eng.confirm_state.counts.orderedRemove(i);
            } else i += 1;
        }
        try res.events.append(try eng.object(.{ .{ "ev", "drop" }, .{ "entity", key } }));
    }

    // 2. Fused output, groups in creation order.
    for (eng.confirm_state.groups.items) |g| {
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


// Members are in key order, so a strict comparison keeps ties to key order.
fn primaryOf(eng: *Engine, g: Group) []const u8 {
    var best = g.members.items[0];
    for (g.members.items[1..]) |m| {
        const cand = eng.entities.get(m).?;
        const cur = eng.entities.get(best).?;
        const better = switch (eng.pack.output) {
            .priority => eng.pack.priorityOf(cand.source) < eng.pack.priorityOf(cur.source),
            .latest => cand.last_time_ms > cur.last_time_ms,
        };
        if (better) best = m;
    }
    return best;
}
