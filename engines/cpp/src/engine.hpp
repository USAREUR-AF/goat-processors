// The correlator engine: ingest, tick, snapshot (spec "What the correlator does").
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "json.hpp"
#include "pack.hpp"
#include "track.hpp"

namespace corr {

struct Entity {
    std::string key;
    std::string source;
    std::int64_t last_time_ms = 0;
    Filter filter;
    Json last;                 // the last accepted report
    int group = 0;             // group number, 0 when ungrouped
    std::int64_t hold_failures = 0;
    int system = 0;            // method assign: system track number, 0 when none
};

// The events and trace one call returns.
struct Output {
    Json events = Json::make_array();
    Json trace = Json::make_array();
};

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

    // Track estimate
    void filter_first(Entity& e, const Point& z, const std::optional<Point>& vel, double ce) const;
    void filter_update(Entity& e, const Point& z, const std::optional<Point>& vel, double ce, double dt) const;
    Filter predict(const Entity& e, std::int64_t t) const;

    // Tests
    double ce_of(const Entity& e) const;
    double d2(const Entity& a, const Filter& b_pred) const;
    TestResult run_test(const TestSpec& t, const Entity& a, const Entity& b, const Filter& b_pred) const;
    bool run_stage(const char* stage, const std::vector<TestSpec>& tests, const Entity& a, const Entity& b,
                   const Filter& b_pred, Output& out) const;

    // Association
    void hold(Entity& a, Output& out);
    void associate(Entity& a, Output& out);
    void leave_group(Entity& e, const char* reason, Output& out);
    bool group_has_source(int g, const std::string& source) const;

    // Method assign (correlate-assign.md)
    Output tick_assign(std::int64_t now_ms);
    Filter fuse(const std::vector<const Entity*>& members, std::int64_t t) const;
    void assign_source(const std::vector<std::string>& reported, Output& out);
    void leave_system(Entity& e, const char* reason, Output& out);
    Json snapshot_assign() const;
    static std::string system_name(int s) { return "s" + std::to_string(s); }

    static std::string group_name(int g) { return "g" + std::to_string(g); }
    static std::pair<std::string, std::string> pair_key(const std::string& a, const std::string& b) {
        return a < b ? std::make_pair(a, b) : std::make_pair(b, a);
    }

    Pack pack_;
    std::optional<std::pair<double, double>> ref_;          // lat0, lon0
    std::map<std::string, Entity> entities_;                // key order
    std::map<int, std::set<std::string>> groups_;           // creation order, members in key order
    std::map<std::pair<std::string, std::string>, std::int64_t> counts_;
    int next_group_ = 1;
    std::map<int, std::set<std::string>> systems_;          // creation order, members in key order
    int next_system_ = 1;
    std::set<std::string> reported_;                        // accepted a report since the previous tick
};

// An exact minimum-cost assignment of every row to a distinct column, for
// rows <= columns; +infinity marks a forbidden entry, and a finite assignment
// must exist. Returns the column of each row (Hungarian method with potentials).
std::vector<int> min_cost_assignment(const std::vector<std::vector<double>>& cost);

} // namespace corr
