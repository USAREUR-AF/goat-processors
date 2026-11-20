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

Axis axis_predict(const Axis& b, double dt, double q) {
    Axis a = b;
    a.p = b.p + b.v * dt;
    a.pp = b.pp + 2 * dt * b.pv + dt * dt * b.vv + q * (dt * dt * dt * dt) / 4;
    a.pv = b.pv + dt * b.vv + q * (dt * dt * dt) / 2;
    a.vv = b.vv + q * (dt * dt);
    return a;
}

AxisUpdate axis_position_update(const Axis& b, double z, double r) {
    Axis a;
    double s = b.pp + r, k1 = b.pp / s, k2 = b.pv / s, y = z - b.p;
    a.p = b.p + k1 * y;
    a.v = b.v + k2 * y;
    a.pp = (1 - k1) * b.pp;
    a.pv = (1 - k1) * b.pv;
    a.vv = b.vv - k2 * b.pv;
    return {a, y * y / s + std::log(s)};
}

AxisUpdate axis_velocity_update(const Axis& b, double z, double r) {
    Axis a;
    double s = b.vv + r, k1 = b.pv / s, k2 = b.vv / s, y = z - b.v;
    a.p = b.p + k1 * y;
    a.v = b.v + k2 * y;
    a.pp = b.pp - k1 * b.pv;
    a.pv = (1 - k2) * b.pv;
    a.vv = (1 - k2) * b.vv;
    return {a, y * y / s + std::log(s)};
}

Filter filter_predict(const Filter& f, double dt, double q) {
    return {axis_predict(f.east, dt, q), axis_predict(f.north, dt, q)};
}

Filter filter_predict(const Filter& filter, std::int64_t last_time_ms, std::int64_t t, double q) {
    return filter_predict(filter, static_cast<double>(t - last_time_ms) / 1000, q);
}

Filter filter_first(const FilterParams& f, const Point& z, const std::optional<Point>& vel, double ce) {
    double vv = vel ? f.vel_sigma_ms * f.vel_sigma_ms : f.unknown_vel_ms * f.unknown_vel_ms;
    Filter out;
    out.east = {z.east, vel ? vel->east : 0.0, ce * ce, 0.0, vv};
    out.north = {z.north, vel ? vel->north : 0.0, ce * ce, 0.0, vv};
    return out;
}

namespace {

// Steps 2 and (with a velocity) 3 on one axis.
Axis correct_axis(const Axis& a, double z, const double* vel, double r, double r_vel) {
    Axis out = axis_position_update(a, z, r).axis;
    return vel ? axis_velocity_update(out, *vel, r_vel).axis : out;
}

} // namespace

Filter filter_correct(const Filter& filter, const FilterParams& f, const Point& z, const std::optional<Point>& vel,
                      double ce) {
    const double r = ce * ce, r_vel = f.vel_sigma_ms * f.vel_sigma_ms;
    return {correct_axis(filter.east, z.east, vel ? &vel->east : nullptr, r, r_vel),
            correct_axis(filter.north, z.north, vel ? &vel->north : nullptr, r, r_vel)};
}

Filter filter_update(const Filter& filter, const FilterParams& f, const Point& z, const std::optional<Point>& vel,
                     double ce, double dt) {
    return filter_correct(filter_predict(filter, dt, f.accel_var), f, z, vel, ce);
}

} // namespace corr
