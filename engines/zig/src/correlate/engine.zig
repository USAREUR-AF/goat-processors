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
const pair_tests = @import("tests.zig");
const assign = @import("../assign/assign.zig");
const bias_mod = @import("../assign/bias.zig");
const confirm = @import("confirm.zig");
const snapshot_correlate = @import("../snapshot/correlate.zig");
const snapshot_assign = @import("../snapshot/assign.zig");
const Entity = entity_mod.Entity;
pub const Pack = pack_mod.Pack;

pub const load_pack = pack_mod.load;

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
    // Method confirm: the groups and pair counts.
    confirm_state: confirm.State,
    // correlate-assign.md: `reported` holds the entities with an accepted report
    // since the previous tick; `assign_state` the memberships and histories.
    reported: std.StringArrayHashMap(void),
    // correlate.md 0.7 "Restart", method assign: the entities whose filter
    // started again since the previous tick.
    restarted: std.StringArrayHashMap(void),
    assign_state: assign.State,

    pub fn create(backing: Allocator, pack: Pack) !*Engine {
        const self = try backing.create(Engine);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .pack = pack,
            .entities = undefined,
            .confirm_state = undefined,
            .reported = undefined,
            .restarted = undefined,
            .assign_state = undefined,
        };
        const a = self.arena.allocator();
        self.entities = std.StringArrayHashMap(Entity).init(a);
        self.confirm_state = confirm.State.init(a);
        self.reported = std.StringArrayHashMap(void).init(a);
        self.restarted = std.StringArrayHashMap(void).init(a);
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

    // `fields` is a tuple of .{ name, value } pairs, kept in that order.
    pub fn object(self: *Engine, fields: anytype) !json.Value {
        return record.object(self.alloc(), fields);
    }

    pub fn stringList(self: *Engine, items: []const []const u8) !json.Value {
        return record.stringList(self.alloc(), items);
    }

    // A group's (`g<n>`) or system track's (`s<n>`) name.
    pub fn groupName(self: *Engine, id: u64) ![]const u8 {
        const prefix = if (self.pack.method == .assign) "s" else "g";
        return std.fmt.allocPrint(self.alloc(), "{s}{d}", .{ prefix, id });
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
        // correlate-assign.md "Window": after the required keys, before out-of-order.
        if (self.pack.method == .assign and assign.isRetiring(self, key)) {
            try res.events.append(try self.object(.{ .{ "ev", "reject" }, .{ "entity", key }, .{ "reason", "retiring" } }));
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
            if (restart) {
                // The filter starts again from this report as a first report. The
                // entity keeps its key, group, pair counts and hold failure count.
                e.filter = first;
                e.imm = first_imm;
                if (self.pack.method == .assign) try self.restarted.put(e.key, {});
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
        // correlate-assign.md: a report gives only `new` or `reject`; the tick decides.
        if (self.pack.method == .assign) {
            try self.reported.put(a_key, {});
            return res;
        }
        try confirm.afterIngest(self, &res, a_key);
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
        // correlate.md 0.8: B's prediction with its timing variance added, first.
        var b_pred = b.predictedForComparison(a.last_time_ms, self.pack);
        // correlate-assign.md 0.5 "Sensor bias": B is then moved into A's frame before the test formula.
        if (self.pack.bias) |bp| b_pred = try bias_mod.moveInto(self.alloc(), &self.assign_state.bias, bp, self.pack.time_offset, a.source, b.source, b_pred);
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

    // ---- tick --------------------------------------------------------------

    // Spec operation `tick(now_ms)`.
    pub fn tick(self: *Engine, now_ms: i64) !Result {
        return switch (self.pack.method) {
            .assign => assign.tick(self, now_ms),
            .confirm => confirm.tick(self, now_ms),
        };
    }

    // ---- snapshot ----------------------------------------------------------

    // Spec operation `snapshot()`: snapshot/correlate.zig and snapshot/assign.zig.
    pub fn snapshot(self: *Engine) !json.Value {
        return switch (self.pack.method) {
            .assign => snapshot_assign.snapshot(self),
            .confirm => snapshot_correlate.confirm(self),
        };
    }
};
