// filter.md "Conditions": one row of the Conditions table per condition: the
// value, the limit and the result (true, false or unknown) before negation.
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>

#include "filter/geometry.hpp"
#include "filter/pack.hpp"
#include "model/json.hpp"

namespace corr::filter {

// The stored state of one entity (filter.md "Snapshot", "Rules" step 4).
struct EntityState : Fix {
    std::optional<std::int64_t> stale_ms;
    std::optional<std::int64_t> kept_ms;   // null until a report is kept
};

enum class Result { True, False, Unknown };

struct Evaluation {
    Result result = Result::False;
    Json value, limit;
};

// Evaluates condition `c` on report `r`. `own` is the state of the report's
// entity before this report, or null; `entities` every stored entity, for
// `near`. A pure function of its arguments.
Evaluation evaluate(const Condition& c, const Json& r, const EntityState* own,
                    const std::map<std::string, EntityState>& entities);

} // namespace corr::filter
