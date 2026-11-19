// spec/quality.md: the quality engine, operations `ingest`, `tick` and `snapshot`.
// Frame and filter are those of the correlate engine (correlate.md "Frame",
// "Track estimate"), reused from frame.zig and kalman.zig.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const frame = @import("frame.zig");
const kalman = @import("kalman.zig");
const reports = @import("entity.zig"); // correlate's typed key readers (spec "Reports")
const qpack = @import("quality_pack.zig");
const measures = @import("quality_measures.zig");
const Pack = qpack.Pack;
const Rule = qpack.Rule;
const Record = measures.Record;
const Order = measures.Order;
const Measures = measures.Measures;
const Num = measures.Num;

pub const load_pack = qpack.load;

pub const Result = struct {
    events: json.Array,
    trace: json.Array,
};

const Entity = struct {
    source: []const u8,
    // `last`: the entity's latest accepted time of a `first` or `advance` report.
    last_time_ms: i64,
    // `last_pos`: the plane position of that report, as reported.
    last_pos: frame.Plane,
    filter: kalman.Filter,
    window: std.ArrayList(Record),
};

// "Rules": per rule, per subject.
const RuleState = struct { count: i64, active: bool };

fn lessKey(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub const Engine = struct {
    arena: std.heap.ArenaAllocator,
    pack: Pack,
    ref: ?frame.Frame = null,
    last_tick: ?i64 = null,
    entities: std.StringArrayHashMap(Entity),
    // One map per rule, in pack order, from subject (entity key or source) to state.
    rule_states: []std.StringArrayHashMap(RuleState),

    pub fn create(backing: Allocator, pack: Pack) !*Engine {
        const self = try backing.create(Engine);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .pack = pack,
            .entities = undefined,
            .rule_states = undefined,
        };
        const a = self.arena.allocator();
        self.entities = std.StringArrayHashMap(Entity).init(a);
        self.rule_states = try a.alloc(std.StringArrayHashMap(RuleState), pack.rules.len);
        for (self.rule_states) |*m| m.* = std.StringArrayHashMap(RuleState).init(a);
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

    // ---- JSON output -------------------------------------------------------

    fn toValue(x: anytype) json.Value {
        const T = @TypeOf(x);
        if (T == json.Value) return x;
        if (T == bool) return .{ .bool = x };
        if (T == f64) return .{ .float = x };
        if (T == i64) return .{ .integer = x };
        if (T == Num) return switch (x) {
            .int => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
        };
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
    fn object(self: *Engine, fields: anytype) !json.Value {
        var m = json.ObjectMap.init(self.alloc());
        inline for (fields) |kv| try m.put(kv[0], toValue(kv[1]));
        return .{ .object = m };
    }

    fn list(self: *Engine, items: anytype) !json.Value {
        var arr = json.Array.init(self.alloc());
        inline for (items) |x| try arr.append(toValue(x));
        return .{ .array = arr };
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

    // The `measures` object of a `quality` event: every measure of the scope's table.
    fn measuresValue(self: *Engine, scope: qpack.Scope, m: Measures) !json.Value {
        var obj = json.ObjectMap.init(self.alloc());
        inline for (std.meta.fields(qpack.Measure)) |f| {
            const name: qpack.Measure = @enumFromInt(f.value);
            if (name.inScope(scope)) try obj.put(f.name, toValue(m.get(name)));
        }
        return .{ .object = obj };
    }

    fn sampleTrace(self: *Engine, res: *Result, key: []const u8, sample: []const u8, value: anytype, inputs: json.Value) !void {
        try res.trace.append(try self.object(.{
            .{ "stage", "sample" },
            .{ "entity", key },
            .{ "sample", sample },
            .{ "value", value },
            .{ "inputs", inputs },
        }));
    }

    // ---- ingest ------------------------------------------------------------

    // Spec "Ingest", operation `ingest(report)`.
    pub fn ingest(self: *Engine, report: json.ObjectMap) !Result {
        var res = Result{ .events = json.Array.init(self.alloc()), .trace = json.Array.init(self.alloc()) };
        const f = self.pack.filter;

        // "Reports": required keys, in the order of the table; a missing one rejects.
        const source_id = reports.stringOf(report, "track.source_id");
        const uid = reports.stringOf(report, "uid");
        const time_ms = reports.integerOf(report, "time_ms");
        const lat = reports.numberOf(report, "lat");
        const lon = reports.numberOf(report, "lon");
        const missing: ?[]const u8 = if (source_id == null) "track.source_id" else if (uid == null) "uid" else if (time_ms == null) "time_ms" else if (lat == null) "lat" else if (lon == null) "lon" else null;
        if (missing) |k| {
            const reason = try std.fmt.allocPrint(self.alloc(), "missing:{s}", .{k});
            try res.events.append(try self.object(.{ .{ "ev", "reject" }, .{ "reason", reason } }));
            return res;
        }
        const t = time_ms.?;
        const key = try std.fmt.allocPrint(self.alloc(), "{s}/{s}", .{ source_id.?, uid.? });

        // Optional keys: null, the wrong type, or a `ce` of 0 or below is absent.
        const ce_valid = reports.ceOf(report);
        const ce = ce_valid orelse f.default_ce_m;
        const course = reports.numberOf(report, "course");
        const speed_ms = reports.numberOf(report, "speed_ms");
        const hae = reports.numberOf(report, "hae");
        const received_ms = reports.integerOf(report, "received_ms");

        // "Frame and filter": the first accepted report, of any order, sets the reference.
        if (self.ref == null) self.ref = .{ .lat0 = lat.?, .lon0 = lon.? };
        const pos = self.ref.?.toPlane(lat.?, lon.?);

        // "Order".
        const existing = self.entities.getPtr(key);
        const last: ?i64 = if (existing) |e| e.last_time_ms else null;
        const order: Order = if (last == null) .first else if (t > last.?) .advance else if (t == last.?) .duplicate else .out_of_order;
        const wt = switch (order) {
            .first, .advance => t,
            .duplicate, .out_of_order => last.?,
        };
        try self.sampleTrace(&res, key, "order", order.name(), try self.list(.{ t, last }));

        // correlate.md "Track estimate": the velocity measurement.
        var vel: ?[2]f64 = null;
        if (course != null and speed_ms != null) {
            vel = .{ speed_ms.? * @sin(frame.rad(course.?)), speed_ms.? * @cos(frame.rad(course.?)) };
        }

        // "Samples", in the order `interval`, `latency`, `nis`, `speed_err`.
        var rec = Record{
            .wt = wt,
            .time_ms = t,
            .order = order,
            .interval = null,
            .latency = null,
            .nis = null,
            .speed_err = null,
            .ce = ce_valid != null,
            .vel = vel != null,
            .hae = hae != null,
        };
        if (order == .advance) {
            rec.interval = t - last.?;
            try self.sampleTrace(&res, key, "interval", rec.interval.?, try self.list(.{ t, last.? }));
        }
        if (received_ms) |rcv| {
            rec.latency = rcv - t;
            try self.sampleTrace(&res, key, "latency", rec.latency.?, try self.list(.{ rcv, t }));
        }
        var predicted: kalman.Filter = undefined;
        if (order == .advance) {
            const e = existing.?;
            const dt = @as(f64, @floatFromInt(t - last.?)) / 1000.0;
            // `nis`: predict to `t`, then the innovation against predicted plus reported variance.
            predicted = e.filter.predict(dt, f.accel_var);
            const r = ce * ce;
            const de = pos.east - predicted.east.p;
            const dn = pos.north - predicted.north.p;
            const se = predicted.east.pp + r;
            const sn = predicted.north.pp + r;
            rec.nis = de * de / se + dn * dn / sn;
            try self.sampleTrace(&res, key, "nis", rec.nis.?, try self.list(.{ de, dn, se, sn }));

            // `speed_err`: speed implied by the move from `last_pos`, against `speed_ms`.
            if (speed_ms) |sp| {
                const implied = std.math.hypot(pos.east - e.last_pos.east, pos.north - e.last_pos.north) / dt;
                rec.speed_err = @abs(implied - sp);
                try self.sampleTrace(&res, key, "speed_err", rec.speed_err.?, try self.list(.{ implied, sp }));
            }
        }

        // Create the entity, or update its filter, `last` and `last_pos` as the order says.
        switch (order) {
            .first => {
                var window = std.ArrayList(Record).init(self.alloc());
                try window.append(rec);
                try self.entities.put(key, .{
                    .source = try self.alloc().dupe(u8, source_id.?),
                    .last_time_ms = t,
                    .last_pos = pos,
                    .filter = .{
                        .east = kalman.Axis.init(pos.east, if (vel) |v| v[0] else null, ce, f.vel_sigma_ms, f.unknown_vel_ms),
                        .north = kalman.Axis.init(pos.north, if (vel) |v| v[1] else null, ce, f.vel_sigma_ms, f.unknown_vel_ms),
                    },
                    .window = window,
                });
                try res.events.append(try self.object(.{ .{ "ev", "new" }, .{ "entity", key } }));
            },
            .advance => {
                const e = existing.?;
                // correlate.md "Track estimate", steps 2 and 3 from the prediction above.
                var flt = predicted;
                flt.east = flt.east.updatePosition(pos.east, ce * ce);
                flt.north = flt.north.updatePosition(pos.north, ce * ce);
                if (vel) |v| {
                    const r = f.vel_sigma_ms * f.vel_sigma_ms;
                    flt.east = flt.east.updateVelocity(v[0], r);
                    flt.north = flt.north.updateVelocity(v[1], r);
                }
                e.filter = flt;
                e.last_time_ms = t;
                e.last_pos = pos;
                try e.window.append(rec);
            },
            .duplicate, .out_of_order => try existing.?.window.append(rec),
        }

        try self.forward(&res, key, report, ce_valid);
        return res;
    }

    // Spec "Forwarding": one `pass` event, changed by the actions in force.
    fn forward(self: *Engine, res: *Result, key: []const u8, report: json.ObjectMap, ce_valid: ?f64) !void {
        const source = self.entities.get(key).?.source;

        // "Actions in force": active entity rules for the entity, active source
        // rules for its source; `alert` changes nothing. Pack order.
        var rule_names = json.Array.init(self.alloc());
        var withheld = false;
        var factors = std.ArrayList(f64).init(self.alloc());
        var marks = std.ArrayList([]const u8).init(self.alloc());
        for (self.pack.rules, self.rule_states) |rule, states| {
            if (rule.action == .alert) continue;
            const subject = if (rule.scope == .entity) key else source;
            const st = states.get(subject) orelse continue;
            if (!st.active) continue;
            try rule_names.append(.{ .string = rule.name });
            switch (rule.action) {
                .drop => withheld = true,
                .downgrade => try factors.append(rule.factor.?),
                .mark => try marks.append(rule.name),
                .alert => unreachable,
            }
        }

        if (withheld) {
            try res.events.append(try self.object(.{
                .{ "ev", "pass" },
                .{ "entity", key },
                .{ "rules", json.Value{ .array = rule_names } },
                .{ "withheld", true },
            }));
            return;
        }

        // The report exactly as received, with `ce` and `quality.marks` changed.
        var out = (try self.cloneValue(.{ .object = report })).object;
        if (factors.items.len > 0) {
            // `x = x * factor` for each `downgrade` in pack order.
            var x = ce_valid orelse self.pack.filter.default_ce_m;
            for (factors.items) |factor| x = x * factor;
            try out.put("ce", .{ .float = x });
        }
        if (marks.items.len > 0) {
            var list_out = json.Array.init(self.alloc());
            if (out.get("quality.marks")) |received| {
                if (received == .array and allStrings(received.array)) {
                    for (received.array.items) |item| try list_out.append(item);
                }
            }
            for (marks.items) |m| {
                if (!holdsString(list_out, m)) try list_out.append(.{ .string = m });
            }
            try out.put("quality.marks", .{ .array = list_out });
        }
        try res.events.append(try self.object(.{
            .{ "ev", "pass" },
            .{ "entity", key },
            .{ "rules", json.Value{ .array = rule_names } },
            .{ "withheld", false },
            .{ "report", json.Value{ .object = out } },
        }));
    }

    fn allStrings(arr: json.Array) bool {
        for (arr.items) |item| if (item != .string) return false;
        return true;
    }

    fn holdsString(arr: json.Array, s: []const u8) bool {
        for (arr.items) |item| if (std.mem.eql(u8, item.string, s)) return true;
        return false;
    }

    // ---- tick --------------------------------------------------------------

    fn sortedEntityKeys(self: *Engine) ![][]const u8 {
        const keys = try self.alloc().dupe([]const u8, self.entities.keys());
        std.mem.sort([]const u8, keys, {}, lessKey);
        return keys;
    }

    // The sources that have at least one entity, in key order.
    fn sortedSources(self: *Engine) ![][]const u8 {
        var out = std.ArrayList([]const u8).init(self.alloc());
        for (self.entities.values()) |e| {
            for (out.items) |s| {
                if (std.mem.eql(u8, s, e.source)) break;
            } else try out.append(e.source);
        }
        std.mem.sort([]const u8, out.items, {}, lessKey);
        return out.items;
    }

    fn hasSource(self: *Engine, source: []const u8) bool {
        for (self.entities.values()) |e| if (std.mem.eql(u8, e.source, source)) return true;
        return false;
    }

    // Tick steps 2 and 3: ends each active rule of `scope` for `subject`, in
    // pack order, with reason `forget`, and removes every rule state for it.
    fn forgetSubject(self: *Engine, res: *Result, scope: qpack.Scope, subject: []const u8) !void {
        for (self.pack.rules, self.rule_states) |rule, *states| {
            if (rule.scope != scope) continue;
            const st = states.get(subject) orelse continue;
            if (st.active) {
                try res.events.append(try self.object(.{
                    .{ "ev", "action-end" },
                    .{ "rule", rule.name },
                    .{ "scope", @tagName(rule.scope) },
                    .{ "subject", subject },
                    .{ "action", @tagName(rule.action) },
                    .{ "reason", "forget" },
                    .{ "value", @as(json.Value, .null) },
                }));
            }
            _ = states.orderedRemove(subject);
        }
    }

    // Spec "Rules", evaluation, once for one rule and one subject.
    fn evaluate(self: *Engine, res: *Result, rule: Rule, states: *std.StringArrayHashMap(RuleState), subject: []const u8, m: Measures) !void {
        const gop = try states.getOrPut(subject);
        if (!gop.found_existing) gop.value_ptr.* = .{ .count = 0, .active = false };
        const st = gop.value_ptr;
        const value = m.get(rule.measure);
        const v: ?f64 = if (value) |x| x.toF64() else null;

        var shown_limit: f64 = undefined;
        var pass: bool = undefined;
        if (!st.active) {
            shown_limit = rule.limit;
            pass = v != null and rule.op.holds(v.?, rule.limit);
            st.count = if (pass) st.count + 1 else 0;
            if (st.count >= rule.for_n) {
                st.active = true;
                st.count = 0;
                try self.actionEvent(res, rule, subject, "action-start", null, value);
            }
        } else {
            shown_limit = rule.clear;
            pass = v != null and rule.op.clears(v.?, rule.clear);
            if (pass) {
                st.active = false;
                try self.actionEvent(res, rule, subject, "action-end", "clear", value);
            }
        }

        try res.trace.append(try self.object(.{
            .{ "stage", "rule" },
            .{ "rule", rule.name },
            .{ "subject", subject },
            .{ "measure", @tagName(rule.measure) },
            .{ "value", value },
            .{ "limit", shown_limit },
            .{ "pass", pass },
            .{ "count", st.count },
            .{ "active", st.active },
        }));
    }

    fn actionEvent(self: *Engine, res: *Result, rule: Rule, subject: []const u8, ev: []const u8, reason: ?[]const u8, value: ?Num) !void {
        var obj = (try self.object(.{
            .{ "ev", ev },
            .{ "rule", rule.name },
            .{ "scope", @tagName(rule.scope) },
            .{ "subject", subject },
            .{ "action", @tagName(rule.action) },
        })).object;
        if (reason) |r| try obj.put("reason", .{ .string = r });
        try obj.put("value", toValue(value));
        try res.events.append(.{ .object = obj });
    }

    fn qualityEvent(self: *Engine, res: *Result, scope: qpack.Scope, subject: []const u8, m: Measures) !void {
        try res.events.append(try self.object(.{
            .{ "ev", "quality" },
            .{ "scope", @tagName(scope) },
            .{ "subject", subject },
            .{ "measures", try self.measuresValue(scope, m) },
        }));
    }

    // Spec "Tick", operation `tick(now_ms)`.
    pub fn tick(self: *Engine, now_ms: i64) !Result {
        var res = Result{ .events = json.Array.init(self.alloc()), .trace = json.Array.init(self.alloc()) };
        const w = self.pack.window;

        // 1. Order.
        if (self.last_tick) |prev| {
            if (now_ms < prev) {
                try res.events.append(try self.object(.{ .{ "ev", "reject" }, .{ "reason", "tick-out-of-order" } }));
                return res;
            }
        }
        self.last_tick = now_ms;
        const sources_at_start = try self.sortedSources();

        // 2. Forget entities, key order.
        for (try self.sortedEntityKeys()) |key| {
            if (now_ms - self.entities.get(key).?.last_time_ms <= w.forget_ms) continue;
            try self.forgetSubject(&res, .entity, key);
            _ = self.entities.orderedRemove(key);
            try res.events.append(try self.object(.{ .{ "ev", "forget" }, .{ "entity", key } }));
        }

        // 3. Forget sources that had entities at the start of the tick and have none now.
        for (sources_at_start) |source| {
            if (self.hasSource(source)) continue;
            try self.forgetSubject(&res, .source, source);
            try res.events.append(try self.object(.{ .{ "ev", "forget" }, .{ "source", source } }));
        }

        // 4. Window.
        var largest_window: usize = 0;
        for (self.entities.values()) |*e| {
            measures.dropOld(&e.window, now_ms, w.window_ms);
            largest_window = @max(largest_window, e.window.items.len);
        }
        const buf = try self.alloc().alloc(f64, @max(largest_window, self.entities.count()));

        // 5. Entities, key order: measures, `quality`, entity rules in pack order.
        const keys = try self.sortedEntityKeys();
        const entity_measures = try self.alloc().alloc(Measures, keys.len);
        for (keys, entity_measures) |key, *m| {
            const e = self.entities.get(key).?;
            m.* = measures.entityMeasures(buf, e.window.items, w.min_samples, now_ms, e.last_time_ms);
            try self.qualityEvent(&res, .entity, key, m.*);
            for (self.pack.rules, self.rule_states) |rule, *states| {
                if (rule.scope == .entity) try self.evaluate(&res, rule, states, key, m.*);
            }
        }

        // 6. Sources, key order: aggregate their entities' measures from step 5.
        var of_source = std.ArrayList(Measures).init(self.alloc());
        for (try self.sortedSources()) |source| {
            of_source.clearRetainingCapacity();
            for (keys, entity_measures) |key, m| {
                if (std.mem.eql(u8, self.entities.get(key).?.source, source)) try of_source.append(m);
            }
            const m = measures.sourceMeasures(buf, of_source.items);
            try self.qualityEvent(&res, .source, source, m);
            for (self.pack.rules, self.rule_states) |rule, *states| {
                if (rule.scope == .source) try self.evaluate(&res, rule, states, source, m);
            }
        }
        return res;
    }

    // ---- snapshot ----------------------------------------------------------

    fn axisValue(self: *Engine, a: kalman.Axis) !json.Value {
        return self.list(.{ a.p, a.v, a.pp, a.pv, a.vv });
    }

    fn recordValue(self: *Engine, r: Record) !json.Value {
        return self.object(.{
            .{ "wt", r.wt },
            .{ "time_ms", r.time_ms },
            .{ "order", r.order.name() },
            .{ "interval", r.interval },
            .{ "latency", r.latency },
            .{ "nis", r.nis },
            .{ "speed_err", r.speed_err },
            .{ "ce", r.ce },
            .{ "vel", r.vel },
            .{ "hae", r.hae },
        });
    }

    // Spec "Snapshot", operation `snapshot()`.
    pub fn snapshot(self: *Engine) !json.Value {
        const a = self.alloc();
        var entities = json.ObjectMap.init(a);
        for (try self.sortedEntityKeys()) |key| {
            const e = self.entities.get(key).?;
            var window = json.Array.init(a);
            for (e.window.items) |r| try window.append(try self.recordValue(r));
            try entities.put(key, try self.object(.{
                .{ "source", e.source },
                .{ "last_time_ms", e.last_time_ms },
                .{ "last_pos", try self.list(.{ e.last_pos.east, e.last_pos.north }) },
                .{ "filter", try self.object(.{ .{ "east", try self.axisValue(e.filter.east) }, .{ "north", try self.axisValue(e.filter.north) } }) },
                .{ "window", json.Value{ .array = window } },
            }));
        }

        var rules = json.ObjectMap.init(a);
        for (self.pack.rules, self.rule_states) |rule, states| {
            var by_subject = json.ObjectMap.init(a);
            const subjects = try a.dupe([]const u8, states.keys());
            std.mem.sort([]const u8, subjects, {}, lessKey);
            for (subjects) |s| {
                const st = states.get(s).?;
                try by_subject.put(s, try self.object(.{ .{ "count", st.count }, .{ "active", st.active } }));
            }
            try rules.put(rule.name, .{ .object = by_subject });
        }

        const ref: json.Value = if (self.ref) |r| try self.list(.{ r.lat0, r.lon0 }) else .null;
        return self.object(.{
            .{ "ref", ref },
            .{ "last_tick", self.last_tick },
            .{ "entities", json.Value{ .object = entities } },
            .{ "rules", json.Value{ .object = rules } },
        });
    }
};
