// Parameter types shared by more than one function's pack: the `filter` line
// (correlate.md "Track estimate"), the `maneuver` line (correlate.md "Two-model
// filter") and the time quality of a report (correlate.md 0.8 "Reports", "Time
// quality"; quality.md 0.2 reuses them).
const std = @import("std");

// correlate.md "Track estimate": the `filter` line.
pub const Filter = struct {
    accel_var: f64,
    default_ce_m: f64,
    vel_sigma_ms: f64,
    unknown_vel_ms: f64,
};

// correlate.md "Two-model filter": the `maneuver` line.
pub const Maneuver = struct {
    accel_var: f64,
    p_enter: f64,
    p_leave: f64,
};

// correlate.md 0.8 "Reports", "Time quality": the state of a report's clock.
pub const TimeState = enum {
    coherent,
    drifting,
    @"free-running",
};

// correlate.md 0.8 "Pack": one `time_default <source_id> error_ms= state=`
// line; each key is null when the line does not give it.
pub const TimeDefault = struct {
    source: []const u8,
    error_ms: ?f64,
    state: ?TimeState,
};

// The `time_default` of a source among a pack's lines, if any.
pub fn timeDefaultOf(defaults: []const TimeDefault, source: []const u8) ?TimeDefault {
    for (defaults) |d| {
        if (std.mem.eql(u8, d.source, source)) return d;
    }
    return null;
}
