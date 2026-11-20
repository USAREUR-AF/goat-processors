// correlate-assign.md "Sensor bias": the stored state of one pair of sources.
#pragma once

#include <cstdint>

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

} // namespace corr::correlate
