// correlate.md "Track estimate".
#include "model/estimate.hpp"
#include "model/report.hpp"

#include <cmath>

namespace corr {

// ---- Reports ---------------------------------------------------------------

std::optional<Point> measured_velocity(const Json& r) {
    auto course = report::number_at(r, "course"), speed = report::number_at(r, "speed_ms");
    if (!course || !speed) return std::nullopt;
    return Point{*speed * std::sin(rad(*course)), *speed * std::cos(rad(*course))};
}

// ---- Track estimate --------------------------------------------------------

void axis_predict(Axis& a, double dt, double q) {
    const Axis b = a;
    a.p = b.p + b.v * dt;
    a.pp = b.pp + 2 * dt * b.pv + dt * dt * b.vv + q * (dt * dt * dt * dt) / 4;
    a.pv = b.pv + dt * b.vv + q * (dt * dt * dt) / 2;
    a.vv = b.vv + q * (dt * dt);
}

double axis_position_update(Axis& a, double z, double r) {
    const Axis b = a;
    double s = b.pp + r, k1 = b.pp / s, k2 = b.pv / s, y = z - b.p;
    a.p = b.p + k1 * y;
    a.v = b.v + k2 * y;
    a.pp = (1 - k1) * b.pp;
    a.pv = (1 - k1) * b.pv;
    a.vv = b.vv - k2 * b.pv;
    return y * y / s + std::log(s);
}

double axis_velocity_update(Axis& a, double z, double r) {
    const Axis b = a;
    double s = b.vv + r, k1 = b.pv / s, k2 = b.vv / s, y = z - b.v;
    a.p = b.p + k1 * y;
    a.v = b.v + k2 * y;
    a.pp = b.pp - k1 * b.pv;
    a.pv = (1 - k2) * b.pv;
    a.vv = (1 - k2) * b.vv;
    return y * y / s + std::log(s);
}

Filter filter_first(const FilterParams& f, const Point& z, const std::optional<Point>& vel, double ce) {
    double vv = vel ? f.vel_sigma_ms * f.vel_sigma_ms : f.unknown_vel_ms * f.unknown_vel_ms;
    Filter out;
    out.east = {z.east, vel ? vel->east : 0.0, ce * ce, 0.0, vv};
    out.north = {z.north, vel ? vel->north : 0.0, ce * ce, 0.0, vv};
    return out;
}

void filter_correct(Filter& filter, const FilterParams& f, const Point& z, const std::optional<Point>& vel,
                    double ce) {
    for (int axis = 0; axis < 2; ++axis) {
        Axis& a = axis == 0 ? filter.east : filter.north;
        axis_position_update(a, axis == 0 ? z.east : z.north, ce * ce);
        if (vel) axis_velocity_update(a, axis == 0 ? vel->east : vel->north, f.vel_sigma_ms * f.vel_sigma_ms);
    }
}

void filter_update(Filter& filter, const FilterParams& f, const Point& z, const std::optional<Point>& vel,
                   double ce, double dt) {
    for (int axis = 0; axis < 2; ++axis) {
        Axis& a = axis == 0 ? filter.east : filter.north;
        axis_predict(a, dt, f.accel_var);
        axis_position_update(a, axis == 0 ? z.east : z.north, ce * ce);
        if (vel) axis_velocity_update(a, axis == 0 ? vel->east : vel->north, f.vel_sigma_ms * f.vel_sigma_ms);
    }
}

Filter filter_predict(const Filter& filter, std::int64_t last_time_ms, std::int64_t t, double q) {
    Filter f = filter;
    double dt = static_cast<double>(t - last_time_ms) / 1000;
    axis_predict(f.east, dt, q);
    axis_predict(f.north, dt, q);
    return f;
}


} // namespace corr
