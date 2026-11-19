#include "kalman.hpp"

#include <cmath>

namespace corr {

// ---- Frame (correlate.md "Frame") ------------------------------------------

double wrap180(double lon) {
    while (lon > 180) lon -= 360;
    while (lon <= -180) lon += 360;
    return lon;
}

PlanePoint to_plane(double lat0, double lon0, double lat, double lon) {
    double dlon = wrap180(lon - lon0);
    return {EARTH_R * rad(dlon) * std::cos(rad(lat0)), EARTH_R * rad(lat - lat0)};
}

PlanePoint velocity_of(double course, double speed_ms) {
    return {speed_ms * std::sin(rad(course)), speed_ms * std::cos(rad(course))};
}

// ---- Track estimate (correlate.md "Track estimate") ------------------------

void axis_predict(Axis& a, double dt, double q) {
    const Axis b = a;
    a.p = b.p + b.v * dt;
    a.pp = b.pp + 2 * dt * b.pv + dt * dt * b.vv + q * (dt * dt * dt * dt) / 4;
    a.pv = b.pv + dt * b.vv + q * (dt * dt * dt) / 2;
    a.vv = b.vv + q * (dt * dt);
}

void axis_position_update(Axis& a, double z, double r) {
    const Axis b = a;
    double s = b.pp + r, k1 = b.pp / s, k2 = b.pv / s, y = z - b.p;
    a.p = b.p + k1 * y;
    a.v = b.v + k2 * y;
    a.pp = (1 - k1) * b.pp;
    a.pv = (1 - k1) * b.pv;
    a.vv = b.vv - k2 * b.pv;
}

void axis_velocity_update(Axis& a, double z, double r) {
    const Axis b = a;
    double s = b.vv + r, k1 = b.pv / s, k2 = b.vv / s, y = z - b.v;
    a.p = b.p + k1 * y;
    a.v = b.v + k2 * y;
    a.pp = b.pp - k1 * b.pv;
    a.pv = (1 - k2) * b.pv;
    a.vv = (1 - k2) * b.vv;
}

void filter_first(Filter& f, const PlanePoint& z, const std::optional<PlanePoint>& vel, double ce,
                  const FilterParams& params) {
    double vv = vel ? params.vel_sigma_ms * params.vel_sigma_ms : params.unknown_vel_ms * params.unknown_vel_ms;
    f.east = {z.east, vel ? vel->east : 0.0, ce * ce, 0.0, vv};
    f.north = {z.north, vel ? vel->north : 0.0, ce * ce, 0.0, vv};
}

void filter_correct(Filter& f, const PlanePoint& z, const std::optional<PlanePoint>& vel, double ce,
                    const FilterParams& params) {
    for (int axis = 0; axis < 2; ++axis) {
        Axis& a = axis == 0 ? f.east : f.north;
        axis_position_update(a, axis == 0 ? z.east : z.north, ce * ce);
        if (vel)
            axis_velocity_update(a, axis == 0 ? vel->east : vel->north,
                                 params.vel_sigma_ms * params.vel_sigma_ms);
    }
}

void filter_update(Filter& f, const PlanePoint& z, const std::optional<PlanePoint>& vel, double ce,
                   double dt, const FilterParams& params) {
    f = filter_predict(f, dt, params.accel_var);
    filter_correct(f, z, vel, ce, params);
}

Filter filter_predict(Filter f, double dt, double q) {
    axis_predict(f.east, dt, q);
    axis_predict(f.north, dt, q);
    return f;
}

Json axis_json(const Axis& a) {
    Json j = Json::make_array();
    for (double x : {a.p, a.v, a.pp, a.pv, a.vv}) j.push(x);
    return j;
}

} // namespace corr
