// spec/fuse.md: the fuse engine and its four operations, `load_pack`,
// `ingest`, `tick`, `snapshot`. Frame, Track estimate and the report helpers
// are the correlate ones (fuse.md "Shared with correlate.md").
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const frame = @import("frame.zig");
const kalman = @import("kalman.zig");
const reports = @import("entity.zig");
const fuse_pack = @import("fuse_pack.zig");
const kin = @import("fuse_kinematics.zig");

pub const Pack = fuse_pack.Pack;
pub const load_pack = fuse_pack.load;

pub const Result = struct {
    events: json.Array,
    trace: json.Array,
};

// One entity: its filter and its last normalised report.
const Entity = struct {
    key: []const u8,
    source: []const u8,
    last_time_ms: i64,
    // The last normalised report (fuse.md "Reports").
    report: json.ObjectMap,
    filter: kalman.Filter,
    // fuse.md "Groups": the `fuse.group` of the last accepted report, or null.
    group: ?[]const u8,

    // correlate.md "Track estimate", prediction: step 1 on a copy.
    fn predictedTo(self: Entity, t_ms: i64, q: f64) kalman.Filter {
        const dt = @as(f64, @floatFromInt(t_ms - self.last_time_ms)) / 1000.0;
        return self.filter.predict(dt, q);
    }
};

// fuse.md "Groups": a named group, or the unnamed group of one entity.
const Group = struct {
    name: ?[]const u8,
    // In key order.
    members: []const []const u8,
};

fn lessKey(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

// ---- JSON output -------------------------------------------------------------

fn toValue(x: anytype) json.Value {
    const T = @TypeOf(x);
    if (T == json.Value) return x;
    if (T == bool) return .{ .bool = x };
    if (T == f64 or T == comptime_float) return .{ .float = x };
    if (T == i64 or T == usize or T == comptime_int) return .{ .integer = @intCast(x) };
    switch (@typeInfo(T)) {
        .Pointer => |p| {
            if (p.size == .Slice and p.child == u8) return .{ .string = x };
            if (p.size == .One and @typeInfo(p.child) == .Array) return .{ .string = x };
        },
        .Optional => return if (x) |v| toValue(v) else .null,
        else => {},
    }
    @compileError("unsupported value type " ++ @typeName(T));
}

// `fields` is a tuple of .{ name, value } pairs.
fn object(a: Allocator, fields: anytype) !json.Value {
    var m = json.ObjectMap.init(a);
    inline for (fields) |kv| try m.put(kv[0], toValue(kv[1]));
    return .{ .object = m };
}

fn stringList(a: Allocator, items: []const []const u8) !json.Value {
    var arr = json.Array.init(a);
    for (items) |s| try arr.append(.{ .string = s });
    return .{ .array = arr };
}

fn cloneValue(a: Allocator, v: json.Value) Allocator.Error!json.Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out = json.Array.init(a);
            for (arr.items) |item| try out.append(try cloneValue(a, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out = json.ObjectMap.init(a);
            var it = obj.iterator();
            while (it.next()) |e| try out.put(try a.dupe(u8, e.key_ptr.*), try cloneValue(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
    };
}

// ---- Reports -----------------------------------------------------------------

fn isNumber(v: json.Value) bool {
    return v == .integer or v == .float or v == .number_string;
}

// fuse.md "Reports", the normalised report: every key removed that is `null`,
// an optional key of correlate.md of the wrong type, a `ce` of 0 or below, or an
// unusable `fuse.group`. The required keys have already been checked.
fn normalise(a: Allocator, report: json.ObjectMap) !json.ObjectMap {
    var out = json.ObjectMap.init(a);
    var it = report.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        const v = e.value_ptr.*;
        const keep = if (v == .null)
            false
        else if (std.mem.eql(u8, k, "hae") or std.mem.eql(u8, k, "course") or std.mem.eql(u8, k, "speed_ms"))
            isNumber(v)
        else if (std.mem.eql(u8, k, "ce"))
            reports.ceOf(report) != null
        else if (std.mem.eql(u8, k, "type"))
            v == .string
        else if (std.mem.eql(u8, k, "stale_ms"))
            v == .integer
        else if (std.mem.eql(u8, k, "fuse.group"))
            v == .string and v.string.len > 0
        else
            true;
        if (keep) try out.put(try a.dupe(u8, k), try cloneValue(a, v));
    }
    return out;
}

// ---- Engine ------------------------------------------------------------------

pub const Engine = struct {
    arena: std.heap.ArenaAllocator,
    pack: Pack,
    ref: ?frame.Frame = null,
    entities: std.StringArrayHashMap(Entity),

    pub fn create(backing: Allocator, pack: Pack) !*Engine {
        const self = try backing.create(Engine);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(backing), .pack = pack, .entities = undefined };
        self.entities = std.StringArrayHashMap(Entity).init(self.arena.allocator());
        return self;
    }

    pub fn destroy(self: *Engine) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }

    fn alloc(self: *Engine) Allocator {
        return self.arena.allocator();
    }

    fn newResult(self: *Engine) Result {
        return .{ .events = json.Array.init(self.alloc()), .trace = json.Array.init(self.alloc()) };
    }

    fn sortedKeys(self: *Engine) ![][]const u8 {
        const keys = try self.alloc().dupe([]const u8, self.entities.keys());
        std.mem.sort([]const u8, keys, {}, lessKey);
        return keys;
    }

    // ---- ingest: fuse.md "Reports" and "Groups" ----------------------------

    pub fn ingest(self: *Engine, report: json.ObjectMap) !Result {
        const a = self.alloc();
        var res = self.newResult();

        // correlate.md "Reports": required keys, in the order of the table.
        const source = reports.stringOf(report, "track.source_id");
        const uid = reports.stringOf(report, "uid");
        const time_ms = reports.integerOf(report, "time_ms");
        const lat = reports.numberOf(report, "lat");
        const lon = reports.numberOf(report, "lon");
        const missing: ?[]const u8 = if (source == null) "track.source_id" else if (uid == null) "uid" else if (time_ms == null) "time_ms" else if (lat == null) "lat" else if (lon == null) "lon" else null;
        if (missing) |k| {
            try res.events.append(try object(a, .{ .{ "ev", "reject" }, .{ "reason", try std.fmt.allocPrint(a, "missing:{s}", .{k}) } }));
            return res;
        }

        // A report earlier than the entity's last accepted report is ignored.
        const key = try std.fmt.allocPrint(a, "{s}/{s}", .{ source.?, uid.? });
        if (self.entities.get(key)) |existing| {
            if (time_ms.? < existing.last_time_ms) {
                try res.events.append(try object(a, .{
                    .{ "ev", "stale-report" },
                    .{ "entity", key },
                    .{ "time_ms", time_ms.? },
                    .{ "last_time_ms", existing.last_time_ms },
                }));
                return res;
            }
        }

        // correlate.md "Frame": the first accepted report fixes the reference.
        if (self.ref == null) self.ref = .{ .lat0 = lat.?, .lon0 = lon.? };
        const stored = try normalise(a, report);
        const group = reports.stringOf(stored, "fuse.group");
        const pos = self.ref.?.toPlane(lat.?, lon.?);
        const f = self.pack.filter;
        const ce = reports.ceOf(stored) orelse f.default_ce_m;

        // correlate.md "Track estimate": velocity measurement.
        var vel: ?struct { e: f64, n: f64 } = null;
        if (reports.numberOf(stored, "course")) |course| {
            if (reports.numberOf(stored, "speed_ms")) |speed| {
                vel = .{ .e = speed * @sin(frame.rad(course)), .n = speed * @cos(frame.rad(course)) };
            }
        }

        const gop = try self.entities.getOrPut(key);
        if (!gop.found_existing) {
            // First report: the filter starts, event `new`.
            gop.value_ptr.* = .{
                .key = key,
                .source = reports.stringOf(stored, "track.source_id").?,
                .last_time_ms = time_ms.?,
                .report = stored,
                .filter = .{
                    .east = kalman.Axis.init(pos.east, if (vel) |v| v.e else null, ce, f.vel_sigma_ms, f.unknown_vel_ms),
                    .north = kalman.Axis.init(pos.north, if (vel) |v| v.n else null, ce, f.vel_sigma_ms, f.unknown_vel_ms),
                },
                .group = group,
            };
            try res.events.append(try object(a, .{ .{ "ev", "new" }, .{ "entity", key }, .{ "group", group } }));
            return res;
        }

        // Later report: predict, position update, velocity update.
        const e = gop.value_ptr;
        var flt = e.predictedTo(time_ms.?, f.accel_var);
        flt.east = flt.east.updatePosition(pos.east, ce * ce);
        flt.north = flt.north.updatePosition(pos.north, ce * ce);
        if (vel) |v| {
            const r = f.vel_sigma_ms * f.vel_sigma_ms;
            flt.east = flt.east.updateVelocity(v.e, r);
            flt.north = flt.north.updateVelocity(v.n, r);
        }
        e.filter = flt;
        e.last_time_ms = time_ms.?;
        e.report = stored;

        // fuse.md "Groups": a move is applied after the filter update.
        const from = e.group;
        e.group = group;
        if (!optEql(from, group)) {
            try res.events.append(try object(a, .{ .{ "ev", "move" }, .{ "entity", e.key }, .{ "from", from }, .{ "to", group } }));
        }
        return res;
    }

    // ---- tick: fuse.md "On each tick" -----------------------------------------

    pub fn tick(self: *Engine, now_ms: i64) !Result {
        var res = self.newResult();

        // 1. Staleness, entities in key order.
        for (try self.sortedKeys()) |key| {
            const e = self.entities.get(key).?;
            const by_pack = now_ms - e.last_time_ms > self.pack.stale_ms;
            const by_report = if (reports.integerOf(e.report, "stale_ms")) |s| now_ms >= s else false;
            if (by_pack or by_report) {
                try res.events.append(try object(self.alloc(), .{ .{ "ev", "drop" }, .{ "entity", e.key }, .{ "group", e.group } }));
                _ = self.entities.orderedRemove(key);
            }
        }

        // 2. Fused output, groups in output order.
        for (try self.groupsInOutputOrder()) |g| try self.fuseGroup(&res, g, now_ms);
        return res;
    }

    // fuse.md "Groups", output order: named groups in byte order of their name,
    // then the unnamed groups in key order of their one member.
    fn groupsInOutputOrder(self: *Engine) ![]Group {
        const a = self.alloc();
        const keys = try self.sortedKeys();
        var names = std.ArrayList([]const u8).init(a);
        for (keys) |k| {
            const g = self.entities.get(k).?.group orelse continue;
            for (names.items) |n| {
                if (std.mem.eql(u8, n, g)) break;
            } else try names.append(g);
        }
        std.mem.sort([]const u8, names.items, {}, lessKey);

        var groups = std.ArrayList(Group).init(a);
        for (names.items) |n| {
            var members = std.ArrayList([]const u8).init(a);
            for (keys) |k| {
                if (optEql(self.entities.get(k).?.group, n)) try members.append(k);
            }
            try groups.append(.{ .name = n, .members = members.items });
        }
        for (keys) |k| {
            if (self.entities.get(k).?.group == null) {
                try groups.append(.{ .name = null, .members = try a.dupe([]const u8, &.{k}) });
            }
        }
        return groups.items;
    }

    // One group, step 2 of "On each tick".
    fn fuseGroup(self: *Engine, res: *Result, g: Group, now_ms: i64) !void {
        const a = self.alloc();
        const n = g.members.len;

        // 2.1 Predict every member's filter to `now_ms`.
        const members = try a.alloc(Entity, n);
        const predicted = try a.alloc(kalman.Filter, n);
        for (g.members, 0..) |k, i| {
            members[i] = self.entities.get(k).?;
            predicted[i] = members[i].predictedTo(now_ms, self.pack.filter.accel_var);
        }

        // 2.2 Combine them by the pack's kinematics method.
        const combined = try self.combine(res, g, members, predicted);
        const est = combined.estimate;
        const from: ?[]const u8 = if (combined.from) |i| members[i].key else null;

        // Kinematics trace record.
        var kc = json.Array.init(a);
        for (members, predicted) |m, p| {
            try kc.append(try object(a, .{
                .{ "member", m.key },
                .{ "var", kin.positionVariance(p) },
                .{ "time_ms", m.last_time_ms },
                .{ "rank", self.pack.rank(m.source) },
            }));
        }
        try res.trace.append(try object(a, .{
            .{ "stage", "kinematics" },
            .{ "group", g.name },
            .{ "method", @tagName(self.pack.kinematics) },
            .{ "candidates", json.Value{ .array = kc } },
            .{ "winner", from },
        }));

        // 2.3 Decide every attribute, in pack order.
        var attributes = json.ObjectMap.init(a);
        for (self.pack.attributes) |attr| {
            if (try self.decideAttribute(res, g, members, attr)) |won| {
                try attributes.put(attr.key, try object(a, .{ .{ "value", won.value }, .{ "from", won.from } }));
            }
        }

        // 2.4 The `fused` event (fuse.md "Fused event").
        const deg = self.ref.?.toDegrees(.{ .east = est.east.p, .north = est.north.p });
        var course = frame.deg(std.math.atan2(est.east.v, est.north.v));
        if (course < 0) course += 360;
        if (course >= 360) course -= 360;
        var ev = (try object(a, .{
            .{ "ev", "fused" },
            .{ "group", g.name },
            .{ "members", try stringList(a, g.members) },
            .{ "from", from },
            .{ "lat", deg.lat },
            .{ "lon", deg.lon },
            .{ "course", course },
            .{ "speed_ms", std.math.hypot(est.east.v, est.north.v) },
            .{ "ce", @sqrt((est.east.pp + est.north.pp) / 2.0) },
        })).object;
        if (self.height(members, combined.from)) |i| {
            try ev.put("hae", members[i].report.get("hae").?);
            try ev.put("hae_from", .{ .string = members[i].key });
        }
        try ev.put("attributes", .{ .object = attributes });
        try res.events.append(.{ .object = ev });
    }

    const Combined = struct { estimate: kin.Estimate, from: ?usize };

    // fuse.md "Kinematics". Members are in key order. For
    // `covariance_intersection`, writes one `intersect` record per fold.
    fn combine(self: *Engine, res: *Result, g: Group, members: []const Entity, predicted: []const kalman.Filter) !Combined {
        const a = self.alloc();
        const estimates = try a.alloc(kin.Estimate, members.len);
        for (predicted, 0..) |p, i| estimates[i] = kin.Estimate.of(p);

        switch (self.pack.kinematics) {
            .inverse_variance => {
                const scratch = try a.alloc(kin.AxisEstimate, members.len);
                return .{ .estimate = kin.inverseVariance(estimates, scratch), .from = null };
            },
            .covariance_intersection => {
                var x = estimates[0];
                for (estimates[1..], members[1..]) |y, m| {
                    const w = kin.intersectionWeight(x, y);
                    try res.trace.append(try object(a, .{
                        .{ "stage", "intersect" },
                        .{ "group", g.name },
                        .{ "member", m.key },
                        .{ "value", w },
                    }));
                    x = kin.fold(x, y, w);
                }
                return .{ .estimate = x, .from = null };
            },
            .best, .priority, .latest => {
                // The first member in key order that is strictly better wins,
                // so ties go to key order.
                var win: usize = 0;
                for (1..members.len) |i| {
                    const better = switch (self.pack.kinematics) {
                        .best => kin.positionVariance(predicted[i]) < kin.positionVariance(predicted[win]),
                        .priority => self.pack.rankOrder(members[i].source) < self.pack.rankOrder(members[win].source),
                        .latest => members[i].last_time_ms > members[win].last_time_ms,
                        else => unreachable,
                    };
                    if (better) win = i;
                }
                return .{ .estimate = estimates[win], .from = win };
            },
        }
    }

    // fuse.md "Fused event", Height. Returns the index of the member whose
    // `hae` is given, or null for no height.
    fn height(self: *Engine, members: []const Entity, from: ?usize) ?usize {
        switch (self.pack.kinematics) {
            .best, .priority, .latest => {
                const i = from.?;
                return if (members[i].report.get("hae") != null) i else null;
            },
            .inverse_variance, .covariance_intersection => {
                var win: ?usize = null;
                for (members, 0..) |m, i| {
                    if (m.report.get("hae") == null) continue;
                    if (win == null or m.last_time_ms > members[win.?].last_time_ms) win = i;
                }
                return win;
            },
        }
    }

    // ---- fuse.md "Attributes" -------------------------------------------------

    const Won = struct { value: json.Value, from: []const u8 };

    // Decides one attribute for a group and writes its trace record.
    fn decideAttribute(self: *Engine, res: *Result, g: Group, members: []const Entity, attr: fuse_pack.Attribute) !?Won {
        const a = self.alloc();

        // Candidates: members in key order whose last report holds the key
        // with a usable value.
        const Candidate = struct { m: Entity, value: json.Value };
        var cands = std.ArrayList(Candidate).init(a);
        for (members) |m| {
            const v = m.report.get(attr.key) orelse continue;
            const usable = switch (attr.rule) {
                .priority, .latest, .majority => v == .string or v == .bool or isNumber(v),
                .max, .min => isNumber(v),
            };
            if (usable) try cands.append(.{ .m = m, .value = v });
        }

        var winner: ?usize = null;
        if (cands.items.len > 0) {
            const c = cands.items;
            var win: usize = 0;
            switch (attr.rule) {
                // Strictly better replaces, so ties go to key order.
                .priority => for (1..c.len) |i| {
                    if (self.pack.rankOrder(c[i].m.source) < self.pack.rankOrder(c[win].m.source)) win = i;
                },
                .latest => for (1..c.len) |i| {
                    if (c[i].m.last_time_ms > c[win].m.last_time_ms) win = i;
                },
                .max => for (1..c.len) |i| {
                    if (numberValue(c[i].value) > numberValue(c[win].value)) win = i;
                },
                .min => for (1..c.len) |i| {
                    if (numberValue(c[i].value) < numberValue(c[win].value)) win = i;
                },
                // Count each value at its first holder in key order; the most
                // held value wins, ties to the earlier first holder.
                .majority => {
                    var best_count: usize = 0;
                    for (c, 0..) |ci, i| {
                        const first_holder = for (c[0..i]) |cj| {
                            if (majorityEqual(cj.value, ci.value)) break false;
                        } else true;
                        if (!first_holder) continue;
                        var count: usize = 0;
                        for (c[i..]) |cj| {
                            if (majorityEqual(cj.value, ci.value)) count += 1;
                        }
                        if (count > best_count) {
                            best_count = count;
                            win = i;
                        }
                    }
                },
            }
            winner = win;
        }

        var tc = json.Array.init(a);
        for (cands.items) |c| {
            try tc.append(try object(a, .{
                .{ "member", c.m.key },
                .{ "value", c.value },
                .{ "time_ms", c.m.last_time_ms },
                .{ "rank", self.pack.rank(c.m.source) },
            }));
        }
        const won: ?Won = if (winner) |i| .{ .value = cands.items[i].value, .from = cands.items[i].m.key } else null;
        try res.trace.append(try object(a, .{
            .{ "stage", "attribute" },
            .{ "group", g.name },
            .{ "key", attr.key },
            .{ "rule", @tagName(attr.rule) },
            .{ "candidates", json.Value{ .array = tc } },
            .{ "winner", if (won) |w| w.from else null },
            .{ "value", if (won) |w| w.value else json.Value.null },
        }));
        return won;
    }

    // ---- fuse.md "Snapshot" ---------------------------------------------------

    pub fn snapshot(self: *Engine) !json.Value {
        const a = self.alloc();
        var ents = json.ObjectMap.init(a);
        for (try self.sortedKeys()) |k| {
            const e = self.entities.get(k).?;
            try ents.put(k, try object(a, .{
                .{ "last_time_ms", e.last_time_ms },
                .{ "group", e.group },
                .{ "filter", try object(a, .{ .{ "east", try axisList(a, e.filter.east) }, .{ "north", try axisList(a, e.filter.north) } }) },
                .{ "report", json.Value{ .object = e.report } },
            }));
        }
        var ref: json.Value = .null;
        if (self.ref) |r| {
            var arr = json.Array.init(a);
            try arr.append(.{ .float = r.lat0 });
            try arr.append(.{ .float = r.lon0 });
            ref = .{ .array = arr };
        }
        return object(a, .{ .{ "ref", ref }, .{ "entities", json.Value{ .object = ents } } });
    }
};

fn axisList(a: Allocator, x: kalman.Axis) !json.Value {
    var arr = json.Array.init(a);
    for ([_]f64{ x.p, x.v, x.pp, x.pv, x.vv }) |v| try arr.append(.{ .float = v });
    return .{ .array = arr };
}

fn numberValue(v: json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch std.math.nan(f64),
        else => unreachable,
    };
}

// fuse.md "Attributes": equality for `majority`. Strings by bytes, numbers by
// value (`1` equals `1.0`), booleans by value; different kinds are never equal.
fn majorityEqual(x: json.Value, y: json.Value) bool {
    if (isNumber(x) and isNumber(y)) return numberValue(x) == numberValue(y);
    if (x == .string and y == .string) return std.mem.eql(u8, x.string, y.string);
    if (x == .bool and y == .bool) return x.bool == y.bool;
    return false;
}
