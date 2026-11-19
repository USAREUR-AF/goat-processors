// The correlator engine: ingest, tick, snapshot (spec "What the correlator does").
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <utility>

#include "json.hpp"
#include "pack.hpp"

namespace corr {

// One axis of the constant-velocity filter (spec "Track estimate").
struct Axis {
    double p = 0, v = 0, pp = 0, pv = 0, vv = 0;
};

struct Filter {
    Axis east, north;
};

struct Entity {
    std::string key;
    std::string source;
    std::int64_t last_time_ms = 0;
    Filter filter;
    Json last;                 // the last accepted report
    int group = 0;             // group number, 0 when ungrouped
    std::int64_t hold_failures = 0;
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
    struct Point { double east, north; };
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
};

} // namespace corr
