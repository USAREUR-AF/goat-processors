// Small helpers shared by engine.cpp (correlate.md) and assign.cpp
// (correlate-assign.md). Internal to the engine.
#pragma once

#include <cmath>
#include <optional>
#include <string>

#include "engine.hpp"
#include "json.hpp"
#include "report.hpp"
#include "track.hpp"

namespace corr::detail {

// correlate.md "Frame" (rad, deg, wrap180), the filter steps and `axis_json`
// are in track.hpp; the Reports helpers are in report.hpp, both shared with
// filter, fuse and quality.
using report::is_integer;
using report::number_at;

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
