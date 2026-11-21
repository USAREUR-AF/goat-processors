// The math of correlate.md "Track estimate", "Two-model filter" and
// "Restart", and of the Tests' d², as pure functions: each returns a new
// value and changes none of its arguments.
#pragma once

#include <optional>

#include "correlate/entity.hpp"
#include "correlate/pack.hpp"
#include "model/estimate.hpp"

namespace corr::correlate {

// What prediction and update read of the pack.
struct Motion {
    FilterParams filter;
    std::optional<ManeuverParams> maneuver;   // two models when present
};

inline Motion motion_of(const Pack& p) { return {p.filter, p.maneuver}; }

// "Two-model filter", step 1: blend(w1, w2) of two filters.
Filter blend(double w1, double w2, const Filter& m1, const Filter& m2);

// "Track estimate", Prediction, dt seconds ahead. With two models each is
// predicted with its own q and the two are blended with the current mu.
Filter predict(const Track& t, const Motion& m, double dt);

// First report: per axis pp = r, that axis's measurement variance; with two
// models both are this filter, with the long-run share of each model.
Track first_track(const Motion& m, const Point& z, const std::optional<Point>& vel, const Point& r);

// A later report, dt seconds after the last: the track after "Track
// estimate" steps 1 to 3 (one model) or "Two-model filter" steps 1 to 5,
// and with two models each model's likelihood lambda.
struct TrackUpdate {
    Track track;
    double lambda[2] = {0, 0};
};
TrackUpdate update_track(const Track& t, const Motion& m, const Point& z, const std::optional<Point>& vel,
                         const Point& r, double dt);

// "Track estimate", Measurement variance of a report with ce, time error te
// (ms) and velocity v (the entity's predicted velocity, the measured one for
// a first report, or 0).
MeasurementVariance measurement_variance(double ce, double te, const Point& v);

// "Track estimate": a prediction for comparison, the timing variance added
// to pp on each axis.
Filter for_comparison(Filter predicted, const Point& timing);

// d² = sum over east, north of (z - p)² / (pp + r): "Tests" (z A's position,
// r A's measurement variance, the filter B's prediction for comparison) and
// "Restart" (z the report, r its measurement variance, the filter the
// entity's prediction).
double d2(const Point& z, const Point& r, const Filter& p);

// "Tests", the `state` test, per axis: the difference of A's filter axis
// `a` (with A's timing variance `ta`) and B's prediction for comparison `b`,
// and its full-state statistic q. Also one report's evidence of "Sequential
// test" (Association), which adds `tpp`, `tvv`.
struct StateAxis {
    double dp, dv, spp, spv, svv, det, q;
};
StateAxis state_axis(const Axis& a, double ta, const Axis& b);

// "Association", Sequential test: one report's evidence for A (filter `a`,
// timing variance `ta`, last `hae` `ha`) against B's prediction for
// comparison `bp` (last `hae` `hb`): the increment of L and the record's d2.
struct SprtEvidence {
    double increment, d2;
};
SprtEvidence sprt_evidence(const Filter& a, const Point& ta, const Filter& bp, const std::optional<double>& ha,
                           const std::optional<double>& hb, const SprtParams& sp);

// "Tests": d² of A against B's prediction for comparison `bp`.
inline double d2(const Entity& a, const Filter& bp) { return d2({a.filter.east.p, a.filter.north.p}, a.r, bp); }

} // namespace corr::correlate
