// What quality keeps of one entity (quality.md "Samples", "Window", "Snapshot").
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "model/estimate.hpp"
#include "model/json.hpp"

namespace corr::quality {

// Spec "Samples": one accepted report, as kept in its entity's window.
struct Record {
    std::int64_t wt = 0;
    std::int64_t time_ms = 0;
    std::string order;                      // first, advance, duplicate, out-of-order
    std::optional<std::int64_t> interval;
    std::optional<std::int64_t> latency;
    Json lateness;                          // null when not taken; an integer, or a binary64 when the clock is a mean of two
    bool source_out_of_order = false;       // the source_order sample is out-of-order
    std::optional<double> time_error;       // ms, stated by the report or the pack's time_default
    std::optional<std::string> time_state;  // coherent, drifting, free-running; absent when unstated
    std::optional<double> nis;
    std::optional<double> speed_err;
    bool ce = false, vel = false, hae = false;
};

struct Entity {
    std::string source;                     // track.source_id of its first report
    std::int64_t last = 0;                  // latest accepted time (`last`)
    Point last_pos{0, 0};              // plane position of its latest first/advance report
    Filter filter;
    std::vector<Record> window;             // arrival order
};

} // namespace corr::quality
