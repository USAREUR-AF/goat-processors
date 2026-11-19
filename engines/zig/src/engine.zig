// Spec "What the correlator does": the four operations.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const pack_mod = @import("pack.zig");
const frame = @import("frame.zig");
const kalman = @import("kalman.zig");
const imm = @import("imm.zig");
const entity_mod = @import("entity.zig");
const pair_tests = @import("pair_tests.zig");
const assign = @import("assign.zig");
const Entity = entity_mod.Entity;
const Pack = pack_mod.Pack;

pub const load_pack = pack_mod.load;

pub const Result = struct {
    events: json.Array,
    trace: json.Array,
};

pub const Group = struct {
    id: u64,
    members: std.ArrayList([]const u8),
};

const PairCount = struct { a: []const u8, b: []const u8, count: i64 };

pub const Stage = enum { gate, confirm, hold, rank };

pub fn lessKey(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub const Engine = struct {
    arena: std.heap.ArenaAllocator,
    pack: Pack,
    ref: ?frame.Frame = null,
    entities: std.StringArrayHashMap(Entity),
    groups: std.ArrayList(Group),
    counts: std.ArrayList(PairCount),
    next_group: u64 = 1,
    // correlate-assign.md: `reported` holds the entities with an accepted report
    // since the previous tick; `assign_state` the memberships and histories.
    reported: std.StringArrayHashMap(void),
    assign_state: assign.State,

    pub fn create(backing: Allocator, pack: Pack) !*Engine {
        const self = try backing.create(Engine);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .pack = pack,
            .entities = undefined,
            .groups = undefined,
            .counts = undefined,
            .reported = undefined,
            .assign_state = undefined,
        };
        const a = self.arena.allocator();
        self.entities = std.StringArrayHashMap(Entity).init(a);
        self.groups = std.ArrayList(Group).init(a);
        self.counts = std.ArrayList(PairCount).init(a);
        self.reported = std.StringArrayHashMap(void).init(a);
        self.assign_state = try assign.State.init(a);
        return self;
    }

    pub fn destroy(self: *Engine) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }

    pub fn alloc(self: *Engine) Allocator {
        return self.arena.allocator();
    }

    // ---- output records ----------------------------------------------------

    fn toValue(self: *Engine, x: anytype) json.Value {
        const T = @TypeOf(x);
        if (T == json.Value) return x;
        if (T == bool) return .{ .bool = x };
        if (T == f64 or T == comptime_float) return .{ .float = x };
        if (T == i64 or T == u64 or T == comptime_int) return .{ .integer = @intCast(x) };
        switch (@typeInfo(T)) {
            .Pointer => |p| {
                if (p.size == .Slice and p.child == u8) return .{ .string = x };
                if (p.size == .One and @typeInfo(p.child) == .Array) return .{ .string = x };
            },
            .Optional => return if (x) |v| self.toValue(v) else .null,
            else => {},
        }
        @compileError("unsupported value type " ++ @typeName(T));
    }

    // `fields` is a tuple of .{ name, value } pairs, kept in that order.
    pub fn object(self: *Engine, fields: anytype) !json.Value {
        var m = json.ObjectMap.init(self.alloc());
        inline for (fields) |kv| try m.put(kv[0], self.toValue(kv[1]));
        return .{ .object = m };
    }

    pub fn stringList(self: *Engine, items: []const []const u8) !json.Value {
        var arr = json.Array.init(self.alloc());
        for (items) |s| try arr.append(.{ .string = s });
        return .{ .array = arr };
    }

    pub fn groupName(self: *Engine, id: u64) ![]const u8 {
        const prefix = if (self.pack.method == .assign) "s" else "g";
        return std.fmt.allocPrint(self.alloc(), "{s}{d}", .{ prefix, id });
    }

    // ---- state helpers -----------------------------------------------------

    pub fn sortedKeys(self: *Engine) ![][]const u8 {
        const keys = try self.alloc().dupe([]const u8, self.entities.keys());
        std.mem.sort([]const u8, keys, {}, lessKey);
        return keys;
    }

    pub fn groupIndex(self: *Engine, id: u64) usize {
        for (self.groups.items, 0..) |g, i| if (g.id == id) return i;
        unreachable;
    }

    pub fn insertSorted(list: *std.ArrayList([]const u8), key: []const u8) !void {
        var i: usize = 0;
        while (i < list.items.len and lessKey({}, list.items[i], key)) i += 1;
        try list.insert(i, key);
    }

    fn pairCount(self: *Engine, x: []const u8, y: []const u8) *PairCount {
        const a, const b = if (lessKey({}, x, y)) .{ x, y } else .{ y, x };
        for (self.counts.items) |*pc| {
            if (std.mem.eql(u8, pc.a, a) and std.mem.eql(u8, pc.b, b)) return pc;
        }
        self.counts.append(.{ .a = a, .b = b, .count = 0 }) catch @panic("out of memory");
        return &self.counts.items[self.counts.items.len - 1];
    }

    fn cloneValue(self: *Engine, v: json.Value) !json.Value {
        const a = self.alloc();
        return switch (v) {
            .null, .bool, .integer, .float => v,
            .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
            .string => |s| .{ .string = try a.dupe(u8, s) },
            .array => |arr| blk: {
                var out = json.Array.init(a);
                for (arr.items) |item| try out.append(try self.cloneValue(item));
                break :blk .{ .array = out };
            },
            .object => |obj| blk: {
                var out = json.ObjectMap.init(a);
                var it = obj.iterator();
                while (it.next()) |e| try out.put(try a.dupe(u8, e.key_ptr.*), try self.cloneValue(e.value_ptr.*));
                break :blk .{ .object = out };
            },
        };
    }

    // ---- ingest ------------------------------------------------------------

    // Spec operation `ingest(report)`.
    pub fn ingest(self: *Engine, report: json.ObjectMap) !Result {
        var res = Result{ .events = json.Array.init(self.alloc()), .trace = json.Array.init(self.alloc()) };

        // Spec "Reports": required keys, in the order of the table.
        const source = entity_mod.stringOf(report, "track.source_id");
        const uid = entity_mod.stringOf(report, "uid");
        const time_ms = entity_mod.integerOf(report, "time_ms");
        const lat = entity_mod.numberOf(report, "lat");
        const lon = entity_mod.numberOf(report, "lon");
        const missing: ?[]const u8 = if (source == null) "track.source_id" else if (uid == null) "uid" else if (time_ms == null) "time_ms" else if (lat == null) "lat" else if (lon == null) "lon" else null;
        if (missing) |k| {
            const reason = try std.fmt.allocPrint(self.alloc(), "missing:{s}", .{k});
            try res.events.append(try self.object(.{ .{ "ev", "reject" }, .{ "reason", reason } }));
            return res;
        }

        const key = try std.fmt.allocPrint(self.alloc(), "{s}/{s}", .{ source.?, uid.? });
        // correlate-assign.md "Window": after the required keys, before out-of-order.
        if (self.pack.method == .assign and assign.isRetiring(self, key)) {
            try res.events.append(try self.object(.{ .{ "ev", "reject" }, .{ "entity", key }, .{ "reason", "retiring" } }));
            return res;
        }
        if (self.entities.get(key)) |existing| {
            if (time_ms.? < existing.last_time_ms) {
                try res.events.append(try self.object(.{ .{ "ev", "reject" }, .{ "entity", key }, .{ "reason", "out-of-order" } }));
                return res;
            }
        }

        // Spec "Frame": the first accepted report fixes the reference.
        if (self.ref == null) self.ref = .{ .lat0 = lat.?, .lon0 = lon.? };
        const stored = (try self.cloneValue(.{ .object = report })).object;
        const pos = self.ref.?.toPlane(lat.?, lon.?);
        const f = self.pack.filter;
        const ce = entity_mod.ceOf(stored) orelse f.default_ce_m;

        // Spec "Track estimate": velocity measurement.
        var meas = kalman.Measurement{ .east = pos.east, .north = pos.north, .r_pos = ce * ce, .r_vel = f.vel_sigma_ms * f.vel_sigma_ms };
        if (entity_mod.numberOf(stored, "course")) |course| {
            if (entity_mod.numberOf(stored, "speed_ms")) |speed| {
                meas.vel = .{ .east = speed * @sin(frame.rad(course)), .north = speed * @cos(frame.rad(course)) };
            }
        }

        const gop = try self.entities.getOrPut(key);
        if (!gop.found_existing) {
            // First report.
            const ve: ?f64 = if (meas.vel) |v| v.east else null;
            const vn: ?f64 = if (meas.vel) |v| v.north else null;
            const first = kalman.Filter{
                .east = kalman.Axis.init(pos.east, ve, ce, f.vel_sigma_ms, f.unknown_vel_ms),
                .north = kalman.Axis.init(pos.north, vn, ce, f.vel_sigma_ms, f.unknown_vel_ms),
            };
            gop.value_ptr.* = .{
                .key = key,
                .source = entity_mod.stringOf(stored, "track.source_id").?,
                .last_time_ms = time_ms.?,
                .report = stored,
                .filter = first,
                .imm = if (self.pack.maneuver) |m| imm.init(m, first) else null,
                .group = null,
                .hold_failures = 0,
            };
            try res.events.append(try self.object(.{ .{ "ev", "new" }, .{ "entity", key } }));
        } else {
            const e = gop.value_ptr;
            const dt = @as(f64, @floatFromInt(time_ms.? - e.last_time_ms)) / 1000.0;
            if (e.imm) |st| {
                // Spec "Two-model filter", later reports: steps 1 to 5, then the four filter records.
                const step = imm.update(st, self.pack.maneuver.?, f.accel_var, dt, meas);
                e.imm = step.state;
                e.filter = imm.combined(step.state);
                for (0..2) |j| try self.filterRecord(&res, key, imm.model_names[j], "likelihood", step.lambda[j]);
                for (0..2) |j| try self.filterRecord(&res, key, imm.model_names[j], "mode", step.state.mu[j]);
            } else {
                // Spec "Track estimate", later reports: predict, position update, velocity update.
                e.filter = e.filter.predict(dt, f.accel_var).update(meas).filter;
            }
            e.last_time_ms = time_ms.?;
            e.report = stored;
        }

        const a_key = self.entities.getPtr(key).?.key;
        // correlate-assign.md: a report gives only `new` or `reject`; the tick decides.
        if (self.pack.method == .assign) {
            try self.reported.put(a_key, {});
            return res;
        }
        if (self.entities.get(a_key).?.group) |gid| {
            try self.hold(&res, a_key, gid);
        } else {
            try self.associate(&res, a_key);
        }
        return res;
    }

    fn filterRecord(self: *Engine, res: *Result, key: []const u8, model: []const u8, test_name: []const u8, value: f64) !void {
        try res.trace.append(try self.object(.{
            .{ "stage", "filter" },
            .{ "a", key },
            .{ "b", model },
            .{ "test", test_name },
            .{ "value", value },
            .{ "limit", json.Value{ .null = {} } },
            .{ "pass", true },
        }));
    }

    // Runs `tests` between A and B in order, stopping at the first failure.
    pub fn runTests(self: *Engine, res: *Result, stage: Stage, tests: []const pack_mod.Test, a_key: []const u8, b_key: []const u8) !bool {
        const a = self.entities.get(a_key).?;
        const b = self.entities.get(b_key).?;
        const b_pred = b.predictedTo(a.last_time_ms, self.pack);
        for (tests) |t| {
            const o = pair_tests.run(t, a, b, b_pred, self.pack.filter);
            var rec = try self.object(.{
                .{ "stage", @tagName(stage) },
                .{ "a", a_key },
                .{ "b", b_key },
                .{ "test", @tagName(t) },
                .{ "value", o.value },
                .{ "limit", o.limit },
                .{ "pass", o.pass },
            });
            if (o.skipped) try rec.object.put("skipped", .{ .bool = true });
            try res.trace.append(rec);
            if (!o.pass) return false;
        }
        return true;
    }

    // Spec "Association": A is in a group G, hold.
    fn hold(self: *Engine, res: *Result, a_key: []const u8, gid: u64) !void {
        const g = self.groups.items[self.groupIndex(gid)];
        const others = try self.alloc().dupe([]const u8, g.members.items);
        var any_pass = false;
        for (others) |m| {
            if (std.mem.eql(u8, m, a_key)) continue;
            // Spec 0.2: the hold passes at the first passing member; no later member is tested.
            if (try self.runTests(res, .hold, self.pack.hold, a_key, m)) {
                any_pass = true;
                break;
            }
        }
        const a = self.entities.getPtr(a_key).?;
        if (any_pass) {
            a.hold_failures = 0;
        } else {
            a.hold_failures += 1;
            if (a.hold_failures >= self.pack.hold_failures) {
                a.hold_failures = 0;
                try self.leave(res, a_key, "hold");
            }
        }
    }

    // `leave`, then `dissolve` when one member is left.
    fn leave(self: *Engine, res: *Result, key: []const u8, reason: []const u8) !void {
        const e = self.entities.getPtr(key).?;
        const gid = e.group.?;
        e.group = null;
        const gi = self.groupIndex(gid);
        const g = &self.groups.items[gi];
        for (g.members.items, 0..) |m, i| {
            if (std.mem.eql(u8, m, key)) {
                _ = g.members.orderedRemove(i);
                break;
            }
        }
        const name = try self.groupName(gid);
        try res.events.append(try self.object(.{ .{ "ev", "leave" }, .{ "group", name }, .{ "entity", key }, .{ "reason", reason } }));
        if (g.members.items.len == 1) {
            const last = g.members.items[0];
            const rest = self.entities.getPtr(last).?;
            rest.group = null;
            rest.hold_failures = 0;
            _ = self.groups.orderedRemove(gi);
            try res.events.append(try self.object(.{ .{ "ev", "dissolve" }, .{ "group", name }, .{ "entity", last } }));
        }
    }

    fn groupHoldsSource(self: *Engine, gid: u64, source: []const u8) bool {
        for (self.groups.items[self.groupIndex(gid)].members.items) |m| {
            if (std.mem.eql(u8, self.entities.get(m).?.source, source)) return true;
        }
        return false;
    }

    // Spec "Association": A is not in a group, associate.
    fn associate(self: *Engine, res: *Result, a_key: []const u8) !void {
        const a = self.entities.get(a_key).?;
        var reached = std.ArrayList([]const u8).init(self.alloc());

        for (try self.sortedKeys()) |b_key| {
            if (std.mem.eql(u8, b_key, a_key)) continue;
            const b = self.entities.get(b_key).?;
            if (!self.pack.same_source_allow) {
                if (std.mem.eql(u8, b.source, a.source)) continue;
                if (b.group) |bg| if (self.groupHoldsSource(bg, a.source)) continue;
            }
            var ok = try self.runTests(res, .gate, self.pack.gate, a_key, b_key);
            if (ok) ok = try self.runTests(res, .confirm, self.pack.confirm, a_key, b_key);
            const pc = self.pairCount(a_key, b_key);
            pc.count = if (ok) pc.count + 1 else 0;
            const done = pc.count >= self.pack.confirm_count;
            try res.trace.append(try self.object(.{
                .{ "stage", "confirm" },
                .{ "a", a_key },
                .{ "b", b_key },
                .{ "test", "count" },
                .{ "value", pc.count },
                .{ "limit", self.pack.confirm_count },
                .{ "pass", done },
            }));
            if (done) try reached.append(b_key);
        }

        // Smallest `d²` among those reaching `confirm_count`, ties to key order.
        var chosen: ?[]const u8 = null;
        var best: f64 = 0;
        for (reached.items) |b_key| {
            const b = self.entities.get(b_key).?;
            const d2 = pair_tests.mahalanobis(a, b.predictedTo(a.last_time_ms, self.pack), self.pack.filter.default_ce_m);
            try res.trace.append(try self.object(.{
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
        const b = self.entities.getPtr(b_key).?;
        if (b.group) |gid| {
            const g = &self.groups.items[self.groupIndex(gid)];
            try insertSorted(&g.members, a_key);
            self.entities.getPtr(a_key).?.group = gid;
            try res.events.append(try self.object(.{ .{ "ev", "join" }, .{ "group", try self.groupName(gid) }, .{ "entity", a_key } }));
        } else {
            const gid = self.next_group;
            self.next_group += 1;
            var members = std.ArrayList([]const u8).init(self.alloc());
            try insertSorted(&members, a_key);
            try insertSorted(&members, b_key);
            try self.groups.append(.{ .id = gid, .members = members });
            b.group = gid;
            self.entities.getPtr(a_key).?.group = gid;
            try res.events.append(try self.object(.{ .{ "ev", "correlate" }, .{ "group", try self.groupName(gid) }, .{ "members", try self.stringList(members.items) } }));
        }
        self.pairCount(a_key, b_key).count = 0;
    }

    // ---- tick --------------------------------------------------------------

    // Spec operation `tick(now_ms)`.
    pub fn tick(self: *Engine, now_ms: i64) !Result {
        if (self.pack.method == .assign) return assign.tick(self, now_ms);
        var res = Result{ .events = json.Array.init(self.alloc()), .trace = json.Array.init(self.alloc()) };

        // 1. Staleness, entities in key order.
        for (try self.sortedKeys()) |key| {
            const e = self.entities.get(key).?;
            const own_stale = if (e.integer("stale_ms")) |s| now_ms >= s else false;
            if (!(now_ms - e.last_time_ms > self.pack.stale_ms or own_stale)) continue;
            if (e.group != null) try self.leave(&res, key, "stale");
            _ = self.entities.orderedRemove(key);
            var i: usize = 0;
            while (i < self.counts.items.len) {
                const pc = self.counts.items[i];
                if (std.mem.eql(u8, pc.a, key) or std.mem.eql(u8, pc.b, key)) {
                    _ = self.counts.orderedRemove(i);
                } else i += 1;
            }
            try res.events.append(try self.object(.{ .{ "ev", "drop" }, .{ "entity", key } }));
        }

        // 2. Fused output, groups in creation order.
        for (self.groups.items) |g| {
            const primary = self.primaryOf(g);
            const p = self.entities.get(primary).?;
            const flt = p.predictedTo(now_ms, self.pack);
            const pos = self.ref.?.toDegrees(.{ .east = flt.east.p, .north = flt.north.p });
            var course = frame.deg(std.math.atan2(flt.east.v, flt.north.v));
            if (course < 0) course += 360.0;
            if (course >= 360.0) course -= 360.0;
            var ev = try self.object(.{
                .{ "ev", "fused" },
                .{ "group", try self.groupName(g.id) },
                .{ "primary", primary },
                .{ "members", try self.stringList(g.members.items) },
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
    fn primaryOf(self: *Engine, g: Group) []const u8 {
        var best = g.members.items[0];
        for (g.members.items[1..]) |m| {
            const cand = self.entities.get(m).?;
            const cur = self.entities.get(best).?;
            const better = switch (self.pack.output) {
                .priority => self.pack.priorityOf(cand.source) < self.pack.priorityOf(cur.source),
                .latest => cand.last_time_ms > cur.last_time_ms,
            };
            if (better) best = m;
        }
        return best;
    }

    // ---- snapshot ----------------------------------------------------------

    pub fn axisValue(self: *Engine, a: kalman.Axis) !json.Value {
        var arr = json.Array.init(self.alloc());
        for ([_]f64{ a.p, a.v, a.pp, a.pv, a.vv }) |x| try arr.append(.{ .float = x });
        return .{ .array = arr };
    }

    // Spec "Snapshot": `filter`, plus `models` and `mode` with the `maneuver` directive.
    pub fn putFilter(self: *Engine, obj: *json.ObjectMap, e: Entity) !void {
        try obj.put("filter", try self.filterValue(e.filter));
        if (e.imm) |st| {
            try obj.put("models", try self.object(.{
                .{ "quiet", try self.filterValue(st.models[0]) },
                .{ "maneuver", try self.filterValue(st.models[1]) },
            }));
            var mode = json.Array.init(self.alloc());
            try mode.append(.{ .float = st.mu[0] });
            try mode.append(.{ .float = st.mu[1] });
            try obj.put("mode", .{ .array = mode });
        }
    }

    fn filterValue(self: *Engine, f: kalman.Filter) !json.Value {
        return self.object(.{ .{ "east", try self.axisValue(f.east) }, .{ "north", try self.axisValue(f.north) } });
    }

    // Spec operation `snapshot()`.
    pub fn snapshot(self: *Engine) !json.Value {
        if (self.pack.method == .assign) return assign.snapshot(self);
        var ref: json.Value = .null;
        if (self.ref) |r| {
            var arr = json.Array.init(self.alloc());
            try arr.append(.{ .float = r.lat0 });
            try arr.append(.{ .float = r.lon0 });
            ref = .{ .array = arr };
        }

        var entities = json.ObjectMap.init(self.alloc());
        for (try self.sortedKeys()) |key| {
            const e = self.entities.get(key).?;
            const group: ?[]const u8 = if (e.group) |gid| try self.groupName(gid) else null;
            var obj = try self.object(.{
                .{ "last_time_ms", e.last_time_ms },
                .{ "group", group },
                .{ "hold_failures", e.hold_failures },
            });
            try self.putFilter(&obj.object, e);
            try entities.put(key, obj);
        }

        var groups = json.ObjectMap.init(self.alloc());
        for (self.groups.items) |g| try groups.put(try self.groupName(g.id), try self.stringList(g.members.items));

        var counts = json.ObjectMap.init(self.alloc());
        for (self.counts.items) |pc| {
            try counts.put(try std.fmt.allocPrint(self.alloc(), "{s}|{s}", .{ pc.a, pc.b }), .{ .integer = pc.count });
        }

        return self.object(.{
            .{ "ref", ref },
            .{ "entities", json.Value{ .object = entities } },
            .{ "groups", json.Value{ .object = groups } },
            .{ "counts", json.Value{ .object = counts } },
            .{ "next_group", self.next_group },
        });
    }
};
