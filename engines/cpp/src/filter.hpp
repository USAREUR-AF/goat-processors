// The filter engine (spec/filter.md "What the filter does"): ingest, tick,
// snapshot. load_pack is in filter_pack.hpp.
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>

#include "engine.hpp"  // Output
#include "filter_pack.hpp"
#include "json.hpp"

namespace corr::filter {

// The stored state of one entity (spec "Snapshot", "Rules" step 4).
struct EntityState {
    std::int64_t time_ms = 0;
    double lat = 0, lon = 0;
    std::optional<double> course, speed_ms;
    std::optional<std::int64_t> stale_ms;
    std::optional<std::int64_t> kept_ms;   // null until a report is kept
};

class Engine {
public:
    explicit Engine(Pack pack);

    Output ingest(const Json& report);
    Output tick(std::int64_t now_ms);
    Json snapshot() const;

private:
    enum class Result { True, False, Unknown };
    struct Evaluation {
        Result result = Result::False;
        Json value, limit;
    };

    Evaluation evaluate(const Condition& c, const Json& report, const EntityState* own) const;

    Pack pack_;
    std::map<std::string, EntityState> entities_;  // key order
};

} // namespace corr::filter
