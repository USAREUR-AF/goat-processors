// Spec correlate.md "Two-model filter": an interacting multiple model filter of
// two constant-velocity models, `quiet` (index 1 in the spec, [0] here) and
// `maneuver` (index 2, [1] here).
const std = @import("std");
const kalman = @import("kalman.zig");
const params = @import("params.zig");
const Axis = kalman.Axis;
const Filter = kalman.Filter;

pub const model_names = [2][]const u8{ "quiet", "maneuver" };

pub const State = struct {
    models: [2]Filter,
    mu: [2]f64,
};

// "Switching over dt seconds": t[i][j] is the probability of model j at the end
// of dt given model i at its start.
fn switching(m: params.Maneuver, dt: f64) [2][2]f64 {
    const a = m.p_enter;
    const b = m.p_leave;
    const s = a + b;
    const l = std.math.pow(f64, 1.0 - s, dt);
    const t12 = a / s * (1.0 - l);
    const t21 = b / s * (1.0 - l);
    return .{ .{ 1.0 - t12, t12 }, .{ t21, 1.0 - t21 } };
}

// Step 1, `blend(w1, w2)` of one axis.
fn blendAxis(w1: f64, w2: f64, x1: Axis, x2: Axis) Axis {
    const p = w1 * x1.p + w2 * x2.p;
    const v = w1 * x1.v + w2 * x2.v;
    const d1 = x1.p - p;
    const e1 = x1.v - v;
    const d2 = x2.p - p;
    const e2 = x2.v - v;
    return .{
        .p = p,
        .v = v,
        .pp = w1 * (x1.pp + d1 * d1) + w2 * (x2.pp + d2 * d2),
        .pv = w1 * (x1.pv + d1 * e1) + w2 * (x2.pv + d2 * e2),
        .vv = w1 * (x1.vv + e1 * e1) + w2 * (x2.vv + e2 * e2),
    };
}

pub fn blend(w1: f64, w2: f64, f1: Filter, f2: Filter) Filter {
    return .{ .east = blendAxis(w1, w2, f1.east, f2.east), .north = blendAxis(w1, w2, f1.north, f2.north) };
}

// "First report": both models are the first-report filter; mu is the long-run share.
pub fn init(m: params.Maneuver, first: Filter) State {
    const s = m.p_enter + m.p_leave;
    return .{ .models = .{ first, first }, .mu = .{ m.p_leave / s, m.p_enter / s } };
}

// The entity's filter: step 5, `blend(mu1, mu2)` of the two models.
pub fn combined(st: State) Filter {
    return blend(st.mu[0], st.mu[1], st.models[0], st.models[1]);
}

pub const Step = struct { state: State, lambda: [2]f64 };

// "Later reports", steps 1 to 4. The combination (step 5) is `combined`.
pub fn update(st: State, m: params.Maneuver, q1: f64, dt: f64, meas: kalman.Measurement) Step {
    const t = switching(m, dt);
    const mu = st.mu;
    const q = [2]f64{ q1, m.accel_var };

    // 1. Mixing, from the model states before mixing.
    const c = [2]f64{ t[0][0] * mu[0] + t[1][0] * mu[1], t[0][1] * mu[0] + t[1][1] * mu[1] };
    var mixed: [2]Filter = undefined;
    for (0..2) |j| {
        if (c[j] == 0) {
            mixed[j] = st.models[j];
        } else {
            const w1 = t[0][j] * mu[0] / c[j];
            const w2 = t[1][j] * mu[1] / c[j];
            mixed[j] = blend(w1, w2, st.models[0], st.models[1]);
        }
    }

    // 2. Predict and update each model; 3. its log-likelihood.
    var models: [2]Filter = undefined;
    var lambda: [2]f64 = undefined;
    for (0..2) |j| {
        const u = mixed[j].predict(dt, q[j]).update(meas);
        models[j] = u.filter;
        lambda[j] = -0.5 * u.g;
    }

    // 4. Mode probabilities, relative to the larger lambda of the models with c above 0.
    var top: ?f64 = null;
    for (0..2) |j| {
        if (c[j] > 0 and (top == null or lambda[j] > top.?)) top = lambda[j];
    }
    var e: [2]f64 = undefined;
    for (0..2) |j| e[j] = if (c[j] > 0) c[j] * @exp(lambda[j] - top.?) else 0;
    const sum = e[0] + e[1];
    return .{ .state = .{ .models = models, .mu = .{ e[0] / sum, e[1] / sum } }, .lambda = lambda };
}

// "Prediction": each model with its own acceleration variance, combined with the
// current mode probabilities. Never changes the entity.
pub fn predict(st: State, m: params.Maneuver, q1: f64, dt: f64) Filter {
    return blend(st.mu[0], st.mu[1], st.models[0].predict(dt, q1), st.models[1].predict(dt, m.accel_var));
}

test "the first state holds the long-run mode probabilities; update keeps them a distribution" {
    const m = params.Maneuver{ .accel_var = 10, .p_enter = 0.1, .p_leave = 0.3 };
    const ax = kalman.Axis{ .p = 0, .v = 1, .pp = 100, .pv = 0, .vv = 4 };
    const st = init(m, .{ .east = ax, .north = ax });
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), st.mu[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), st.mu[1], 1e-12);
    const c = combined(st);
    try std.testing.expectApproxEqAbs(ax.p, c.east.p, 1e-12);
    const meas = kalman.Measurement{ .east = 50, .north = 0, .r_east = 100, .r_north = 100, .r_vel = 1 };
    const step = update(st, m, 1, 1, meas);
    try std.testing.expectApproxEqAbs(@as(f64, 1), step.state.mu[0] + step.state.mu[1], 1e-12);
    // A large miss favors the maneuver model.
    try std.testing.expect(step.state.mu[1] > st.mu[1]);
    const p = predict(st, m, 1, 2);
    try std.testing.expectApproxEqAbs(@as(f64, 2), p.east.p, 1e-12);
}

test "switching over 0 s is the identity" {
    const t = switching(.{ .accel_var = 10, .p_enter = 0.1, .p_leave = 0.3 }, 0);
    try std.testing.expectEqual(@as(f64, 1), t[0][0]);
    try std.testing.expectEqual(@as(f64, 0), t[0][1]);
}
