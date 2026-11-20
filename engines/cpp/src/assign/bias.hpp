// correlate-assign.md "Sensor bias" (with "Time offset"): the stored state of
// one pair of sources and the pure functions that read and update it.
#pragma once

#include <cstdint>
#include <optional>

#include "correlate/pack.hpp"
#include "model/estimate.hpp"

namespace corr::correlate {

struct BiasState {
    double o[2] = {0, 0};   // offset, east and north
    double w[2] = {0, 0};   // weight sum, east and north
    double var = 0;         // one variance for both axes
    std::int64_t n = 0;     // count of accepted pairs
    // "Time offset", with `time_offset`: the clock offset tau in seconds and
    // the sums S1 to S8 (S[0] is S1).
    double tau = 0;
    double S[8] = {0, 0, 0, 0, 0, 0, 0, 0};
};

// "State": a pair with no stored state reads as o = 0, w = 0, var = s², n = 0.
BiasState initial_bias(const BiasParams& b);

// "Moving B into A's frame": `f` (B's prediction for comparison) moved by the
// pair's state: p + o when B's source is first in key order, else p - o, on
// each axis, with pp + var. With `timed` (`time_offset`) the offset on each
// axis is o - v*tau, v B's predicted velocity on that axis.
Filter move_into_frame(Filter f, const BiasState& st, bool b_first, bool timed);

// "Update", steps 1 to 3 for one pair: `fs` and `ft` the predictions of the
// entity whose source is first in key order (ES) and of the other (ET).
struct PairUpdate {
    BiasState state;   // after step 3; the input state when refused
    double d2 = 0;
    bool accepted = false;
};
PairUpdate update_pair(const BiasState& st, const Filter& fs, const Filter& ft, const BiasParams& b,
                       const std::optional<double>& time_offset_sigma_ms);

} // namespace corr::correlate
