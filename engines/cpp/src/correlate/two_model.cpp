// correlate.md "Two-model filter" (with the first report and later reports of
// "Track estimate" for one entity, and Prediction).
#include "correlate/engine.hpp"

#include <cmath>

#include "correlate/common.hpp"

namespace corr::correlate {

using namespace detail;

namespace {

// Spec "Two-model filter", step 1: blend(w1, w2) of one axis.
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

Filter blend(double w1, double w2, const Filter& m1, const Filter& m2) {
    return {blend(w1, w2, m1.east, m2.east), blend(w1, w2, m1.north, m2.north)};
}

// Spec "Track estimate", steps 1 to 3 on one filter, with acceleration
// variance q and the report's position variance r_east, r_north
// (Measurement variance). Returns g, the likelihood terms added left to right from 0 in
// the order east position, north position, east velocity, north velocity.
double kalman_step(Filter& f, double dt, double q, double z_east, double z_north,
                   const double* vel_east, const double* vel_north, double r_east, double r_north,
                   double r_vel) {
    axis_predict(f.east, dt, q);
    axis_predict(f.north, dt, q);
    double term[4] = {0, 0, 0, 0};
    term[0] = axis_position_update(f.east, z_east, r_east);
    term[1] = axis_position_update(f.north, z_north, r_north);
    if (vel_east) {
        term[2] = axis_velocity_update(f.east, *vel_east, r_vel);
        term[3] = axis_velocity_update(f.north, *vel_north, r_vel);
    }
    double g = 0;
    g = g + term[0];
    g = g + term[1];
    if (vel_east) {
        g = g + term[2];
        g = g + term[3];
    }
    return g;
}

} // namespace

// First report: per axis pp = r, that axis's measurement variance.
void Engine::filter_first(Entity& e, const Point& z, const std::optional<Point>& vel, const Point& r) const {
    const auto& f = pack_.filter;
    double vv = vel ? f.vel_sigma_ms * f.vel_sigma_ms : f.unknown_vel_ms * f.unknown_vel_ms;
    e.filter.east = {z.east, vel ? vel->east : 0.0, r.east, 0.0, vv};
    e.filter.north = {z.north, vel ? vel->north : 0.0, r.north, 0.0, vv};
    // Spec "Two-model filter", First report: both models are this filter,
    // with the long-run share of each model.
    if (pack_.maneuver) {
        double a = pack_.maneuver->p_enter, b = pack_.maneuver->p_leave, s = a + b;
        e.models[0] = e.models[1] = e.filter;
        e.mu[0] = b / s;
        e.mu[1] = a / s;
    }
}

void Engine::filter_update(Entity& e, const Point& z, const std::optional<Point>& vel, const Point& r,
                           double dt, Output& out) const {
    const auto& f = pack_.filter;
    const double r_vel = f.vel_sigma_ms * f.vel_sigma_ms;
    const double* ve = vel ? &vel->east : nullptr;
    const double* vn = vel ? &vel->north : nullptr;
    if (!pack_.maneuver) {
        kalman_step(e.filter, dt, f.accel_var, z.east, z.north, ve, vn, r.east, r.north, r_vel);
        return;
    }

    // Spec "Two-model filter", Later reports.
    const double a = pack_.maneuver->p_enter, b = pack_.maneuver->p_leave;
    const double q[2] = {f.accel_var, pack_.maneuver->accel_var};

    // Switching over dt seconds: t[i][j] is model i -> model j.
    double s = a + b;
    double l = std::pow(1 - s, dt);
    double t12 = a / s * (1 - l), t21 = b / s * (1 - l);
    double t[2][2] = {{1 - t12, t12}, {t21, 1 - t21}};
    const double mu1 = e.mu[0], mu2 = e.mu[1];

    // 1. Mixing, both mixed states from the model states before mixing.
    double c[2];
    Filter mixed[2];
    for (int j = 0; j < 2; ++j) {
        c[j] = t[0][j] * mu1 + t[1][j] * mu2;
        if (c[j] == 0) {
            mixed[j] = e.models[j];
        } else {
            double w1 = t[0][j] * mu1 / c[j], w2 = t[1][j] * mu2 / c[j];
            mixed[j] = blend(w1, w2, e.models[0], e.models[1]);
        }
    }

    // 2. Predict and update, and 3. likelihood lambda = -0.5 * g.
    double lambda[2];
    for (int j = 0; j < 2; ++j) {
        e.models[j] = mixed[j];
        double g = kalman_step(e.models[j], dt, q[j], z.east, z.north, ve, vn, r.east, r.north, r_vel);
        lambda[j] = -0.5 * g;
    }

    // 4. Mode probabilities, relative to the larger lambda of the models with c above 0.
    bool have_m = false;
    double m = 0;
    for (int j = 0; j < 2; ++j)
        if (c[j] > 0 && (!have_m || lambda[j] > m)) { m = lambda[j]; have_m = true; }
    double ev[2];
    for (int j = 0; j < 2; ++j) ev[j] = c[j] > 0 ? c[j] * std::exp(lambda[j] - m) : 0.0;
    double sum = ev[0] + ev[1];
    e.mu[0] = ev[0] / sum;
    e.mu[1] = ev[1] / sum;

    // 5. Combination.
    e.filter = blend(e.mu[0], e.mu[1], e.models[0], e.models[1]);

    // Trace: likelihoods, then modes.
    out.trace.push(filter_record(e.key, "likelihood", "quiet", lambda[0]));
    out.trace.push(filter_record(e.key, "likelihood", "maneuver", lambda[1]));
    out.trace.push(filter_record(e.key, "mode", "quiet", e.mu[0]));
    out.trace.push(filter_record(e.key, "mode", "maneuver", e.mu[1]));
}

// Spec "Track estimate", Prediction: step 1 on a copy. With two models, each
// is predicted with its own q and the two are blended with the current mu.
Filter Engine::predict(const Entity& e, std::int64_t t) const {
    double dt = static_cast<double>(t - e.last_time_ms) / 1000;
    auto step1 = [dt](Filter f, double q) {
        axis_predict(f.east, dt, q);
        axis_predict(f.north, dt, q);
        return f;
    };
    if (!pack_.maneuver) return step1(e.filter, pack_.filter.accel_var);
    return blend(e.mu[0], e.mu[1], step1(e.models[0], pack_.filter.accel_var),
                 step1(e.models[1], pack_.maneuver->accel_var));
}

} // namespace corr::correlate
