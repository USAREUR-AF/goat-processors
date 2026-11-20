// correlate.md "Track estimate": the per-entity constant-velocity filter,
// one per axis. Shared by correlate, fuse (fuse.md "Shared with
// correlate.md") and quality (quality.md "Frame and filter"), so the three
// run the same filter with the same operations.
#pragma once

#include <cstdint>
#include <optional>

#include "model/frame.hpp"
#include "model/json.hpp"

namespace corr {

// The `filter` line of a correlate, fuse or quality pack.
struct FilterParams {
    double accel_var = 0;
    double default_ce_m = 0;
    double vel_sigma_ms = 0;
    double unknown_vel_ms = 0;
};

// One axis of the constant-velocity filter.
struct Axis {
    double p = 0, v = 0, pp = 0, pv = 0, vv = 0;
};

struct Filter {
    Axis east, north;
};

// correlate.md "Reports": the velocity measurement (east, north), when the
// report has both `course` and `speed_ms`.
std::optional<Point> measured_velocity(const Json& r);

// Every function below is pure: it returns a new value and changes none
// of its arguments.

// Step 1: the axis predicted by dt seconds with acceleration variance q.
Axis axis_predict(const Axis& a, double dt, double q);

// An axis after an update, with the innovation's likelihood term
// y*y/s + ln(s) (correlate.md "Two-model filter", step 3); callers without
// two models ignore it.
struct AxisUpdate {
    Axis axis;
    double term;
};
// Step 2: position update with measurement z and variance r.
AxisUpdate axis_position_update(const Axis& a, double z, double r);
// Step 3: velocity update with measurement z and variance r.
AxisUpdate axis_velocity_update(const Axis& a, double z, double r);

// Step 1 on both axes.
Filter filter_predict(const Filter& f, double dt, double q);
// Prediction from last_time_ms to t; dt may be negative.
Filter filter_predict(const Filter& filter, std::int64_t last_time_ms, std::int64_t t, double q);

// First report: position z with variance ce² on each axis, the measured
// velocity or 0.
Filter filter_first(const FilterParams& f, const Point& z, const std::optional<Point>& vel, double ce);
// Steps 2 and (with a velocity) 3 on each axis of an already predicted filter
// (quality.md "Samples": the filter is updated from the prediction that gave nis).
Filter filter_correct(const Filter& filter, const FilterParams& f, const Point& z, const std::optional<Point>& vel,
                      double ce);
// Later reports: steps 1, 2 and (with a velocity) 3 on each axis.
Filter filter_update(const Filter& filter, const FilterParams& f, const Point& z, const std::optional<Point>& vel,
                     double ce, double dt);

} // namespace corr
