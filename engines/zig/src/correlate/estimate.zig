// correlate.md "Track estimate" (Measurement variance, with the timing
// variance of 0.8) and "Restart": pure functions of the report and the
// entity's prediction to the report's time.
const std = @import("std");
const kalman = @import("../model/kalman.zig");
const frame = @import("../model/frame.zig");

pub const Variance = struct {
    r_east: f64,
    r_north: f64,
    // The timing variance `(v*ts)²` per axis; 0 when the time error is 0.
    time_var_east: f64,
    time_var_north: f64,
};

// Measurement variance. With `te` 0, r_east = r_north = ce². Otherwise, with
// ts = te / 1000 and (v_e, v_n) the prediction's velocity (the first report:
// the measured velocity, or 0), r = ce² + (v*ts)² per axis.
pub fn measurementVariance(ce: f64, te: f64, pred: ?kalman.Filter, measured: ?kalman.Velocity) Variance {
    var time_var_east: f64 = 0;
    var time_var_north: f64 = 0;
    if (te > 0) {
        const ts = te / 1000.0;
        const ve: ?f64 = if (measured) |v| v.east else null;
        const vn: ?f64 = if (measured) |v| v.north else null;
        const v_e = if (pred) |pf| pf.east.v else (ve orelse 0.0);
        const v_n = if (pred) |pf| pf.north.v else (vn orelse 0.0);
        time_var_east = (v_e * ts) * (v_e * ts);
        time_var_north = (v_n * ts) * (v_n * ts);
    }
    return .{
        .r_east = if (te > 0) ce * ce + time_var_east else ce * ce,
        .r_north = if (te > 0) ce * ce + time_var_north else ce * ce,
        .time_var_east = time_var_east,
        .time_var_north = time_var_north,
    };
}

// Restart: d² of the report's position against the entity's prediction to its
// time, with the report's measurement variance.
pub fn restartD2(pos: frame.Plane, pred: kalman.Filter, r_east: f64, r_north: f64) f64 {
    const de = pos.east - pred.east.p;
    const dn = pos.north - pred.north.p;
    return de * de / (pred.east.pp + r_east) + dn * dn / (pred.north.pp + r_north);
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "measurement variance adds the timing variance only with a time error" {
        const v0 = measurementVariance(10, 0, null, .{ .east = 3, .north = 4 });
        try std.testing.expectEqual(@as(f64, 100), v0.r_east);
        try std.testing.expectEqual(@as(f64, 0), v0.time_var_north);
        const v1 = measurementVariance(10, 1000, null, .{ .east = 3, .north = 4 });
        try std.testing.expectEqual(@as(f64, 109), v1.r_east);
        try std.testing.expectEqual(@as(f64, 116), v1.r_north);
        const ax = kalman.Axis{ .p = 0, .v = 2, .pp = 1, .pv = 0, .vv = 1 };
        const v2 = measurementVariance(10, 500, .{ .east = ax, .north = ax }, null);
        try std.testing.expectEqual(@as(f64, 1), v2.time_var_east);
    }

    test "restart d2" {
        const ax = kalman.Axis{ .p = 0, .v = 0, .pp = 50, .pv = 0, .vv = 1 };
        try std.testing.expectEqual(@as(f64, 2), restartD2(.{ .east = 10, .north = 0 }, .{ .east = ax, .north = ax }, 50, 50) * 2);
    }
};
