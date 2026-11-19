// The local plane and the constant-velocity filter of spec/correlate.md,
// sections Frame and Track estimate. Shared by the correlate engine
// (engine.cpp) and the quality engine (quality.cpp).
#pragma once

#include <optional>

#include "json.hpp"
#include "pack.hpp"

namespace corr {

// ---- Frame -----------------------------------------------------------------

constexpr double EARTH_R = 6371008.8;
constexpr double PI = 3.141592653589793;
inline double rad(double x) { return x * PI / 180; }
inline double deg(double x) { return x * 180 / PI; }

// Brings a longitude into (-180, 180].
double wrap180(double lon);

// Metres east and north of the reference (lat0, lon0).
struct PlanePoint {
    double east, north;
};

PlanePoint to_plane(double lat0, double lon0, double lat, double lon);

// Velocity measurement: ve = speed * sin(rad(course)), vn = speed * cos(rad(course)).
PlanePoint velocity_of(double course, double speed_ms);

// ---- Track estimate --------------------------------------------------------

// One axis: position p, velocity v, symmetric covariance pp, pv, vv.
struct Axis {
    double p = 0, v = 0, pp = 0, pv = 0, vv = 0;
};

struct Filter {
    Axis east, north;
};

// Step 1, predict by dt seconds with process noise q.
void axis_predict(Axis& a, double dt, double q);
// Step 2, position update with measurement z and variance r.
void axis_position_update(Axis& a, double z, double r);
// Step 3, velocity update with measurement z and variance r.
void axis_velocity_update(Axis& a, double z, double r);

// First report: both axes from the measured position, velocity (or none) and ce.
void filter_first(Filter& f, const PlanePoint& z, const std::optional<PlanePoint>& vel, double ce,
                  const FilterParams& params);

// Steps 2 and (with a velocity) 3 on both axes of an already predicted filter.
void filter_correct(Filter& f, const PlanePoint& z, const std::optional<PlanePoint>& vel, double ce,
                    const FilterParams& params);

// Later reports: steps 1, 2 and (with a velocity) 3 on both axes.
void filter_update(Filter& f, const PlanePoint& z, const std::optional<PlanePoint>& vel, double ce,
                   double dt, const FilterParams& params);

// Prediction: step 1 on a copy.
Filter filter_predict(Filter f, double dt, double q);

// [p, v, pp, pv, vv], the snapshot form of an axis.
Json axis_json(const Axis& a);

} // namespace corr
