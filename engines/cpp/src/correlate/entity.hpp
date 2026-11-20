// What correlate keeps of one entity (correlate.md "Track estimate",
// "Two-model filter", "Snapshot"; correlate-assign.md "Snapshot").
#pragma once

#include <cstdint>
#include <string>

#include "model/estimate.hpp"
#include "model/json.hpp"

namespace corr::correlate {

struct Entity {
    std::string key;
    std::string source;
    std::int64_t last_time_ms = 0;
    Filter filter;             // with `maneuver`, the combination of the two models
    Filter models[2];          // with `maneuver`: quiet (index 0), maneuver (index 1)
    double mu[2] = {0, 0};     // with `maneuver`: mu1, mu2
    Json last;                 // the last accepted report
    // correlate.md "Track estimate", Measurement variance, of the last report:
    double time_error_ms = 0;  // its time error te (Reports, "Time quality")
    std::string time_state = "coherent";   // its time state; read by no step of correlate
    Point r = {0, 0};          // r_east, r_north
    Point timing = {0, 0};     // timing variance (v_e*ts)², (v_n*ts)²; 0 and 0 when te is 0
    int group = 0;             // group number, 0 when ungrouped
    std::int64_t hold_failures = 0;
    int system = 0;            // method assign: committed system track number, 0 when none
};

// correlate.md "Track estimate", Measurement variance: what one report gives.
struct MeasurementVariance {
    Point r;        // r_east, r_north
    Point timing;   // (v_e*ts)², (v_n*ts)²; 0 and 0 when te is 0
};

} // namespace corr::correlate
