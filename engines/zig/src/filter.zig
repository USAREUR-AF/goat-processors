// spec/filter.md: the filter engine and its four operations.
// Section names in comments are those of spec/filter.md.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const fpack = @import("filter_pack.zig");
const geo = @import("filter_geo.zig");
// "Reports" cites the Reports section of correlate.md; the key readers are the
// correlate engine's own.
const report_keys = @import("entity.zig");

pub const Pack = fpack.Pack;
pub const load_pack = fpack.load;

pub const Result = struct {
    events: json.Array,
    trace: json.Array,
};

// "Snapshot": the stored state of one entity.
pub const State = struct {
    time_ms: i64,
    lat: f64,
    lon: f64,
    course: ?f64,
    speed_ms: ?f64,
    stale_ms: ?i64,
    kept_ms: ?i64,
};

// A report that passed the required-key checks of "Reports".
const Report = struct {
    map: json.ObjectMap,
    key: []const u8,
    source: []const u8,
    uid: []const u8,
    time_ms: i64,
    lat: f64,
    lon: f64,
};

// "Conditions": true (yes), false (no) or unknown.
const Truth = enum { yes, no, unknown };

fn truth(b: bool) Truth {
    return if (b) .yes else .no;
}

// One evaluated condition: its result before `not`, and the trace `value`/`limit`.
const Outcome = struct { result: Truth, value: json.Value, limit: json.Value };

fn lessKey(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// An integer for the trace; differences of two int64 are computed in i128.
fn intValue(x: i128) json.Value {
    if (std.math.cast(i64, x)) |i| return .{ .integer = i };
    return .{ .float = @floatFromInt(x) };
}

fn optFloat(x: ?f64) json.Value {
    return if (x) |v| .{ .float = v } else .null;
}

fn optInt(x: ?i64) json.Value {
    return if (x) |v| .{ .integer = v } else .null;
}

fn asNumber(v: json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

// "Reports": the environment, the third `-`-separated element of `type`.
fn environment(type_: ?[]const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, type_ orelse return null, '-');
    _ = parts.next();
    _ = parts.next() orelse return null;
    return parts.next();
}

// "Reports": the affiliation, the second element when the first is exactly `a`.
fn affiliation(type_: ?[]const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, type_ orelse return null, '-');
    const first = parts.next().?;
    if (!std.mem.eql(u8, first, "a")) return null;
    return parts.next();
}

// "Absent and present": the report's value of key `name` after the
// optional-key rules of Reports, or null when absent.
fn present(m: json.ObjectMap, name: []const u8) ?json.Value {
    const v = m.get(name) orelse return null;
    if (v == .null) return null;
    const eql = std.mem.eql;
    if (eql(u8, name, "hae") or eql(u8, name, "course") or eql(u8, name, "speed_ms")) {
        if (report_keys.numberOf(m, name) == null) return null;
    } else if (eql(u8, name, "ce")) {
        if (report_keys.ceOf(m) == null) return null;
    } else if (eql(u8, name, "type")) {
        if (report_keys.stringOf(m, name) == null) return null;
    } else if (eql(u8, name, "stale_ms")) {
        if (report_keys.integerOf(m, name) == null) return null;
    }
    return v;
}

// "`key` equality" between a report value and a pack text.
fn keyEquals(v: json.Value, t: fpack.Text) bool {
    return switch (v) {
        .string => |s| std.mem.eql(u8, s, t.text),
        .integer, .float, .number_string => if (t.number) |n| asNumber(v) == n else false,
        .bool => |b| std.mem.eql(u8, t.text, if (b) "true" else "false"),
        else => false,
    };
}

fn inRange(x: f64, r: fpack.Range) bool {
    if (r.min) |lo| if (x < lo) return false;
    if (r.max) |hi| if (x > hi) return false;
    return true;
}

pub const Engine = struct {
    arena: std.heap.ArenaAllocator,
    pack: Pack,
    entities: std.StringArrayHashMap(State),

    pub fn create(backing: Allocator, pack: Pack) !*Engine {
        const self = try backing.create(Engine);
        self.* = .{ .arena = std.heap.ArenaAllocator.init(backing), .pack = pack, .entities = undefined };
        self.entities = std.StringArrayHashMap(State).init(self.arena.allocator());
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

    fn object(self: *Engine, fields: anytype) !json.Value {
        var m = json.ObjectMap.init(self.alloc());
        inline for (fields) |kv| try m.put(kv[0], kv[1]);
        return .{ .object = m };
    }

    fn str(s: []const u8) json.Value {
        return .{ .string = s };
    }

    fn stringList(self: *Engine, items: []const []const u8) !json.Value {
        var arr = json.Array.init(self.alloc());
        for (items) |s| try arr.append(str(s));
        return .{ .array = arr };
    }

    fn textList(self: *Engine, items: []const fpack.Text) !json.Value {
        var arr = json.Array.init(self.alloc());
        for (items) |t| try arr.append(str(t.text));
        return .{ .array = arr };
    }

    fn rangeLimit(self: *Engine, r: fpack.Range) !json.Value {
        var arr = json.Array.init(self.alloc());
        try arr.append(optFloat(r.min));
        try arr.append(optFloat(r.max));
        return .{ .array = arr };
    }

    fn sortedKeys(self: *Engine) ![][]const u8 {
        const keys = try self.alloc().dupe([]const u8, self.entities.keys());
        std.mem.sort([]const u8, keys, {}, lessKey);
        return keys;
    }

    // ---- ingest --------------------------------------------------------------

    // Operation `ingest(report)`: one event and the trace for that report.
    pub fn ingest(self: *Engine, map: json.ObjectMap) !Result {
        var res = self.newResult();

        // "Reports": required keys, checked in the order of correlate.md's table.
        const source = report_keys.stringOf(map, "track.source_id");
        const uid = report_keys.stringOf(map, "uid");
        const time_ms = report_keys.integerOf(map, "time_ms");
        const lat = report_keys.numberOf(map, "lat");
        const lon = report_keys.numberOf(map, "lon");
        const missing: ?[]const u8 = if (source == null) "track.source_id" else if (uid == null) "uid" else if (time_ms == null) "time_ms" else if (lat == null) "lat" else if (lon == null) "lon" else null;
        if (missing) |k| {
            // A rejected report gives no trace and changes no state.
            const reason = try std.fmt.allocPrint(self.alloc(), "missing:{s}", .{k});
            try res.events.append(try self.object(.{ .{ "ev", str("reject") }, .{ "reason", str(reason) } }));
            return res;
        }
        const r = Report{
            .map = map,
            .key = try std.fmt.allocPrint(self.alloc(), "{s}/{s}", .{ source.?, uid.? }),
            .source = source.?,
            .uid = uid.?,
            .time_ms = time_ms.?,
            .lat = lat.?,
            .lon = lon.?,
        };

        // "Rules" 1 and 2: the first matching rule decides, else `default`.
        var action = self.pack.default;
        var rule_name: []const u8 = "default";
        for (self.pack.rules) |rule| {
            if (try self.ruleMatches(&res, rule, r)) {
                action = rule.action;
                rule_name = rule.name;
                break;
            }
        }

        // "Rules" 3: one event.
        try res.events.append(try self.object(.{
            .{ "ev", str(@tagName(action)) },
            .{ "entity", str(r.key) },
            .{ "rule", str(rule_name) },
        }));

        // "Rules" 4: state, after the decision.
        try self.updateState(r, action == .keep);
        return res;
    }

    // "Rules" 1: conditions in pack order; the first that does not pass ends the rule.
    fn ruleMatches(self: *Engine, res: *Result, rule: fpack.Rule, r: Report) !bool {
        for (rule.conditions) |w| {
            const o = try self.evaluate(w.condition, r);
            // "Conditions": `not` swaps true and false; unknown never passes.
            const pass = switch (o.result) {
                .yes => !w.negated,
                .no => w.negated,
                .unknown => false,
            };
            var rec = try self.object(.{
                .{ "stage", str("rule") },
                .{ "rule", str(rule.name) },
                .{ "entity", str(r.key) },
                .{ "test", str(@tagName(w.condition)) },
                .{ "negated", json.Value{ .bool = w.negated } },
                .{ "value", o.value },
                .{ "limit", o.limit },
                .{ "pass", json.Value{ .bool = pass } },
            });
            if (o.result == .unknown) try rec.object.put("unknown", .{ .bool = true });
            try res.trace.append(rec);
            if (!pass) return false;
        }
        return true;
    }

    // "Conditions": the table, one branch per row.
    fn evaluate(self: *Engine, c: fpack.Condition, r: Report) !Outcome {
        const type_ = report_keys.stringOf(r.map, "type");
        switch (c) {
            .circle => |p| {
                const d = geo.distance(r.lat, r.lon, p.lat, p.lon);
                return .{ .result = truth(d <= p.radius_m), .value = .{ .float = d }, .limit = .{ .float = p.radius_m } };
            },
            .polygon => |p| {
                const side = geo.polygon(p.vertices, r.lat, r.lon);
                return .{ .result = truth(side != .outside), .value = str(side.name()), .limit = .null };
            },
            .near => |p| {
                const limit = json.Value{ .float = p.radius_m };
                const unknown = Outcome{ .result = .unknown, .value = .null, .limit = limit };
                // The reference's state before this report.
                const ref = self.entities.get(p.reference) orelse return unknown;
                // Stale by age, or by the reference's own `stale_ms`.
                const diff = @as(i128, r.time_ms) - ref.time_ms;
                const age = if (diff < 0) -diff else diff;
                if (age > p.max_age_ms) return unknown;
                if (ref.stale_ms) |s| if (r.time_ms >= s) return unknown;
                const at = geo.predict(ref.time_ms, ref.lat, ref.lon, ref.course, ref.speed_ms, r.time_ms);
                const d = geo.distance(r.lat, r.lon, at.lat, at.lon);
                return .{ .result = truth(d <= p.radius_m), .value = .{ .float = d }, .limit = limit };
            },
            .env => |p| return self.listCondition(environment(type_), p.in),
            .affiliation => |p| return self.listCondition(affiliation(type_), p.in),
            .source => |p| return self.listCondition(r.source, p.in),
            .uid => |p| return self.listCondition(r.uid, p.in),
            .key => |k| {
                const v = present(r.map, k.name);
                switch (k.form) {
                    .eq => |t| {
                        const limit = str(t.text);
                        const val = v orelse return .{ .result = .unknown, .value = .null, .limit = limit };
                        return .{ .result = truth(keyEquals(val, t)), .value = val, .limit = limit };
                    },
                    .in => |items| {
                        const limit = try self.textList(items);
                        const val = v orelse return .{ .result = .unknown, .value = .null, .limit = limit };
                        var found = false;
                        for (items) |t| {
                            if (keyEquals(val, t)) found = true;
                        }
                        return .{ .result = truth(found), .value = val, .limit = limit };
                    },
                    .range => |rg| return self.rangeCondition(v, rg),
                }
            },
            .has => |p| {
                const is_present = present(r.map, p.name) != null;
                return .{ .result = truth(is_present), .value = .{ .bool = is_present }, .limit = .null };
            },
            .speed => |rg| return self.rangeCondition(present(r.map, "speed_ms"), rg),
            .altitude => |rg| return self.rangeCondition(present(r.map, "hae"), rg),
            .interval => |p| {
                const limit = json.Value{ .integer = p.min_ms };
                const kept = if (self.entities.get(r.key)) |s| s.kept_ms else null;
                const k = kept orelse return .{ .result = .no, .value = .null, .limit = limit };
                const value = @as(i128, r.time_ms) - k;
                return .{ .result = truth(value < p.min_ms), .value = intValue(value), .limit = limit };
            },
            .order => {
                const kept = if (self.entities.get(r.key)) |s| s.kept_ms else null;
                const value = json.Value{ .integer = r.time_ms };
                const k = kept orelse return .{ .result = .no, .value = value, .limit = .null };
                return .{ .result = truth(r.time_ms < k), .value = value, .limit = .{ .integer = k } };
            },
        }
    }

    // `env`, `affiliation`, `source`, `uid`: byte-for-byte membership in the `in` list.
    fn listCondition(self: *Engine, value: ?[]const u8, items: []const []const u8) !Outcome {
        const limit = try self.stringList(items);
        const v = value orelse return .{ .result = .unknown, .value = .null, .limit = limit };
        var found = false;
        for (items) |item| {
            if (std.mem.eql(u8, item, v)) found = true;
        }
        return .{ .result = truth(found), .value = str(v), .limit = limit };
    }

    // `key` range, `speed`, `altitude`: inclusive bounds; unknown when absent or not a number.
    fn rangeCondition(self: *Engine, value: ?json.Value, rg: fpack.Range) !Outcome {
        const limit = try self.rangeLimit(rg);
        const v = value orelse return .{ .result = .unknown, .value = .null, .limit = limit };
        const x = asNumber(v) orelse return .{ .result = .unknown, .value = v, .limit = limit };
        return .{ .result = truth(inRange(x, rg)), .value = v, .limit = limit };
    }

    // "Rules" 4.
    fn updateState(self: *Engine, r: Report, kept: bool) !void {
        const from_report = State{
            .time_ms = r.time_ms,
            .lat = r.lat,
            .lon = r.lon,
            .course = report_keys.numberOf(r.map, "course"),
            .speed_ms = report_keys.numberOf(r.map, "speed_ms"),
            .stale_ms = report_keys.integerOf(r.map, "stale_ms"),
            .kept_ms = null,
        };
        const slot = try self.entities.getOrPut(r.key);
        if (!slot.found_existing) {
            // An entity with no state gets state from this report, `kept_ms` null.
            slot.key_ptr.* = try self.alloc().dupe(u8, r.key);
            slot.value_ptr.* = from_report;
        } else if (r.time_ms >= slot.value_ptr.time_ms) {
            // A report not older replaces the position fields; an older one replaces none.
            const kept_ms = slot.value_ptr.kept_ms;
            slot.value_ptr.* = from_report;
            slot.value_ptr.kept_ms = kept_ms;
        }
        if (kept) {
            const s = slot.value_ptr;
            if (s.kept_ms == null or s.kept_ms.? < r.time_ms) s.kept_ms = r.time_ms;
        }
    }

    // ---- tick ----------------------------------------------------------------

    // Operation `tick(now_ms)`: forgets entities older than `forget_ms`, in key order.
    pub fn tick(self: *Engine, now_ms: i64) !Result {
        var res = self.newResult();
        for (try self.sortedKeys()) |key| {
            const s = self.entities.get(key).?;
            const value = @as(i128, now_ms) - s.time_ms;
            const forget = value > self.pack.forget_ms;
            try res.trace.append(try self.object(.{
                .{ "stage", str("forget") },
                .{ "entity", str(key) },
                .{ "test", str("age") },
                .{ "value", intValue(value) },
                .{ "limit", json.Value{ .integer = self.pack.forget_ms } },
                .{ "pass", json.Value{ .bool = forget } },
            }));
            if (forget) {
                _ = self.entities.orderedRemove(key);
                try res.events.append(try self.object(.{ .{ "ev", str("forget") }, .{ "entity", str(key) } }));
            }
        }
        return res;
    }

    // ---- snapshot ------------------------------------------------------------

    // Operation `snapshot()`: `{"entities": {key: state}}`.
    pub fn snapshot(self: *Engine) !json.Value {
        var entities = json.ObjectMap.init(self.alloc());
        for (try self.sortedKeys()) |key| {
            const s = self.entities.get(key).?;
            try entities.put(key, try self.object(.{
                .{ "time_ms", json.Value{ .integer = s.time_ms } },
                .{ "lat", json.Value{ .float = s.lat } },
                .{ "lon", json.Value{ .float = s.lon } },
                .{ "course", optFloat(s.course) },
                .{ "speed_ms", optFloat(s.speed_ms) },
                .{ "stale_ms", optInt(s.stale_ms) },
                .{ "kept_ms", optInt(s.kept_ms) },
            }));
        }
        return self.object(.{.{ "entities", json.Value{ .object = entities } }});
    }
};
