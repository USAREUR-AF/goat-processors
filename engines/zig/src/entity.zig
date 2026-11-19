// Spec "Reports" and "Track estimate": one entity per `<track.source_id>/<uid>`.
const std = @import("std");
const json = std.json;
const kalman = @import("kalman.zig");

pub const Entity = struct {
    key: []const u8,
    source: []const u8,
    last_time_ms: i64,
    report: json.ObjectMap,
    filter: kalman.Filter,
    group: ?u64,
    hold_failures: i64,

    pub fn number(self: Entity, key: []const u8) ?f64 {
        return numberOf(self.report, key);
    }

    pub fn integer(self: Entity, key: []const u8) ?i64 {
        return integerOf(self.report, key);
    }

    // The entity's last `ce`, or the pack's `default_ce_m`.
    pub fn ce(self: Entity, default_ce_m: f64) f64 {
        return self.number("ce") orelse default_ce_m;
    }

    // Spec "Tests": `@env` names the environment taken from `type`.
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

    // Spec "Track estimate": prediction applies step 1 to a copy.
    pub fn predictedTo(self: Entity, t_ms: i64, q: f64) kalman.Filter {
        const dt = @as(f64, @floatFromInt(t_ms - self.last_time_ms)) / 1000.0;
        return self.filter.predict(dt, q);
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

pub fn integerOf(m: json.ObjectMap, key: []const u8) ?i64 {
    const v = m.get(key) orelse return null;
    return switch (v) {
        // Spec 0.2 "Reports": `time_ms` and `stale_ms` must be integers; a float is the wrong type.
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
