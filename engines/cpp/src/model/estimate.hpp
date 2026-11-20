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

// Step 1, predict by dt seconds with acceleration variance q.
void axis_predict(Axis& a, double dt, double q);
// Step 2, position update with measurement z and variance r. Returns the
// innovation's likelihood term y*y/s + ln(s) (correlate.md "Two-model filter",
// step 3); callers without two models ignore it.
double axis_position_update(Axis& a, double z, double r);
// Step 3, velocity update with measurement z and variance r. Returns the
// likelihood term, as step 2.
double axis_velocity_update(Axis& a, double z, double r);

// First report.
Filter filter_first(const FilterParams& f, const Point& z, const std::optional<Point>& vel, double ce);
// Steps 2 and (with a velocity) 3 on both axes of an already predicted filter
// (quality.md "Samples": the filter is updated from the prediction that gave nis).
void filter_correct(Filter& filter, const FilterParams& f, const Point& z, const std::optional<Point>& vel,
                    double ce);
// Later reports: steps 1, 2 and (with a velocity) 3 on each axis.
void filter_update(Filter& filter, const FilterParams& f, const Point& z, const std::optional<Point>& vel,
                   double ce, double dt);
// Prediction from last_time_ms to t, on a copy; dt may be negative.
Filter filter_predict(const Filter& filter, std::int64_t last_time_ms, std::int64_t t, double q);

} // namespace corr
