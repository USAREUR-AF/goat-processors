// quality.md "Input clock": pure functions of the entities as they are
// before a report is taken.
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>

#include "model/json.hpp"
#include "quality/entity.hpp"

namespace corr::quality {

// The median of the other sources' latest times (an integer, or a binary64
// when it is the mean of two), or absent when there is no other source.
std::optional<Json> input_clock(const std::map<std::string, Entity>& entities, const std::string& source);

// The greatest `last` among the entities of `source`, or absent.
std::optional<std::int64_t> source_latest(const std::map<std::string, Entity>& entities, const std::string& source);

} // namespace corr::quality
