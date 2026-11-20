// quality.md "Entity measures" and "Source measures": pure functions of
// the window and of the entity measures.
#pragma once

#include <cstdint>
#include <vector>

#include "model/json.hpp"
#include "quality/entity.hpp"

namespace corr::quality {

// An object, one key per entity measure, of entity `e` at now_ms; a
// statistic is null when fewer than min_samples records hold its sample.
Json entity_measures(const Entity& e, std::int64_t now_ms, std::int64_t min_samples);

// An object, one key per source measure, over the measures of the source's
// entities in key order.
Json source_measures(const std::vector<const Json*>& entity_measures);

} // namespace corr::quality
