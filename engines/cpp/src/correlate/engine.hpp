// The correlate function (correlate.md "What the correlator does", version
// 0.8, and correlate-assign.md version 0.6): load_pack (in correlate/pack.hpp),
// then ingest, tick and snapshot.
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "assign/bias.hpp"
#include "assign/membership.hpp"
#include "assign/ranking.hpp"
#include "correlate/entity.hpp"
#include "correlate/pack.hpp"
#include "model/estimate.hpp"
#include "model/json.hpp"
#include "model/output.hpp"

namespace corr::correlate {

class Engine {
public:
    explicit Engine(Pack pack);

    Output ingest(const Json& report);
    Output tick(std::int64_t now_ms);
    Json snapshot() const;

private:
    struct TestResult { Json value, limit; bool pass; bool skipped; };

    // Frame
    Point to_plane(double lat, double lon) const;
    std::pair<double, double> to_degrees(double east, double north) const;

    // Track estimate and Two-model filter
    MeasurementVariance measurement_variance(const Entity* e, std::int64_t time_ms,
                                             const std::optional<Point>& vel, double ce, double te) const;
    void filter_first(Entity& e, const Point& z, const std::optional<Point>& vel, const Point& r) const;
    void filter_update(Entity& e, const Point& z, const std::optional<Point>& vel, const Point& r, double dt,
                       Output& out) const;
    Filter predict(const Entity& e, std::int64_t t) const;
    Filter predict_for_comparison(const Entity& b, std::int64_t t) const;
    bool restart_test(const Entity& e, std::int64_t time_ms, const Point& z, const Point& r, Output& out) const;

    // Tests
    double ce_of(const Entity& e) const;
    double d2(const Entity& a, const Filter& b_pred) const;
    TestResult run_test(const TestSpec& t, const Entity& a, const Entity& b, const Filter& b_pred) const;
    bool run_stage(const char* stage, const std::vector<TestSpec>& tests, const Entity& a, const Entity& b,
                   const Filter& b_pred, Output& out, const Json* extra = nullptr) const;

    // Association
    void hold(Entity& a, Output& out);
    void associate(Entity& a, Output& out);
    void leave_group(Entity& e, const char* reason, Output& out);
    bool group_has_source(int g, const std::string& source) const;
    bool is_stale(const Entity& e, std::int64_t now_ms) const;

    // Method confirm, in confirm.cpp
    Output tick_confirm(std::int64_t now_ms);
    Json snapshot_confirm() const;

    // Method assign (correlate-assign.md), in assign/
    Output tick_assign(std::int64_t now_ms);
    Filter fuse(const std::set<std::string>& members, std::int64_t t, const Entity* frame = nullptr) const;
    BiasState bias_state(const std::string& pair) const;
    Filter predict_into_frame(const Entity& a, const Entity& b, std::int64_t t) const;
    void bias_update(std::int64_t now_ms, const std::set<std::string>& rows, Output& out);
    void fit_time_offset(BiasState& st, const double r[2], const double v[2], const double y[2]) const;
    std::vector<RankedAssignment> rank_source(const std::vector<std::string>& rows, const Membership& m,
                                              int h, std::vector<int>& columns,
                                              std::vector<std::vector<double>>& entries, Output& out) const;
    void apply_assignment(const std::vector<std::string>& rows, const std::vector<int>& columns,
                          const RankedAssignment& r, Record& rec) const;
    void system_output(std::int64_t now_ms, const Membership& reported, Output& out) const;
    Json snapshot_assign() const;

    static std::string group_name(int g) { return "g" + std::to_string(g); }
    static std::pair<std::string, std::string> pair_key(const std::string& a, const std::string& b) {
        return a < b ? std::make_pair(a, b) : std::make_pair(b, a);
    }
    void filter_json(const Entity& e, Json& into) const;   // snapshot `filter`, `models`, `mode`

    Pack pack_;
    std::optional<std::pair<double, double>> ref_;          // lat0, lon0
    std::map<std::string, Entity> entities_;                // key order
    std::map<int, std::set<std::string>> groups_;           // creation order, members in key order
    std::map<std::pair<std::string, std::string>, std::int64_t> counts_;
    int next_group_ = 1;

    // Method assign
    Membership committed_;
    std::vector<History> histories_ = {History{}};           // rank order
    std::set<std::string> retiring_;
    std::set<std::string> reported_;                        // accepted a report since the previous tick
    std::set<std::string> restarted_;                       // filter started again since the previous tick
    std::map<std::string, BiasState> bias_;                 // stored pair states, by "<S>|<T>"
};

} // namespace corr::correlate
