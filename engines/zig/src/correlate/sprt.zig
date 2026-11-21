// correlate.md 1.0 "Association", Sequential test: one report's evidence for
// A against B, a pure function of the two entities, B's prediction to A's
// time (with B's timing variance added) and the `sprt` line.
const std = @import("std");
const kalman = @import("../model/kalman.zig");
const pack_mod = @import("pack.zig");
const tests = @import("tests.zig");
const Entity = @import("entity.zig").Entity;

pub const Evidence = struct {
    // The increment of `L`.
    increment: f64,
    // The record's `d2`: the two `q`, plus `dh*dh/h1` when both have `hae`.
    d2: f64,
};

// One axis: `0.5*(q0 - q) + 0.5*ln(det0 / det)`, "different objects" the same
// Gaussian difference with the added spread `P` on position and `V` on velocity.
fn axisTerm(sa: tests.StateAxis, P: f64, V: f64) f64 {
    const tpp = sa.spp + P;
    const tvv = sa.svv + V;
    const det0 = tpp * tvv - sa.spv * sa.spv;
    const q0 = (tvv * sa.dp * sa.dp - 2.0 * sa.spv * sa.dp * sa.dv + tpp * sa.dv * sa.dv) / det0;
    return 0.5 * (q0 - sa.q) + 0.5 * @log(det0 / sa.det);
}

pub fn evidence(a: Entity, b: Entity, b_pred: kalman.Filter, s: pack_mod.Sprt) Evidence {
    const P = s.pos_m * s.pos_m;
    const V = s.vel_ms * s.vel_ms;
    const se = tests.stateAxis(a.filter.east, a.time_var_east, b_pred.east);
    const sn = tests.stateAxis(a.filter.north, a.time_var_north, b_pred.north);
    var inc = axisTerm(se, P, V) + axisTerm(sn, P, V);
    var d2 = se.q + sn.q;
    if (a.number("hae")) |ha| if (b.number("hae")) |hb| {
        const h1 = 2.0 * s.hae_sigma_m * s.hae_sigma_m;
        const h0 = h1 + P;
        const dh = ha - hb;
        inc = inc + (0.5 * (dh * dh / h0 - dh * dh / h1) + 0.5 * @log(h0 / h1));
        d2 = d2 + dh * dh / h1;
    };
    return .{ .increment = inc, .d2 = d2 };
}

// The unit tests of this file, run by src/unit_test.zig only: not compiled
// into the vector test binaries the perf harness times.
pub const unit_tests = struct {
    test "the evidence of two equal states is positive and its d2 is 0" {
        const ax = kalman.Axis{ .p = 0, .v = 0, .pp = 100, .pv = 0, .vv = 10 };
        const t = axisTerm(tests.stateAxis(ax, 0, ax), 1e8, 9e4);
        try std.testing.expect(t > 0);
        try std.testing.expectEqual(@as(f64, 0), tests.stateAxis(ax, 0, ax).q);
        const s = pack_mod.Sprt{ .false = 0.01, .missed = 0.01, .pos_m = 1, .vel_ms = 1, .hae_sigma_m = 1 };
        try std.testing.expectApproxEqAbs(-s.upper(), s.lower(), 1e-12);
    }
};
