// quality.md "Rules" (Evaluation) and "Forwarding": pure functions of a
// rule, its state and the measures, and of the actions in force.
#pragma once

#include <optional>
#include <string>
#include <vector>

#include "model/json.hpp"
#include "quality/pack.hpp"

namespace corr::quality {

// "Rules": per rule, per subject.
struct RuleState {
    std::int64_t count = 0;
    bool active = false;
};

// One rule evaluated on one subject: its state after, its `action-start` or
// `action-end` event if any, and its trace record.
struct RuleStep {
    RuleState state;
    std::optional<Json> event;
    Json trace;
};
RuleStep evaluate_rule(const Rule& rule, const RuleState& before, const std::string& subject,
                       const Json& measures);

// "Forwarding": the pass event for an accepted report of entity `key`, given
// the actions in force other than alert, in pack order.
Json forward(const std::vector<const Rule*>& acting, const Json& report, const std::string& key,
             double default_ce_m);

} // namespace corr::quality
