// Spec "What the correlator does": the four operations.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const pack_mod = @import("pack.zig");
const frame = @import("../model/frame.zig");
const kalman = @import("../model/kalman.zig");
const imm = @import("../model/imm.zig");
const report_mod = @import("../model/report.zig");
const record = @import("../trace/record.zig");
const snapshot_common = @import("../snapshot/common.zig");
const entity_mod = @import("entity.zig");
const estimate = @import("estimate.zig");
const Entity = entity_mod.Entity;
pub const Pack = pack_mod.Pack;

pub const load_pack = pack_mod.load;
pub const parse = pack_mod.parse;

pub const Result = record.Result;

pub const Stage = enum { gate, confirm, hold, rank };

pub fn lessKey(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub const Engine = struct {
    arena: std.heap.ArenaAllocator,
    pack: Pack,
    ref: ?frame.Frame = null,
    entities: std.StringArrayHashMap(Entity),
    // correlate.md 1.0 "Stale time of a source", with `stale_rate`: each
    // source's last `samples` update intervals, oldest first.
    intervals: std.StringArrayHashMap(std.ArrayList(i64)),
    // The method's own state (methods.zig `init`).
    method_state: *anyopaque,

    pub fn create(backing: Allocator, pack: Pack) !*Engine {
        const self = try backing.create(Engine);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .pack = pack,
            .entities = undefined,
            .intervals = undefined,
            .method_state = undefined,
        };
        const a = self.arena.allocator();
        self.entities = std.StringArrayHashMap(Entity).init(a);
        self.intervals = std.StringArrayHashMap(std.ArrayList(i64)).init(a);
        self.method_state = try pack.method.init(a);
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

    // `fields` is a tuple of .{ name, value } pairs, kept in that order.
    pub fn object(self: *Engine, fields: anytype) !json.Value {
        return record.object(self.alloc(), fields);
    }

    pub fn stringList(self: *Engine, items: []const []const u8) !json.Value {
        return record.stringList(self.alloc(), items);
    }

    // A group's (`g<n>`) or system track's (`s<n>`) name.
    pub fn groupName(self: *Engine, id: u64) ![]const u8 {
        return std.fmt.allocPrint(self.alloc(), "{s}{d}", .{ self.pack.method.group_prefix, id });
    }

    // ---- state helpers -----------------------------------------------------

    pub fn sortedKeys(self: *Engine) ![][]const u8 {
        return snapshot_common.sortedKeys(self.alloc(), self.entities.keys());
    }

    pub fn insertSorted(list: *std.ArrayList([]const u8), key: []const u8) !void {
        var i: usize = 0;
        while (i < list.items.len and lessKey({}, list.items[i], key)) i += 1;
        try list.insert(i, key);
    }

    // ---- staleness -----------------------------------------------------------

    // correlate.md 1.0 "Stale time of a source", with `stale_rate`: `k * m`, `m` the lower median of the source's intervals,
    // raised to the floor and lowered to the ceiling; the ceiling with none.
    pub fn staleTime(self: *Engine, source: []const u8) f64 {
        const sr = self.pack.stale_rate.?;
        const floor_ms: f64 = @floatFromInt(sr.floor_ms);
        const ceiling_ms: f64 = @floatFromInt(sr.ceiling_ms);
        const list = self.intervals.get(source) orelse return ceiling_ms;
        if (list.items.len == 0) return ceiling_ms;
        var buf: [64]i64 = undefined;
        const sorted = if (list.items.len <= buf.len) buf[0..list.items.len] else self.alloc().alloc(i64, list.items.len) catch @panic("out of memory");
        @memcpy(sorted, list.items);
        std.mem.sort(i64, sorted, {}, std.sort.asc(i64));
        const m: f64 = @floatFromInt(sorted[(sorted.len - 1) / 2]);
        const t = sr.factor * m;
        if (t < floor_ms) return floor_ms;
        if (t > ceiling_ms) return ceiling_ms;
        return t;
    }

    // correlate.md "On each tick", Staleness: above its source's stale time,
    // or at or past its last report's `stale_ms`.
    pub fn isStale(self: *Engine, e: Entity, now_ms: i64) bool {
        const own_stale = if (e.integer("stale_ms")) |s| now_ms >= s else false;
        // `stale_ms` compares integers; a `stale_rate` time is a binary64.
        if (self.pack.stale_rate == null) return now_ms - e.last_time_ms > self.pack.stale_ms or own_stale;
        const age: f64 = @floatFromInt(now_ms - e.last_time_ms);
        return age > self.staleTime(e.source) or own_stale;
    }

    // Appends an update interval to the source's list, which keeps the last `samples`.
    fn appendInterval(self: *Engine, source: []const u8, interval: i64) !void {
        const sr = self.pack.stale_rate orelse return;
        const gop = try self.intervals.getOrPut(source);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.alloc().dupe(u8, source);
            gop.value_ptr.* = std.ArrayList(i64).init(self.alloc());
        }
        try gop.value_ptr.append(interval);
        while (gop.value_ptr.items.len > @as(usize, @intCast(sr.samples))) _ = gop.value_ptr.orderedRemove(0);
    }

    // ---- ingest ------------------------------------------------------------

    // Spec operation `ingest(report)`.
    pub fn ingest(self: *Engine, report: json.ObjectMap) !Result {
        var res = Result.init(self.alloc());

        // Spec "Reports": required keys, in the order of the table.
        const req = switch (report_mod.required(report)) {
            .ok => |x| x,
            .missing => |k| {
                const reason = try std.fmt.allocPrint(self.alloc(), "missing:{s}", .{k});
                try res.events.append(try self.object(.{ .{ "ev", "reject" }, .{ "reason", reason } }));
                return res;
            },
        };
        const time_ms = req.time_ms;

        const key = try std.fmt.allocPrint(self.alloc(), "{s}/{s}", .{ req.source, req.uid });
        // The method may reject a report after the required keys, before out-of-order
        // (correlate-assign.md "Window": a retiring entity).
        if (self.pack.method.reject(self, key)) |reason| {
            try res.events.append(try self.object(.{ .{ "ev", "reject" }, .{ "entity", key }, .{ "reason", reason } }));
            return res;
        }
        if (self.entities.get(key)) |existing| {
            if (time_ms < existing.last_time_ms) {
                try res.events.append(try self.object(.{ .{ "ev", "reject" }, .{ "entity", key }, .{ "reason", "out-of-order" } }));
                return res;
            }
        }

        // Spec "Frame": the first accepted report fixes the reference.
        if (self.ref == null) self.ref = .{ .lat0 = req.lat, .lon0 = req.lon };
        const stored = (try report_mod.cloneValue(self.alloc(), .{ .object = report })).object;
        const pos = self.ref.?.toPlane(req.lat, req.lon);
        const f = self.pack.filter;
        const ce = entity_mod.ceOf(stored) orelse f.default_ce_m;

        // Spec "Track estimate": velocity measurement.
        const measured = kalman.velocityOf(entity_mod.numberOf(stored, "course"), entity_mod.numberOf(stored, "speed_ms"));

        // correlate.md 0.8 "Reports", Time quality: the report's time error and state.
        const tq = entity_mod.timeQualityOf(stored, req.source, self.pack.time_default);
        const te = tq.error_ms;

        // A later report's entity is predicted to the report's time once: the
        // velocity of the measurement variance and the Restart test read it.
        const existing: ?Entity = self.entities.get(key);
        const pred: ?kalman.Filter = if (existing) |e| e.predictedTo(time_ms, self.pack) else null;

        // correlate.md 0.8 "Track estimate", Measurement variance.
        const variance = estimate.measurementVariance(ce, te, pred, measured);
        const time_var_east = variance.time_var_east;
        const time_var_north = variance.time_var_north;
        const meas = kalman.Measurement{
            .east = pos.east,
            .north = pos.north,
            .r_east = variance.r_east,
            .r_north = variance.r_north,
            .vel = measured,
            .r_vel = f.vel_sigma_ms * f.vel_sigma_ms,
        };
        if (te > 0) {
            // The `time` record, before any other record of the report.
            try res.trace.append(try self.object(.{
                .{ "stage", "filter" },
                .{ "a", key },
                .{ "b", json.Value{ .null = {} } },
                .{ "test", "time" },
                .{ "value", te },
                .{ "limit", json.Value{ .null = {} } },
                .{ "pass", true },
                .{ "var_east", time_var_east },
                .{ "var_north", time_var_north },
            }));
        }

        // Spec "Track estimate", first report (also a restart): per axis `pp = r`;
        // one filter, or both models with the long-run mode probabilities.
        const first = kalman.Filter.first(meas, f.vel_sigma_ms, f.unknown_vel_ms);
        const first_imm: ?imm.State = if (self.pack.maneuver) |m| imm.init(m, first) else null;

        const gop = try self.entities.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .key = key,
                .source = entity_mod.stringOf(stored, "track.source_id").?,
                .last_time_ms = time_ms,
                .report = stored,
                .filter = first,
                .imm = first_imm,
                .group = null,
                .hold_failures = 0,
                .r_east = meas.r_east,
                .r_north = meas.r_north,
                .time_error_ms = te,
                .time_var_east = time_var_east,
                .time_var_north = time_var_north,
                .time_state = tq.state,
            };
            try res.events.append(try self.object(.{ .{ "ev", "new" }, .{ "entity", key } }));
        } else {
            const e = gop.value_ptr;
            // correlate.md 0.7 "Restart": d² of the report against the entity's
            // prediction to its time, with the report's measurement variance; after
            // the `time` record and before any other record of the report.
            var restart = false;
            if (self.pack.restart) |rs| {
                const d2 = estimate.restartD2(pos, pred.?, meas.r_east, meas.r_north);
                const pass = d2 < rs.gate;
                try res.trace.append(try self.object(.{
                    .{ "stage", "filter" },
                    .{ "a", e.key },
                    .{ "b", json.Value{ .null = {} } },
                    .{ "test", "restart" },
                    .{ "value", d2 },
                    .{ "limit", rs.gate },
                    .{ "pass", pass },
                }));
                restart = !pass;
            }
            const dt = kalman.seconds(e.last_time_ms, time_ms);
            // correlate.md 1.0: an accepted report of an existing entity appends
            // its interval to its source's list (with `stale_rate`).
            try self.appendInterval(e.source, time_ms - e.last_time_ms);
            if (restart) {
                // The filter starts again from this report as a first report. The
                // entity keeps its key, group, pair counts and hold failure count.
                e.filter = first;
                e.imm = first_imm;
                try self.pack.method.restarted(self, e.key);
            } else if (e.imm) |st| {
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
            e.last_time_ms = time_ms;
            e.report = stored;
            // The entity keeps this report's measurement variance and timing
            // variance (also after a restart).
            e.r_east = meas.r_east;
            e.r_north = meas.r_north;
            e.time_error_ms = te;
            e.time_var_east = time_var_east;
            e.time_var_north = time_var_north;
            e.time_state = tq.state;
        }

        const a_key = self.entities.getPtr(key).?.key;
        // The method's association (correlate.md "Association"; correlate-assign.md
        // keeps the entity for the tick).
        try self.pack.method.accepted(self, &res, a_key);
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

    // B predicted to A's time for a comparison with A.
    pub fn comparePrediction(self: *Engine, a: Entity, b: Entity) !kalman.Filter {
        // correlate.md 0.8: B's prediction with its timing variance added, first.
        const b_pred = b.predictedForComparison(a.last_time_ms, self.pack);
        // Then the method may change it (correlate-assign.md 0.5 "Sensor bias": B is moved into A's frame).
        return self.pack.method.compare(self, a, b, b_pred);
    }

    // Runs `tests` between A and B in order, stopping at the first failure.
    pub fn runTests(self: *Engine, res: *Result, stage: Stage, tests: []const pack_mod.Test, a_key: []const u8, b_key: []const u8) !bool {
        const a = self.entities.get(a_key).?;
        const b = self.entities.get(b_key).?;
        const b_pred = try self.comparePrediction(a, b);
        for (tests) |t| {
            const o = t.run(.{ .a = a, .b = b, .b_pred = b_pred, .filter = self.pack.filter });
            var rec = try self.object(.{
                .{ "stage", @tagName(stage) },
                .{ "a", a_key },
                .{ "b", b_key },
                .{ "test", t.name() },
                .{ "value", o.value },
                .{ "limit", o.limit },
                .{ "pass", o.pass },
            });
            if (o.skipped) try rec.object.put("skipped", .{ .bool = true });
            if (o.dof) |dof| try rec.object.put("dof", .{ .integer = dof });
            try res.trace.append(rec);
            if (!o.pass) return false;
        }
        return true;
    }

    // ---- tick --------------------------------------------------------------

    // Spec operation `tick(now_ms)`.
    pub fn tick(self: *Engine, now_ms: i64) !Result {
        return self.pack.method.tick(self, now_ms);
    }

    // ---- snapshot ----------------------------------------------------------

    // Spec operation `snapshot()`, by the method (methods.zig).
    pub fn snapshot(self: *Engine) !json.Value {
        return self.pack.method.snapshot(self);
    }
};

const util = @import("../engine_test_util.zig");

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "confirm: rejects, new, time record, restart and the fused output" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const pack = try pack_mod.parse(a,
            \\pack p
            \\version 1.0.0
            \\filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100
            \\maneuver accel_var=50 p_enter=0.05 p_leave=0.2
            \\restart gate=20
            \\gate mahalanobis gate=9.21
            \\confirm_count 1
            \\hold mahalanobis gate=18.42
            \\hold_failures 1
            \\stale_ms 5000
            \\time_default b error_ms=100
        );
        const o = try util.run(this_module, a, pack,
            \\[{"ingest": {"uid": "x"}},
            \\ {"ingest": {"track.source_id": "a", "uid": "1", "time_ms": 1000, "lat": 0, "lon": 0, "course": 90, "speed_ms": 10}},
            \\ {"ingest": {"track.source_id": "a", "uid": "1", "time_ms": 500, "lat": 0, "lon": 0}},
            \\ {"ingest": {"track.source_id": "b", "uid": "2", "time_ms": 1000, "lat": 0, "lon": 0.0001, "hae": 5}},
            \\ {"ingest": {"track.source_id": "a", "uid": "1", "time_ms": 2000, "lat": 1, "lon": 1}},
            \\ {"tick": 2000},
            \\ {"tick": 20000}]
        );
        try std.testing.expectEqualStrings("reject", util.ev(o, 0, 0));
        try std.testing.expectEqualStrings("missing:track.source_id", o.events[0].array.items[0].object.get("reason").?.string);
        try std.testing.expectEqualStrings("new", util.ev(o, 1, 0));
        try std.testing.expectEqualStrings("out-of-order", o.events[2].array.items[0].object.get("reason").?.string);
        // b has a time error from its time_default: the `time` record comes first.
        try std.testing.expectEqualStrings("time", o.trace[3].array.items[0].object.get("test").?.string);
        try std.testing.expectEqualStrings("correlate", util.ev(o, 3, 1));
        // a jumps a degree: the restart test fails, then a hold failure ends the group.
        try std.testing.expectEqualStrings("restart", o.trace[4].array.items[0].object.get("test").?.string);
        try std.testing.expect(!o.trace[4].array.items[0].object.get("pass").?.bool);
        try std.testing.expectEqualStrings("leave", util.ev(o, 4, 0));
        try std.testing.expectEqualStrings("dissolve", util.ev(o, 4, 1));
        try std.testing.expectEqual(@as(usize, 0), o.events[5].array.items.len);
        try std.testing.expectEqualStrings("drop", util.ev(o, 6, 0));
        try std.testing.expectEqual(@as(usize, 0), o.snapshot.object.get("entities").?.object.count());
    }

    test "sprt: evidence with heights, an update from a failed gate, a forced update, stale_rate" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // `false` so small that one report's evidence leaves the pair below `up`.
        const pack = try pack_mod.parse(a,
            \\pack p
            \\version 1.0.0
            \\filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100
            \\gate mahalanobis gate=9.21
            \\gate same key=@env
            \\sprt false=0.0000000001 missed=0.01 pos_m=10000 vel_ms=300 hae_sigma_m=100
            \\stale_rate factor=2 floor_ms=1000 ceiling_ms=60000 samples=2
        );
        const o = try util.run(this_module, a, pack,
            \\[{"ingest": {"track.source_id": "a", "uid": "1", "time_ms": 0, "lat": 0, "lon": 0, "hae": 100, "type": "a-f-A"}},
            \\ {"ingest": {"track.source_id": "b", "uid": "2", "time_ms": 0, "lat": 0, "lon": 0.0001, "hae": 120, "type": "a-f-A"}},
            \\ {"ingest": {"track.source_id": "b", "uid": "2", "time_ms": 1000, "lat": 0, "lon": 0.0001, "hae": 120, "type": "a-f-G"}},
            \\ {"ingest": {"track.source_id": "c", "uid": "3", "time_ms": 1000, "lat": 0, "lon": 0, "type": "a-f-A"}},
            \\ {"ingest": {"track.source_id": "c", "uid": "3", "time_ms": 2000, "lat": 0.05, "lon": 0, "type": "a-f-A"}},
            \\ {"ingest": {"track.source_id": "c", "uid": "3", "time_ms": 3000, "lat": 0.05, "lon": 0, "type": "a-f-A"}},
            \\ {"ingest": {"track.source_id": "c", "uid": "3", "time_ms": 9000, "lat": 0.05, "lon": 0, "type": "a-f-A"}},
            \\ {"tick": 9000}]
        );
        // Step 2: one report's evidence, with heights, short of `up`.
        const r1 = o.trace[1].array.items[2].object;
        try std.testing.expectEqualStrings("llr", r1.get("test").?.string);
        try std.testing.expect(!r1.get("pass").?.bool);
        try std.testing.expect(r1.get("increment").?.float > 0);
        // Step 3: `same` fails on a pair with an `L`: a forced update, no increment, removed.
        const recs = o.trace[2].array.items;
        const forced = recs[recs.len - 1].object;
        try std.testing.expect(forced.get("increment").? == .null);
        try std.testing.expect(forced.get("d2").? == .null);
        // Step 5: c is far off; the gate fails, `same` passes, the pair adds its evidence.
        var saw_negative = false;
        for (o.trace[4].array.items) |r| {
            if (std.mem.eql(u8, r.object.get("stage").?.string, "sprt") and r.object.get("increment").? != .null and r.object.get("increment").?.float < 0) saw_negative = true;
        }
        try std.testing.expect(saw_negative);
        try std.testing.expectEqual(@as(usize, 0), o.snapshot.object.get("groups").?.object.count());
        // c's intervals are [1000, 6000] (samples 2): lower median 1000, stale after 2000 ms.
        try std.testing.expectEqual(@as(usize, 2), o.snapshot.object.get("intervals").?.object.get("c").?.array.items.len);
        try std.testing.expectEqualStrings("drop", util.ev(o, 7, 0));
    }

    test "assign: a report gives new; the tick starts and joins system tracks" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const pack = try pack_mod.parse(a,
            \\pack p
            \\version 1.0.0
            \\method assign
            \\filter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100
            \\new_cost 9
            \\keep_bonus 1
            \\stale_ms 5000
            \\restart gate=20
            \\bias sigma_m=50 floor_m=5 gate=9
            \\time_offset sigma_ms=100
            \\window 2
            \\hypotheses 2
            \\margin 50
        );
        const o = try util.run(this_module, a, pack,
            \\[{"ingest": {"track.source_id": "a", "uid": "1", "time_ms": 1000, "lat": 0, "lon": 0, "hae": 3}},
            \\ {"tick": 1000},
            \\ {"ingest": {"track.source_id": "b", "uid": "2", "time_ms": 1500, "lat": 0, "lon": 0.0001}},
            \\ {"ingest": {"track.source_id": "a", "uid": "1", "time_ms": 1500, "lat": 0, "lon": 0}},
            \\ {"tick": 2000},
            \\ {"tick": 3000},
            \\ {"ingest": {"track.source_id": "a", "uid": "1", "time_ms": 3000, "lat": 1, "lon": 1}},
            \\ {"tick": 4000},
            \\ {"tick": 30000},
            \\ {"tick": 31000},
            \\ {"ingest": {"track.source_id": "b", "uid": "2", "time_ms": 32000, "lat": 0, "lon": 0}}]
        );
        try std.testing.expectEqualStrings("new", util.ev(o, 0, 0));
        try std.testing.expect(util.has(o, 1, "system") and util.has(o, 1, "provisional"));
        var saw_bias = false;
        var saw_join = false;
        for (o.trace) |t| for (t.array.items) |r| {
            if (std.mem.eql(u8, r.object.get("stage").?.string, "bias")) saw_bias = true;
        };
        for (o.events) |e| for (e.array.items) |x| {
            if (std.mem.eql(u8, x.object.get("ev").?.string, "join")) saw_join = true;
        };
        try std.testing.expect(saw_join);
        try std.testing.expect(saw_bias);
        try std.testing.expect(o.snapshot.object.get("histories") != null);
        try std.testing.expect(o.snapshot.object.get("bias") != null);
    }
};

// This file as a module, for its unit tests.
const this_module = @This();
