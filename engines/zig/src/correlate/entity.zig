// Spec "Reports" and "Track estimate": one entity per `<track.source_id>/<uid>`.
const std = @import("std");
const json = std.json;
const kalman = @import("../model/kalman.zig");
const imm = @import("../model/imm.zig");
const report = @import("../model/report.zig");
const pack_mod = @import("pack.zig");

pub const numberOf = report.numberOf;
pub const integerOf = report.integerOf;
pub const stringOf = report.stringOf;
pub const ceOf = report.ceOf;
pub const TimeQuality = report.TimeQuality;
pub const timeQualityOf = report.timeQualityOf;

pub const Entity = struct {
    key: []const u8,
    source: []const u8,
    last_time_ms: i64,
    report: json.ObjectMap,
    // The entity's filter; with `maneuver`, the combination of `imm`'s two models.
    filter: kalman.Filter,
    imm: ?imm.State,
    group: ?u64,
    hold_failures: i64,
    // correlate.md 0.8 "Track estimate", Measurement variance: the last report's
    // `r_east`, `r_north`, its time error, and the entity's timing variance
    // `(v_e*ts)²`, `(v_n*ts)²` (0 and 0 when the time error is 0).
    r_east: f64,
    r_north: f64,
    time_error_ms: f64,
    time_var_east: f64,
    time_var_north: f64,
    // correlate.md 0.8 "Time quality": parsed and kept, not used by correlate.
    time_state: pack_mod.TimeState,

    pub fn number(self: Entity, key: []const u8) ?f64 {
        return numberOf(self.report, key);
    }

    pub fn integer(self: Entity, key: []const u8) ?i64 {
        return integerOf(self.report, key);
    }

    // The entity's last `ce`, or the pack's `default_ce_m`.
    pub fn ce(self: Entity, default_ce_m: f64) f64 {
        return ceOf(self.report) orelse default_ce_m;
    }

    // Spec "Tests": `@env` names the environment taken from `type`; absent when
    // `type` is absent or has fewer than three elements.
    pub fn sameValue(self: Entity, key: []const u8) ?json.Value {
        if (std.mem.eql(u8, key, "@env")) {
            const t = stringOf(self.report, "type") orelse return null;
            var parts = std.mem.splitScalar(u8, t, '-');
            _ = parts.next() orelse return null;
            _ = parts.next() orelse return null;
            const env = parts.next() orelse return null;
            return .{ .string = env };
        }
        const v = self.report.get(key) orelse return null;
        if (v == .null) return null;
        return v;
    }

    // Spec "Track estimate", prediction: step 1 applied to a copy. With two models,
    // spec "Two-model filter", prediction.
    pub fn predictedTo(self: Entity, t_ms: i64, pack: pack_mod.Pack) kalman.Filter {
        const dt = @as(f64, @floatFromInt(t_ms - self.last_time_ms)) / 1000.0;
        if (self.imm) |st| return imm.predict(st, pack.maneuver.?, pack.filter.accel_var, dt);
        return self.filter.predict(dt, pack.filter.accel_var);
    }

    // correlate.md 0.8 "Track estimate": the prediction of B to be compared with
    // another entity, with B's timing variance added to the predicted `pp` on
    // each axis, before any other change to that prediction (Tests, the `rank`
    // record, correlate-assign.md Cost).
    pub fn predictedForComparison(self: Entity, t_ms: i64, pack: pack_mod.Pack) kalman.Filter {
        var f = self.predictedTo(t_ms, pack);
        f.east.pp = f.east.pp + self.time_var_east;
        f.north.pp = f.north.pp + self.time_var_north;
        return f;
    }
};
