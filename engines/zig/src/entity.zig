// Spec "Reports" and "Track estimate": one entity per `<track.source_id>/<uid>`.
const std = @import("std");
const json = std.json;
const kalman = @import("kalman.zig");
const imm = @import("imm.zig");
const pack_mod = @import("pack.zig");

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

pub fn numberOf(m: json.ObjectMap, key: []const u8) ?f64 {
    const v = m.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

// Spec 0.3 "Reports": a `ce` of 0 or below is treated as absent.
pub fn ceOf(m: json.ObjectMap) ?f64 {
    const c = numberOf(m, "ce") orelse return null;
    return if (c > 0) c else null;
}

// correlate.md 0.8 "Reports", "Time quality": the time error and time state of
// a report, found per key: the report's own key when present, otherwise the
// pack's `time_default` for its source, otherwise 0 and `coherent`.
pub const TimeQuality = struct { error_ms: f64, state: pack_mod.TimeState };

pub fn timeQualityOf(m: json.ObjectMap, source: []const u8, pack: pack_mod.Pack) TimeQuality {
    const default = pack.timeDefaultOf(source);
    // `time_error_ms`: a finite number 0 or above; anything else is absent.
    var error_ms: ?f64 = null;
    if (numberOf(m, "time_error_ms")) |x| {
        if (std.math.isFinite(x) and x >= 0) error_ms = x;
    }
    if (error_ms == null) {
        if (default) |d| error_ms = d.error_ms;
    }
    // `time_state`: one of the three strings, byte for byte; anything else is absent.
    var state: ?pack_mod.TimeState = null;
    if (stringOf(m, "time_state")) |t| state = std.meta.stringToEnum(pack_mod.TimeState, t);
    if (state == null) {
        if (default) |d| state = d.state;
    }
    return .{ .error_ms = error_ms orelse 0, .state = state orelse .coherent };
}

pub fn integerOf(m: json.ObjectMap, key: []const u8) ?i64 {
    const v = m.get(key) orelse return null;
    return switch (v) {
        // Spec 0.3 "Reports": an integer is a JSON number written without a fraction or
        // an exponent; std.json yields `.float` for `1000.0` and `1e3`, so those are the wrong type.
        .integer => |i| i,
        else => null,
    };
}

pub fn stringOf(m: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = m.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
