// The parts of correlate.md that more than one function uses: Frame and
// Track estimate (the per-entity filter); Reports is in report.hpp. The
// correlate engine (engine.cpp) and the fuse engine (fuse.cpp) both use these,
// so the two functions run the same filter with the same operations.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <utility>

#include "json.hpp"
#include "pack.hpp"

namespace corr {

// ---- correlate.md "Frame" --------------------------------------------------

constexpr double EARTH_R = 6371008.8;
constexpr double PI = 3.141592653589793;
inline double rad(double x) { return x * PI / 180; }
inline double deg(double x) { return x * 180 / PI; }
// Brings a longitude into (-180, 180].
double wrap180(double lon);

struct Point {
    double east, north;
};

// Degrees to metres east and north of the reference (lat0, lon0).
Point to_plane(double lat0, double lon0, double lat, double lon);
// Metres east and north of the reference back to (lat, lon) in degrees.
std::pair<double, double> to_degrees(double lat0, double lon0, double east, double north);

// ---- correlate.md "Reports" ------------------------------------------------

// How a key is read (number_at, ce_at, is_integer, missing_required) is in
// report.hpp, shared with the filter.

// The velocity measurement (east, north), when the report has both `course`
// and `speed_ms`.
std::optional<Point> measured_velocity(const Json& r);

// ---- correlate.md "Track estimate" -----------------------------------------

// One axis of the constant-velocity filter.
struct Axis {
    double p = 0, v = 0, pp = 0, pv = 0, vv = 0;
};

struct Filter {
    Axis east, north;
};

// Step 1, predict by dt seconds with acceleration variance q.
void axis_predict(Axis& a, double dt, double q);
// Step 2, position update with measurement z and variance r.
void axis_position_update(Axis& a, double z, double r);
// Step 3, velocity update with measurement z and variance r.
void axis_velocity_update(Axis& a, double z, double r);

// First report.
Filter filter_first(const FilterParams& f, const Point& z, const std::optional<Point>& vel, double ce);
// Later reports: steps 1, 2 and (with a velocity) 3 on each axis.
void filter_update(Filter& filter, const FilterParams& f, const Point& z, const std::optional<Point>& vel,
                   double ce, double dt);
// Prediction from last_time_ms to t, on a copy; dt may be negative.
Filter filter_predict(const Filter& filter, std::int64_t last_time_ms, std::int64_t t, double q);

// `[p, v, pp, pv, vv]`, the snapshot form of one axis.
Json axis_json(const Axis& a);

} // namespace corr
