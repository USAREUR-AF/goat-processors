// fuse.md "Reports" and "Groups": what fuse keeps of one entity, a group at
// a tick, and the rank of a source (fuse.md "Kinematics", "Rank").
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "model/estimate.hpp"
#include "model/json.hpp"

namespace corr::fuse {

struct Entity {
    std::string key;
    std::string source;                    // track.source_id
    std::int64_t last_time_ms = 0;
    Filter filter;                         // correlate.md "Track estimate"
    Json report;                           // the last normalized report
    std::optional<std::string> group;      // fuse.group of that report; nullopt is its own unnamed group
};

// One group at a tick: its name (nullopt for an unnamed group) and its
// members in key order.
struct Group {
    std::optional<std::string> name;
    std::vector<const Entity*> members;
};

// The index of `source` among the pack's `source` lines, or nullopt when it
// is not listed.
inline std::optional<std::int64_t> rank(const std::vector<std::string>& sources, const std::string& source) {
    for (size_t i = 0; i < sources.size(); ++i)
        if (sources[i] == source) return static_cast<std::int64_t>(i);
    return std::nullopt;
}

// Rank for comparison: an unlisted source ranks after every listed source.
inline std::int64_t rank_order(const std::vector<std::string>& sources, const std::string& source) {
    return rank(sources, source).value_or(static_cast<std::int64_t>(sources.size()));
}

} // namespace corr::fuse
