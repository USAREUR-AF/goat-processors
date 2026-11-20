// The quality function (quality.md, version 0.2): load_pack (in
// quality/pack.hpp), then ingest, tick and snapshot.
//
// Quality measures every entity and every source from the reports alone and
// applies the actions a pack's rules attach to those measures. It reuses the
// correlate frame and filter (model/estimate.hpp).
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "model/estimate.hpp"
#include "model/json.hpp"
#include "model/output.hpp"
#include "quality/entity.hpp"
#include "quality/pack.hpp"
#include "quality/rules.hpp"

namespace corr::quality {

// ---- Engine ----------------------------------------------------------------

class Engine {
public:
    explicit Engine(Pack pack);

    Output ingest(const Json& report);
    Output tick(std::int64_t now_ms);
    Json snapshot() const;

private:
    // Spec "Rules", Evaluation, for every rule of `scope` on one subject.
    void evaluate_rules(Scope scope, const std::string& subject, const Json& measures, Output& out);

    // Spec "Tick" steps 2 and 3: end the active rules of `scope` for a subject and drop its states.
    void forget_subject(Scope scope, const std::string& subject, Output& out);

    // Spec "Forwarding": the pass event for an accepted report.
    Json pass_event(const Json& report, const std::string& key, const std::string& source) const;

    bool in_force(size_t rule_index, const std::string& key, const std::string& source) const;

    Pack pack_;
    std::optional<std::pair<double, double>> ref_;     // lat0, lon0
    std::optional<std::int64_t> last_tick_;
    std::map<std::string, Entity> entities_;           // key order
    std::vector<std::map<std::string, RuleState>> rule_states_;   // per rule in pack order, subject in key order
};

} // namespace corr::quality
