// spec/filter.md: the filter engine and its four operations.
// Section names in comments are those of spec/filter.md.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const fpack = @import("pack.zig");
const conditions = @import("conditions.zig");
// "Reports" cites the Reports section of correlate.md; the key readers are the
// correlate engine's own.
const report_keys = @import("../model/report.zig");

const record = @import("../trace/record.zig");
const common = @import("../snapshot/common.zig");
const snapshot_filter = @import("../snapshot/filter.zig");

pub const Pack = fpack.Pack;
pub const load_pack = fpack.load;

pub const Result = record.Result;

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
pub const Report = struct {
    map: json.ObjectMap,
    key: []const u8,
    source: []const u8,
    uid: []const u8,
    time_ms: i64,
    lat: f64,
    lon: f64,
};

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

    pub fn alloc(self: *Engine) Allocator {
        return self.arena.allocator();
    }

    fn newResult(self: *Engine) Result {
        return Result.init(self.alloc());
    }

    pub fn object(self: *Engine, fields: anytype) !json.Value {
        return record.object(self.alloc(), fields);
    }

    fn str(s: []const u8) json.Value {
        return .{ .string = s };
    }

    fn stringList(self: *Engine, items: []const []const u8) !json.Value {
        return record.stringList(self.alloc(), items);
    }

    pub fn sortedKeys(self: *Engine) ![][]const u8 {
        return common.sortedKeys(self.alloc(), self.entities.keys());
    }

    // ---- ingest --------------------------------------------------------------

    // Operation `ingest(report)`: one event and the trace for that report.
    pub fn ingest(self: *Engine, map: json.ObjectMap) !Result {
        var res = self.newResult();

        // "Reports": required keys, checked in the order of correlate.md's table.
        const req = switch (report_keys.required(map)) {
            .ok => |x| x,
            .missing => |k| {
                // A rejected report gives no trace and changes no state.
                const reason = try std.fmt.allocPrint(self.alloc(), "missing:{s}", .{k});
                try res.events.append(try self.object(.{ .{ "ev", str("reject") }, .{ "reason", str(reason) } }));
                return res;
            },
        };
        const r = Report{
            .map = map,
            .key = try std.fmt.allocPrint(self.alloc(), "{s}/{s}", .{ req.source, req.uid }),
            .source = req.source,
            .uid = req.uid,
            .time_ms = req.time_ms,
            .lat = req.lat,
            .lon = req.lon,
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
            const o = try conditions.evaluate(self.alloc(), &self.entities, w.condition, r);
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
                .{ "value", conditions.intValue(value) },
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

    // Operation `snapshot()`: snapshot/filter.zig.
    pub fn snapshot(self: *Engine) !json.Value {
        return snapshot_filter.snapshot(self);
    }
};
