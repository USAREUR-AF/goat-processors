// correlate.md "Two-model filter", with the first and later reports of
// "Track estimate" for one entity and its Prediction.
#include "correlate/motion.hpp"

#include <cmath>

namespace corr::correlate {

namespace {

// Step 1: blend(w1, w2) of one axis.
Axis blend(double w1, double w2, const Axis& m1, const Axis& m2) {
    Axis o;
    o.p = w1 * m1.p + w2 * m2.p;
    o.v = w1 * m1.v + w2 * m2.v;
    double d1 = m1.p - o.p, e1 = m1.v - o.v, d2 = m2.p - o.p, e2 = m2.v - o.v;
    o.pp = w1 * (m1.pp + d1 * d1) + w2 * (m2.pp + d2 * d2);
    o.pv = w1 * (m1.pv + d1 * e1) + w2 * (m2.pv + d2 * e2);
    o.vv = w1 * (m1.vv + e1 * e1) + w2 * (m2.vv + e2 * e2);
    return o;
}

// "Track estimate", steps 1 to 3 on one filter, with acceleration variance q
// and the report's position variance r (Measurement variance).
struct Step {
    Filter f;
    double g;   // the likelihood terms added left to right from 0 in the order
                // east position, north position, east velocity, north velocity
};

Step kalman_step(const Filter& f0, double dt, double q, const Point& z, const std::optional<Point>& vel,
                 const Point& r, double r_vel) {
    const Filter p = filter_predict(f0, dt, q);
    const AxisUpdate pe = axis_position_update(p.east, z.east, r.east);
    const AxisUpdate pn = axis_position_update(p.north, z.north, r.north);
    if (!vel) return {{pe.axis, pn.axis}, (0 + pe.term) + pn.term};
    const AxisUpdate ve = axis_velocity_update(pe.axis, vel->east, r_vel);
    const AxisUpdate vn = axis_velocity_update(pn.axis, vel->north, r_vel);
    return {{ve.axis, vn.axis}, (((0 + pe.term) + pn.term) + ve.term) + vn.term};
}

} // namespace

Filter blend(double w1, double w2, const Filter& m1, const Filter& m2) {
    return {blend(w1, w2, m1.east, m2.east), blend(w1, w2, m1.north, m2.north)};
}

Filter predict(const Track& t, const Motion& m, double dt) {
    if (!m.maneuver) return filter_predict(t.filter, dt, m.filter.accel_var);
    return blend(t.mu[0], t.mu[1], filter_predict(t.models[0], dt, m.filter.accel_var),
                 filter_predict(t.models[1], dt, m.maneuver->accel_var));
}

Track first_track(const Motion& m, const Point& z, const std::optional<Point>& vel, const Point& r) {
    const auto& f = m.filter;
    double vv = vel ? f.vel_sigma_ms * f.vel_sigma_ms : f.unknown_vel_ms * f.unknown_vel_ms;
    Track t;
    t.filter.east = {z.east, vel ? vel->east : 0.0, r.east, 0.0, vv};
    t.filter.north = {z.north, vel ? vel->north : 0.0, r.north, 0.0, vv};
    if (m.maneuver) {
        double a = m.maneuver->p_enter, b = m.maneuver->p_leave, s = a + b;
        t.models[0] = t.models[1] = t.filter;
        t.mu[0] = b / s;
        t.mu[1] = a / s;
    }
    return t;
}

TrackUpdate update_track(const Track& t0, const Motion& mo, const Point& z, const std::optional<Point>& vel,
                         const Point& r, double dt) {
    const auto& f = mo.filter;
    const double r_vel = f.vel_sigma_ms * f.vel_sigma_ms;
    TrackUpdate u;
    u.track = t0;
    if (!mo.maneuver) {
        u.track.filter = kalman_step(t0.filter, dt, f.accel_var, z, vel, r, r_vel).f;
        return u;
    }

    // Later reports.
    const double a = mo.maneuver->p_enter, b = mo.maneuver->p_leave;
    const double q[2] = {f.accel_var, mo.maneuver->accel_var};

    // Switching over dt seconds: t[i][j] is model i -> model j.
    double s = a + b;
    double l = std::pow(1 - s, dt);
    double t12 = a / s * (1 - l), t21 = b / s * (1 - l);
    double t[2][2] = {{1 - t12, t12}, {t21, 1 - t21}};
    const double mu1 = t0.mu[0], mu2 = t0.mu[1];

    // 1. Mixing, both mixed states from the model states before mixing.
    double c[2];
    Filter mixed[2];
    for (int j = 0; j < 2; ++j) {
        c[j] = t[0][j] * mu1 + t[1][j] * mu2;
        if (c[j] == 0) {
            mixed[j] = t0.models[j];
        } else {
            double w1 = t[0][j] * mu1 / c[j], w2 = t[1][j] * mu2 / c[j];
            mixed[j] = blend(w1, w2, t0.models[0], t0.models[1]);
        }
    }

    // 2. Predict and update, and 3. likelihood lambda = -0.5 * g.
    for (int j = 0; j < 2; ++j) {
        Step st = kalman_step(mixed[j], dt, q[j], z, vel, r, r_vel);
        u.track.models[j] = st.f;
        u.lambda[j] = -0.5 * st.g;
    }

    // 4. Mode probabilities, relative to the larger lambda of the models with c above 0.
    bool have_m = false;
    double m = 0;
    for (int j = 0; j < 2; ++j)
        if (c[j] > 0 && (!have_m || u.lambda[j] > m)) { m = u.lambda[j]; have_m = true; }
    double ev[2];
    for (int j = 0; j < 2; ++j) ev[j] = c[j] > 0 ? c[j] * std::exp(u.lambda[j] - m) : 0.0;
    double sum = ev[0] + ev[1];
    u.track.mu[0] = ev[0] / sum;
    u.track.mu[1] = ev[1] / sum;

    // 5. Combination.
    u.track.filter = blend(u.track.mu[0], u.track.mu[1], u.track.models[0], u.track.models[1]);
    return u;
}

} // namespace corr::correlate
