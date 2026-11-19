#include "track.hpp"

#include <cmath>

namespace corr {

// ---- Frame -----------------------------------------------------------------

double wrap180(double lon) {
    while (lon > 180) lon -= 360;
    while (lon <= -180) lon += 360;
    return lon;
}

Point to_plane(double lat0, double lon0, double lat, double lon) {
    double dlon = wrap180(lon - lon0);
    return {EARTH_R * rad(dlon) * std::cos(rad(lat0)), EARTH_R * rad(lat - lat0)};
}

std::pair<double, double> to_degrees(double lat0, double lon0, double east, double north) {
    double lat = lat0 + deg(north / EARTH_R);
    double lon = lon0 + deg(east / (EARTH_R * std::cos(rad(lat0))));
    return {lat, wrap180(lon)};
}

// ---- Reports ---------------------------------------------------------------

std::optional<double> number_at(const Json& r, const std::string& key) {
    const Json* v = r.find(key);
    if (!v || !v->is_number()) return std::nullopt;
    return v->number;
}

std::optional<double> ce_at(const Json& r) {
    auto ce = number_at(r, "ce");
    if (ce && *ce <= 0) return std::nullopt;
    return ce;
}

bool is_integer(const Json* v) { return v && v->is_number() && v->is_int; }

std::optional<std::string> missing_required(const Json& r) {
    const std::pair<const char*, char> required[] = {
        {"track.source_id", 's'}, {"uid", 's'}, {"time_ms", 'i'}, {"lat", 'n'}, {"lon", 'n'}};
    for (const auto& req : required) {
        const Json* v = r.find(req.first);
        bool ok = req.second == 's' ? v && v->is_string()
                : req.second == 'i' ? is_integer(v)
                                    : v && v->is_number();
        if (!ok) return std::string(req.first);
    }
    return std::nullopt;
}

std::optional<Point> measured_velocity(const Json& r) {
    auto course = number_at(r, "course"), speed = number_at(r, "speed_ms");
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

Filter filter_first(const FilterParams& f, const Point& z, const std::optional<Point>& vel, double ce) {
    double vv = vel ? f.vel_sigma_ms * f.vel_sigma_ms : f.unknown_vel_ms * f.unknown_vel_ms;
    Filter out;
    out.east = {z.east, vel ? vel->east : 0.0, ce * ce, 0.0, vv};
    out.north = {z.north, vel ? vel->north : 0.0, ce * ce, 0.0, vv};
    return out;
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

Json axis_json(const Axis& a) {
    Json j = Json::make_array();
    for (double x : {a.p, a.v, a.pp, a.pv, a.vv}) j.push(x);
    return j;
}

} // namespace corr
