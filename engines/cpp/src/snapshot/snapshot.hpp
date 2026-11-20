// The parts of a snapshot more than one function writes (correlate.md,
// fuse.md, quality.md "Snapshot").
#pragma once

#include <optional>
#include <utility>

#include "model/estimate.hpp"
#include "model/json.hpp"

namespace corr::snapshot {

// `[p, v, pp, pv, vv]`, the snapshot form of one axis.
Json axis_json(const Axis& a);

// `{"east": [...], "north": [...]}`, the snapshot form of a filter.
Json filter_json(const Filter& f);

// `ref`: `[lat0, lon0]`, or null before the first accepted report.
Json ref_json(const std::optional<std::pair<double, double>>& ref);

} // namespace corr::snapshot
