// spec/quality.md "Input clock" (the median) and "Samples" (`nis`,
// `speed_err`): pure functions.
const std = @import("std");
const kalman = @import("../model/kalman.zig");
const frame = @import("../model/frame.zig");
const Num = @import("measures.zig").Num;

// "Input clock", steps 2 and 3: the median of the other sources' latest times,
// sorted ascending in place: the middle value for an odd count, `(a + b) / 2`
// in binary64 for an even count; null with no other source.
pub fn median(latest: []i64) ?Num {
    const n = latest.len;
    if (n == 0) return null;
    std.mem.sort(i64, latest, {}, std.sort.asc(i64));
    if (n % 2 == 1) return .{ .int = latest[n / 2] };
    const a: f64 = @floatFromInt(latest[n / 2 - 1]);
    const b: f64 = @floatFromInt(latest[n / 2]);
    return .{ .float = (a + b) / 2.0 };
}

pub const Nis = struct { value: f64, de: f64, dn: f64, se: f64, sn: f64 };

// `nis`: the innovation of the report's position against the prediction to
// its time, with the predicted plus the reported variance `r` per axis.
pub fn nis(predicted: kalman.Filter, pos: frame.Plane, r: f64) Nis {
    const de = pos.east - predicted.east.p;
    const dn = pos.north - predicted.north.p;
    const se = predicted.east.pp + r;
    const sn = predicted.north.pp + r;
    return .{ .value = de * de / se + dn * dn / sn, .de = de, .dn = dn, .se = se, .sn = sn };
}

pub const SpeedError = struct { value: f64, implied: f64 };

// `speed_err`: the speed implied by the move from `last_pos` over `dt`
// seconds, against the reported `speed_ms`.
pub fn speedError(last_pos: frame.Plane, pos: frame.Plane, dt: f64, speed_ms: f64) SpeedError {
    const implied = std.math.hypot(pos.east - last_pos.east, pos.north - last_pos.north) / dt;
    return .{ .value = @abs(implied - speed_ms), .implied = implied };
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "median of odd, even and no counts" {
        var odd = [_]i64{ 30, 10, 20 };
        try std.testing.expectEqual(@as(i64, 20), median(&odd).?.int);
        var even = [_]i64{ 4, 1 };
        try std.testing.expectEqual(@as(f64, 2.5), median(&even).?.float);
        var none = [_]i64{};
        try std.testing.expect(median(&none) == null);
    }

    test "nis and speed error" {
        const ax = kalman.Axis{ .p = 0, .v = 0, .pp = 50, .pv = 0, .vv = 1 };
        const n = nis(.{ .east = ax, .north = ax }, .{ .east = 10, .north = 0 }, 50);
        try std.testing.expectEqual(@as(f64, 1), n.value);
        const s = speedError(.{ .east = 0, .north = 0 }, .{ .east = 3, .north = 4 }, 1, 4);
        try std.testing.expectEqual(@as(f64, 5), s.implied);
        try std.testing.expectEqual(@as(f64, 1), s.value);
    }
};
