// spec/correlate-assign.md (version 0.2): system tracks, per-source least-cost
// assignment at each tick, inverse-variance fused estimate.
const std = @import("std");
const json = std.json;
const engine_mod = @import("engine.zig");
const frame = @import("frame.zig");
const kalman = @import("kalman.zig");
const hungarian = @import("hungarian.zig");
const Engine = engine_mod.Engine;
const Result = engine_mod.Result;
const lessKey = engine_mod.lessKey;

const inf = std.math.inf(f64);

// "Fused estimate", one axis: inverse-variance weights of the members' predictions.
const FusedAxis = struct { p: f64, v: f64, pp: f64, vv: f64 };
const Fused = struct { east: FusedAxis, north: FusedAxis };

fn fuseAxis(axes: []const kalman.Axis) FusedAxis {
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

fn fused(self: *Engine, members: []const []const u8, t_ms: i64) !Fused {
    const a = self.alloc();
    const east = try a.alloc(kalman.Axis, members.len);
    const north = try a.alloc(kalman.Axis, members.len);
    for (members, 0..) |m, i| {
        const f = self.entities.get(m).?.predictedTo(t_ms, self.pack.filter.accel_var);
        east[i] = f.east;
        north[i] = f.north;
    }
    return .{ .east = fuseAxis(east), .north = fuseAxis(north) };
}

// "Cost": d² of A against the fused estimate of M, both at A's `last_time_ms`.
fn cost(self: *Engine, a_key: []const u8, members: []const []const u8) !f64 {
    const a = self.entities.get(a_key).?;
    const m = try fused(self, members, a.last_time_ms);
    const de = a.filter.east.p - m.east.p;
    const dn = a.filter.north.p - m.north.p;
    return de * de / (a.filter.east.pp + m.east.pp) + dn * dn / (a.filter.north.pp + m.north.pp);
}

fn systemOf(self: *Engine, key: []const u8) ?u64 {
    return self.entities.get(key).?.group;
}

fn systemMembers(self: *Engine, id: u64) []const []const u8 {
    return self.groups.items[self.groupIndex(id)].members.items;
}

fn removeMember(list: *std.ArrayList([]const u8), key: []const u8) void {
    for (list.items, 0..) |m, i| {
        if (std.mem.eql(u8, m, key)) {
            _ = list.orderedRemove(i);
            return;
        }
    }
}

// A leaves its system track (`leave`), which ends when left empty (`end`).
fn leave(self: *Engine, res: *Result, key: []const u8, reason: []const u8) !void {
    const e = self.entities.getPtr(key).?;
    const id = e.group.?;
    e.group = null;
    const gi = self.groupIndex(id);
    removeMember(&self.groups.items[gi].members, key);
    const name = try self.groupName(id);
    try res.events.append(try self.object(.{ .{ "ev", "leave" }, .{ "system", name }, .{ "entity", key }, .{ "reason", reason } }));
    if (self.groups.items[gi].members.items.len == 0) {
        _ = self.groups.orderedRemove(gi);
        try res.events.append(try self.object(.{ .{ "ev", "end" }, .{ "system", name } }));
    }
}

fn traceRecord(self: *Engine, res: *Result, a: []const u8, b: []const u8, test_name: []const u8, value: ?f64) !void {
    try res.trace.append(try self.object(.{
        .{ "stage", "assign" },
        .{ "a", a },
        .{ "b", b },
        .{ "test", test_name },
        .{ "value", value },
        .{ "limit", json.Value{ .null = {} } },
        .{ "pass", value != null },
    }));
}

const Column = struct { id: u64, others: []const []const u8 };

// "On each tick", one source S with its reported entities R (key order).
fn assignSource(self: *Engine, res: *Result, source: []const u8, rows: []const []const u8) !void {
    const a = self.alloc();

    // 1. Columns: R entities left out, not empty, no entity of S; creation order.
    var cols = std.ArrayList(Column).init(a);
    for (self.groups.items) |g| {
        var others = std.ArrayList([]const u8).init(a);
        var has_s = false;
        for (g.members.items) |m| {
            var in_r = false;
            for (rows) |r| if (std.mem.eql(u8, r, m)) {
                in_r = true;
            };
            if (in_r) continue;
            if (std.mem.eql(u8, self.entities.get(m).?.source, source)) has_s = true;
            try others.append(m);
        }
        if (others.items.len == 0 or has_s) continue;
        try cols.append(.{ .id = g.id, .others = others.items });
    }

    // 2. Entries. Matrix columns: the system-track columns, then one `alone` per row.
    const nc = cols.items.len;
    const n = rows.len;
    const m = nc + n;
    const costs = try a.alloc(f64, n * m);
    @memset(costs, inf);
    for (rows, 0..) |r, i| {
        const own = systemOf(self, r);
        for (cols.items, 0..) |c, j| {
            var ok = true;
            for (c.others) |o| {
                if (!try self.runTests(res, .gate, self.pack.gate, r, o)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;
            var d2 = try cost(self, r, c.others);
            if (own != null and own.? == c.id) d2 -= self.pack.keep_bonus;
            costs[i * m + j] = d2;
        }
        var alone = self.pack.new_cost;
        if (own) |id| {
            if (systemMembers(self, id).len == 1) alone -= self.pack.keep_bonus;
        }
        costs[i * m + nc + i] = alone;
    }

    // Trace: entries, entities in key order, columns in creation order then `alone`.
    for (rows, 0..) |r, i| {
        for (cols.items, 0..) |c, j| {
            const v = costs[i * m + j];
            try traceRecord(self, res, r, try self.groupName(c.id), "cost", if (v == inf) null else v);
        }
        try traceRecord(self, res, r, "alone", "cost", costs[i * m + nc + i]);
    }

    // 3. Exact least-cost assignment.
    const choice = try hungarian.solve(a, costs, n, m);

    for (rows, 0..) |r, i| {
        const j = choice[i];
        const b = if (j < nc) try self.groupName(cols.items[j].id) else "alone";
        try traceRecord(self, res, r, b, "choice", costs[i * m + j]);
    }

    // 4. Apply, entities of R in key order.
    for (rows, 0..) |r, i| {
        const j = choice[i];
        const own = systemOf(self, r);
        if (j < nc) {
            const target = cols.items[j].id;
            if (own != null and own.? == target) continue;
            if (own != null) try leave(self, res, r, "assign");
            const g = &self.groups.items[self.groupIndex(target)];
            try Engine.insertSorted(&g.members, r);
            self.entities.getPtr(r).?.group = target;
            try res.events.append(try self.object(.{ .{ "ev", "join" }, .{ "system", try self.groupName(target) }, .{ "entity", r } }));
        } else {
            if (own) |id| {
                if (systemMembers(self, id).len == 1) continue;
                try leave(self, res, r, "assign");
            }
            const id = self.next_group;
            self.next_group += 1;
            var members = std.ArrayList([]const u8).init(a);
            try members.append(r);
            try self.groups.append(.{ .id = id, .members = members });
            self.entities.getPtr(r).?.group = id;
            try res.events.append(try self.object(.{ .{ "ev", "start" }, .{ "system", try self.groupName(id) }, .{ "entity", r } }));
        }
    }
}

pub fn tick(self: *Engine, now_ms: i64) !Result {
    const a = self.alloc();
    var res = Result{ .events = json.Array.init(a), .trace = json.Array.init(a) };

    // Staleness, first, entities in key order (rule of correlate.md).
    for (try self.sortedKeys()) |key| {
        const e = self.entities.get(key).?;
        const own_stale = if (e.integer("stale_ms")) |s| now_ms >= s else false;
        if (!(now_ms - e.last_time_ms > self.pack.stale_ms or own_stale)) continue;
        if (e.group != null) try leave(self, &res, key, "stale");
        _ = self.entities.orderedRemove(key);
        _ = self.reported.orderedRemove(key);
        try res.events.append(try self.object(.{ .{ "ev", "drop" }, .{ "entity", key } }));
    }

    // Reported entities, grouped by source, sources in key order.
    const reported = try a.dupe([]const u8, self.reported.keys());
    std.mem.sort([]const u8, reported, {}, lessKey);
    var sources = std.ArrayList([]const u8).init(a);
    for (reported) |k| {
        const src = self.entities.get(k).?.source;
        var seen = false;
        for (sources.items) |s| if (std.mem.eql(u8, s, src)) {
            seen = true;
        };
        if (!seen) try sources.append(src);
    }
    std.mem.sort([]const u8, sources.items, {}, lessKey);
    for (sources.items) |src| {
        var rows = std.ArrayList([]const u8).init(a);
        for (reported) |k| if (std.mem.eql(u8, self.entities.get(k).?.source, src)) try rows.append(k);
        try assignSource(self, &res, src, rows.items);
    }
    self.reported.clearRetainingCapacity();

    // Output, system tracks in creation order.
    for (self.groups.items) |g| {
        const f = try fused(self, g.members.items, now_ms);
        const pos = self.ref.?.toDegrees(.{ .east = f.east.p, .north = f.north.p });
        var course = frame.deg(std.math.atan2(f.east.v, f.north.v));
        if (course < 0) course += 360.0;
        if (course >= 360.0) course -= 360.0;
        var ev = try self.object(.{
            .{ "ev", "system" },
            .{ "system", try self.groupName(g.id) },
            .{ "members", try self.stringList(g.members.items) },
            .{ "lat", pos.lat },
            .{ "lon", pos.lon },
            .{ "course", course },
            .{ "speed_ms", std.math.hypot(f.east.v, f.north.v) },
        });
        // `hae` from the member with the greatest `last_time_ms` that has one; ties to key order.
        var best: ?struct { t: i64, hae: f64 } = null;
        for (g.members.items) |mk| {
            const e = self.entities.get(mk).?;
            const hae = e.number("hae") orelse continue;
            if (best == null or e.last_time_ms > best.?.t) best = .{ .t = e.last_time_ms, .hae = hae };
        }
        if (best) |b| try ev.object.put("hae", .{ .float = b.hae });
        try res.events.append(ev);
    }
    return res;
}

pub fn snapshot(self: *Engine) !json.Value {
    const a = self.alloc();
    var ref: json.Value = .null;
    if (self.ref) |r| {
        var arr = json.Array.init(a);
        try arr.append(.{ .float = r.lat0 });
        try arr.append(.{ .float = r.lon0 });
        ref = .{ .array = arr };
    }
    var entities = json.ObjectMap.init(a);
    for (try self.sortedKeys()) |key| {
        const e = self.entities.get(key).?;
        const system: ?[]const u8 = if (e.group) |id| try self.groupName(id) else null;
        try entities.put(key, try self.object(.{
            .{ "last_time_ms", e.last_time_ms },
            .{ "system", system },
            .{ "filter", try self.object(.{ .{ "east", try self.axisValue(e.filter.east) }, .{ "north", try self.axisValue(e.filter.north) } }) },
        }));
    }
    var systems = json.ObjectMap.init(a);
    for (self.groups.items) |g| try systems.put(try self.groupName(g.id), try self.stringList(g.members.items));
    // correlate-assign.md 0.2 "Snapshot": entities reported since the previous tick, key order.
    const reported = try a.dupe([]const u8, self.reported.keys());
    std.mem.sort([]const u8, reported, {}, lessKey);
    return self.object(.{
        .{ "ref", ref },
        .{ "entities", json.Value{ .object = entities } },
        .{ "systems", json.Value{ .object = systems } },
        .{ "next_system", self.next_group },
        .{ "reported", try self.stringList(reported) },
    });
}
