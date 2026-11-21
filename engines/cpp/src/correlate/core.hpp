// What every correlate method shares (correlate.md "What the correlator
// does"): the pack, the frame reference and the entities, with the
// operations on them that more than one method uses.
#pragma once

#include <cstdint>
#include <deque>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "correlate/entity.hpp"
#include "correlate/motion.hpp"
#include "correlate/pack.hpp"
#include "model/json.hpp"
#include "model/output.hpp"

namespace corr::correlate {

struct Core {
    explicit Core(Pack pack);

    // Frame
    Point to_plane(double lat, double lon) const;
    std::pair<double, double> to_degrees(double east, double north) const;

    // Track estimate, Two-model filter and Restart: the pure functions of
    // correlate/motion.hpp applied to a stored entity.
    Filter predict(const Entity& e, std::int64_t t) const;
    Filter predict_for_comparison(const Entity& b, std::int64_t t) const;
    bool restart_test(const Entity& e, std::int64_t time_ms, const Point& z, const Point& r, Output& out) const;

    // Tests: one stage's tests in pack order, each to the trace, up to the
    // first failure. `extra`, when given, is an object whose keys are added
    // to each record.
    bool run_stage(const char* stage, const std::vector<TestSpec>& tests, const Entity& a, const Entity& b,
                   const Filter& b_pred, Output& out, const Json* extra = nullptr) const;

    // "On each tick", 1: above the stale time of the entity's source, or
    // the report's own stale_ms reached.
    bool is_stale(const Entity& e, std::int64_t now_ms) const;
    // "Stale time of a source": stale_ms, or with stale_rate k times the lower
    // median of the source's intervals within [floor_ms, ceiling_ms].
    double stale_time(const std::string& source) const;
    // With stale_rate: an accepted report of an existing entity of `source`,
    // `interval` ms after its previous one. Without it, nothing.
    void record_interval(const std::string& source, std::int64_t interval);
    // Snapshot `intervals`: each source with an interval, oldest first.
    Json intervals_json() const;

    // Snapshot: `filter`, `time` when the last report had a time error above
    // 0, and with `maneuver` also `models` and `mode`.
    void filter_json(const Entity& e, Json& into) const;

    Pack pack_;
    Motion motion_;                                   // of pack_
    std::optional<std::pair<double, double>> ref_;   // lat0, lon0
    std::map<std::string, Entity> entities_;         // key order
    std::map<std::string, std::deque<std::int64_t>> intervals_;   // stale_rate: per source, the last n
};

} // namespace corr::correlate
