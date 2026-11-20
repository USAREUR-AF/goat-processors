// spec/quality.md 0.2: the quality engine, operations `ingest`, `tick` and
// `snapshot`. Frame and filter are those of the correlate engine (correlate.md
// "Frame", "Track estimate"), reused from frame.zig and kalman.zig; the report's
// own time error and time state are read as correlate.md 0.8 "Time quality"
// reads them, reused from entity.zig.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const frame = @import("../model/frame.zig");
const kalman = @import("../model/kalman.zig");
const reports = @import("../model/report.zig"); // correlate's typed key readers (spec "Reports")
const qpack = @import("pack.zig");
const measures = @import("measures.zig");
const rules = @import("rules.zig");
const samples = @import("samples.zig");
const record = @import("../trace/record.zig");
const common = @import("../snapshot/common.zig");
const snapshot_quality = @import("../snapshot/quality.zig");
pub const Pack = qpack.Pack;
const Rule = qpack.Rule;
const Record = measures.Record;
const Order = measures.Order;
const Measures = measures.Measures;
const Num = measures.Num;
const TimeState = qpack.TimeState;

pub const load_pack = qpack.load;
pub const parse = qpack.parse;

pub const Result = record.Result;

pub const Entity = struct {
    source: []const u8,
    // `last`: the entity's latest accepted time of a `first` or `advance` report.
    last_time_ms: i64,
    // `last_pos`: the plane position of that report, as reported.
    last_pos: frame.Plane,
    filter: kalman.Filter,
    window: std.ArrayList(Record),
};

pub const RuleState = rules.RuleState;

const toValue = record.toValue;

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

    pub fn alloc(self: *Engine) Allocator {
        return self.arena.allocator();
    }

    // ---- JSON output -------------------------------------------------------

    // `fields` is a tuple of .{ name, value } pairs.
    pub fn object(self: *Engine, fields: anytype) !json.Value {
        return record.object(self.alloc(), fields);
    }

    pub fn list(self: *Engine, items: anytype) !json.Value {
        return record.list(self.alloc(), items);
    }

    // The `measures` object of a `quality` event: every measure of the scope's table.
    fn measuresValue(self: *Engine, scope: qpack.Scope, m: Measures) !json.Value {
        var obj = json.ObjectMap.init(self.alloc());
        inline for (std.meta.fields(qpack.Measure)) |f| {
            const name: qpack.Measure = @enumFromInt(f.value);
            if (qpack.inScope(name, scope)) try obj.put(f.name, toValue(m.get(name)));
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

    // ---- input clock -------------------------------------------------------

    // Spec "Input clock", steps 1 to 3, over the entities that exist before the
    // report is applied: the median of the latest times of the sources other
    // than the report's `track.source_id`; null with no other source.
    fn inputClock(self: *Engine, report_source: []const u8) !?Num {
        // 1. Each other source's latest time: the greatest `last` of its entities.
        var sources = std.ArrayList([]const u8).init(self.alloc());
        var latest = std.ArrayList(i64).init(self.alloc());
        defer sources.deinit();
        defer latest.deinit();
        for (self.entities.values()) |e| {
            if (std.mem.eql(u8, e.source, report_source)) continue;
            for (sources.items, latest.items) |s, *l| {
                if (std.mem.eql(u8, s, e.source)) {
                    l.* = @max(l.*, e.last_time_ms);
                    break;
                }
            } else {
                try sources.append(e.source);
                try latest.append(e.last_time_ms);
            }
        }
        return samples.median(latest.items);
    }

    // Spec "Input clock": the source latest, the greatest `last` among the
    // entities whose source is the report's `track.source_id` (the report's own
    // entity among them when it is of that source); null when there is none.
    fn sourceLatest(self: *Engine, report_source: []const u8) ?i64 {
        var out: ?i64 = null;
        for (self.entities.values()) |e| {
            if (!std.mem.eql(u8, e.source, report_source)) continue;
            if (out == null or e.last_time_ms > out.?) out = e.last_time_ms;
        }
        return out;
    }

    // ---- ingest ------------------------------------------------------------

    // Spec "Ingest", operation `ingest(report)`.
    pub fn ingest(self: *Engine, report: json.ObjectMap) !Result {
        var res = Result.init(self.alloc());
        const f = self.pack.filter;

        // "Reports": required keys, in the order of the table; a missing one rejects.
        const req = switch (reports.required(report)) {
            .ok => |x| x,
            .missing => |k| {
                const reason = try std.fmt.allocPrint(self.alloc(), "missing:{s}", .{k});
                try res.events.append(try self.object(.{ .{ "ev", "reject" }, .{ "reason", reason } }));
                return res;
            },
        };
        const source_id: ?[]const u8 = req.source;
        const uid: ?[]const u8 = req.uid;
        const time_ms: ?i64 = req.time_ms;
        const lat: ?f64 = req.lat;
        const lon: ?f64 = req.lon;
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
        const meas = kalman.Measurement{
            .east = pos.east,
            .north = pos.north,
            .r_east = ce * ce,
            .r_north = ce * ce,
            .vel = kalman.velocityOf(course, speed_ms),
            .r_vel = f.vel_sigma_ms * f.vel_sigma_ms,
        };
        const vel = meas.vel;

        // "Input clock": built before the report is applied.
        const clock = try self.inputClock(source_id.?);
        const source_latest = self.sourceLatest(source_id.?);

        // "Reports", "Time quality", per key: the report's own valid value, else
        // the pack's `time_default` for the report's `track.source_id`, else unstated.
        const default = self.pack.timeDefaultOf(source_id.?);
        const report_time_error = reports.reportTimeErrorOf(report);
        const default_time_error: ?f64 = if (default) |d| d.error_ms else null;
        const report_time_state = reports.reportTimeStateOf(report);
        const default_time_state: ?TimeState = if (default) |d| d.state else null;

        // "Samples", in the order `interval`, `latency`, `lateness`,
        // `time_error`, `time_state`, `source_order`, `nis`, `speed_err`.
        var rec = Record{
            .wt = wt,
            .time_ms = t,
            .order = order,
            .interval = null,
            .latency = null,
            .lateness = null,
            .nis = null,
            .speed_err = null,
            .time_error = report_time_error orelse default_time_error,
            .time_state = report_time_state orelse default_time_state,
            .source_out_of_order = false,
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
        if (clock) |c| {
            // `clock - t`: an integer when the clock is one, else binary64.
            rec.lateness = switch (c) {
                .int => |ci| .{ .int = ci - t },
                .float => |cf| .{ .float = cf - @as(f64, @floatFromInt(t)) },
            };
            try self.sampleTrace(&res, key, "lateness", rec.lateness.?, try self.list(.{ c, t }));
        }
        if (rec.time_error) |te| {
            try self.sampleTrace(&res, key, "time_error", te, try self.list(.{ report_time_error, default_time_error }));
        }
        if (rec.time_state) |ts| {
            try self.sampleTrace(&res, key, "time_state", @tagName(ts), try self.list(.{
                if (report_time_state) |x| @tagName(x) else null,
                if (default_time_state) |x| @tagName(x) else null,
            }));
        }
        // `source_order`, always: `out-of-order` when `t` is below the source latest.
        rec.source_out_of_order = if (source_latest) |sl| t < sl else false;
        try self.sampleTrace(&res, key, "source_order", if (rec.source_out_of_order) "out-of-order" else "in-order", try self.list(.{ t, source_latest }));
        var predicted: kalman.Filter = undefined;
        if (order == .advance) {
            const e = existing.?;
            const dt = kalman.seconds(last.?, t);
            // `nis`: predict to `t`, then the innovation against predicted plus reported variance.
            predicted = e.filter.predict(dt, f.accel_var);
            const n = samples.nis(predicted, pos, ce * ce);
            rec.nis = n.value;
            try self.sampleTrace(&res, key, "nis", n.value, try self.list(.{ n.de, n.dn, n.se, n.sn }));

            // `speed_err`: speed implied by the move from `last_pos`, against `speed_ms`.
            if (speed_ms) |sp| {
                const se = samples.speedError(e.last_pos, pos, dt, sp);
                rec.speed_err = se.value;
                try self.sampleTrace(&res, key, "speed_err", se.value, try self.list(.{ se.implied, sp }));
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
                    .filter = kalman.Filter.first(meas, f.vel_sigma_ms, f.unknown_vel_ms),
                    .window = window,
                });
                try res.events.append(try self.object(.{ .{ "ev", "new" }, .{ "entity", key } }));
            },
            .advance => {
                const e = existing.?;
                // correlate.md "Track estimate", steps 2 and 3 from the prediction above.
                e.filter = predicted.update(meas).filter;
                e.last_time_ms = t;
                e.last_pos = pos;
                try e.window.append(rec);
            },
            .duplicate, .out_of_order => try existing.?.window.append(rec),
        }

        try self.forward(&res, key, source_id.?, report, ce_valid);
        return res;
    }

    // Spec "Forwarding": one `pass` event, changed by the actions in force.
    fn forward(self: *Engine, res: *Result, key: []const u8, source: []const u8, report: json.ObjectMap, ce_valid: ?f64) !void {
        // "Actions in force": active entity rules for the entity, active source
        // rules for the report's own `track.source_id` ("Reports": actions read
        // the report's source); `alert` changes nothing. Pack order.
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
        var out = (try reports.cloneValue(self.alloc(), .{ .object = report })).object;
        if (factors.items.len > 0) {
            // `x = x * factor` for each `downgrade` in pack order.
            var x = ce_valid orelse self.pack.filter.default_ce_m;
            for (factors.items) |factor| x = x * factor;
            // The largest finite binary64 when `x` overflowed to infinity.
            if (std.math.isInf(x)) x = std.math.floatMax(f64);
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

    pub fn sortedEntityKeys(self: *Engine) ![][]const u8 {
        return common.sortedKeys(self.alloc(), self.entities.keys());
    }

    // The sources that have at least one entity, in key order.
    fn sortedSources(self: *Engine) ![][]const u8 {
        var out = std.ArrayList([]const u8).init(self.alloc());
        for (self.entities.values()) |e| {
            for (out.items) |s| {
                if (std.mem.eql(u8, s, e.source)) break;
            } else try out.append(e.source);
        }
        std.mem.sort([]const u8, out.items, {}, common.lessKey);
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

    // Spec "Rules", evaluation, once for one rule and one subject (rules.zig).
    fn evaluate(self: *Engine, res: *Result, rule: Rule, states: *std.StringArrayHashMap(RuleState), subject: []const u8, m: Measures) !void {
        const gop = try states.getOrPut(subject);
        if (!gop.found_existing) gop.value_ptr.* = .{ .count = 0, .active = false };
        const value = m.get(rule.measure);
        const out = rules.step(rule, gop.value_ptr.*, value);
        gop.value_ptr.* = out.state;
        switch (out.change) {
            .none => {},
            .start => try self.actionEvent(res, rule, subject, "action-start", null, value),
            .end => try self.actionEvent(res, rule, subject, "action-end", "clear", value),
        }
        try res.trace.append(try self.object(.{
            .{ "stage", "rule" },
            .{ "rule", rule.name },
            .{ "subject", subject },
            .{ "measure", @tagName(rule.measure) },
            .{ "value", value },
            .{ "limit", out.shown_limit },
            .{ "pass", out.pass },
            .{ "count", out.state.count },
            .{ "active", out.state.active },
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
        var res = Result.init(self.alloc());
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

    // ---- snapshot: snapshot/quality.zig --------------------------------------

    pub fn snapshot(self: *Engine) !json.Value {
        return snapshot_quality.snapshot(self);
    }
};

const util = @import("../engine_test_util.zig");

test "quality: samples, rules that start and end, forwarding, forgetting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pack = try qpack.parse(a,
        \\pack q
        \\version 1
        \\filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100
        \\window window_ms=10000 min_samples=1 forget_ms=3000
        \\rule many scope=source measure=reports op=>= limit=2 for=1 clear=0 action=mark
        \\rule slow scope=entity measure=interval_max op=> limit=500 for=1 clear=100 action=downgrade factor=2
        \\rule odd scope=entity measure=duplicate op=>= limit=1 for=1 clear=0 action=drop
        \\rule seen scope=entity measure=age op=>= limit=0 for=1 clear=-1 action=alert
    );
    const o = try util.run(@This(), a, pack,
        \\[{"ingest": {"track.source_id": "a", "uid": "1", "time_ms": 0, "lat": 0, "lon": 0, "received_ms": 10, "time_state": "drifting", "time_error_ms": 5, "quality.marks": ["x"]}},
        \\ {"ingest": {"track.source_id": "b", "uid": "2", "time_ms": 0, "lat": 0, "lon": 0}},
        \\ {"ingest": {"track.source_id": "a", "uid": "1", "time_ms": 1000, "lat": 0, "lon": 0.001, "speed_ms": 1, "course": 90, "ce": 10}},
        \\ {"tick": 1000},
        \\ {"ingest": {"track.source_id": "a", "uid": "1", "time_ms": 1000, "lat": 0, "lon": 0.001}},
        \\ {"ingest": {"track.source_id": "a", "uid": "1", "time_ms": 500, "lat": 0, "lon": 0.001}},
        \\ {"tick": 1500},
        \\ {"ingest": {"track.source_id": "a", "uid": "1", "time_ms": 1600, "lat": 0, "lon": 0.001}},
        \\ {"tick": 900},
        \\ {"tick": 10000},
        \\ {"ingest": {"time_ms": 1}}]
    );
    try std.testing.expectEqualStrings("new", util.ev(o, 0, 0));
    try std.testing.expectEqualStrings("pass", util.ev(o, 0, 1));
    var starts: usize = 0;
    for (o.events) |e| for (e.array.items) |x| {
        if (std.mem.eql(u8, x.object.get("ev").?.string, "action-start")) starts += 1;
    };
    try std.testing.expect(starts >= 2);
    // After the duplicate, `odd` is active: the next report of the entity is withheld.
    try std.testing.expect(o.events[7].array.items[0].object.get("withheld").?.bool);
    try std.testing.expectEqualStrings("reject", util.ev(o, 8, 0));
    try std.testing.expectEqualStrings("tick-out-of-order", o.events[8].array.items[0].object.get("reason").?.string);
    try std.testing.expect(util.has(o, 9, "forget") and util.has(o, 9, "action-end"));
    try std.testing.expectEqualStrings("reject", util.ev(o, 10, 0));
    try std.testing.expectEqual(@as(usize, 0), o.snapshot.object.get("entities").?.object.count());
}
