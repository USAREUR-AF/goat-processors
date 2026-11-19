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
    Filter filter;             // with `maneuver`, the combination of the two models
    Filter models[2];          // with `maneuver`: quiet (index 0), maneuver (index 1)
    double mu[2] = {0, 0};     // with `maneuver`: mu1, mu2
    Json last;                 // the last accepted report
    int group = 0;             // group number, 0 when ungrouped
    std::int64_t hold_failures = 0;
    int system = 0;            // method assign: committed system track number, 0 when none
};

// The events and trace one call returns.
struct Output {
    Json events = Json::make_array();
    Json trace = Json::make_array();
};

// correlate-assign.md "Memberships": one picture of the system tracks.
struct Membership {
    std::map<int, std::set<std::string>> systems;   // creation order, members in key order
    int next_system = 1;

    int system_of(const std::string& key) const;     // 0 when in none
};

// correlate-assign.md "Memberships": one pending tick of a history.
struct Record {
    double cost = 0;
    Json choices = Json::make_array();   // [entity, chosen] pairs
    Json events = Json::make_array();
    Membership membership;
};

struct History {
    std::vector<Record> records;         // oldest first
    double total() const;
};

// correlate-assign.md "Ranking": one assignment of a source's entities.
struct RankedAssignment {
    std::vector<size_t> choice;          // choice vector: column index, or the column count for alone
    double total = 0;
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

    // Track estimate and Two-model filter
    void filter_first(Entity& e, const Point& z, const std::optional<Point>& vel, double ce) const;
    void filter_update(Entity& e, const Point& z, const std::optional<Point>& vel, double ce, double dt,
                       Output& out) const;
    Filter predict(const Entity& e, std::int64_t t) const;

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

    // Method assign (correlate-assign.md), in assign.cpp
    Output tick_assign(std::int64_t now_ms);
    Filter fuse(const std::set<std::string>& members, std::int64_t t) const;
    std::vector<RankedAssignment> rank_source(const std::vector<std::string>& rows, const Membership& m,
                                              int h, std::vector<int>& columns,
                                              std::vector<std::vector<double>>& entries, Output& out) const;
    void apply_assignment(const std::vector<std::string>& rows, const std::vector<int>& columns,
                          const RankedAssignment& r, Record& rec) const;
    void system_output(std::int64_t now_ms, Output& out) const;
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
};

// correlate-assign.md "Ranking": the first k assignments of rows to columns,
// in Ranking order. entries[i][j] for j < columns is row i against column j,
// entries[i][columns] is row i alone; +infinity is forbidden. Brute force.
std::vector<RankedAssignment> rank_assignments(const std::vector<std::vector<double>>& entries,
                                               size_t columns, size_t k);

} // namespace corr
