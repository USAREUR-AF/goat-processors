// Small helpers shared by engine.cpp (correlate.md) and assign.cpp
// (correlate-assign.md). Internal to the engine.
#pragma once

#include <cmath>
#include <optional>
#include <string>

#include "engine.hpp"
#include "json.hpp"

namespace corr::detail {

// correlate.md "Frame".
constexpr double R = 6371008.8;
constexpr double PI = 3.141592653589793;
inline double rad(double x) { return x * PI / 180; }
inline double deg(double x) { return x * 180 / PI; }
inline double wrap180(double lon) {
    while (lon > 180) lon -= 360;
    while (lon <= -180) lon += 360;
    return lon;
}

// Report values; a null value counts as absent.
inline std::optional<double> number_at(const Json& r, const std::string& key) {
    const Json* v = r.find(key);
    if (!v || !v->is_number()) return std::nullopt;
    return v->number;
}

// correlate.md "Reports": `time_ms` and `stale_ms` must be integers.
inline bool is_integer(const Json* v) { return v && v->is_number() && v->is_int; }

inline Json axis_json(const Axis& a) {
    Json j = Json::make_array();
    for (double x : {a.p, a.v, a.pp, a.pv, a.vv}) j.push(x);
    return j;
}

inline Json filter_json_of(const Filter& f) {
    Json j = Json::make_object();
    j["east"] = axis_json(f.east);
    j["north"] = axis_json(f.north);
    return j;
}

inline Json event(const char* ev) {
    Json e = Json::make_object();
    e["ev"] = ev;
    return e;
}

// course = deg(atan2(ve, vn)) in [0, 360).
inline double course_of(double ve, double vn) {
    double course = deg(std::atan2(ve, vn));
    if (course < 0) course += 360;
    if (course >= 360) course -= 360;
    return course;
}

} // namespace corr::detail
