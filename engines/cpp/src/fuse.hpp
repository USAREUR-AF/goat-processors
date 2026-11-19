// The fuse engine: ingest, tick, snapshot (fuse.md "What fuse does").
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "engine.hpp"      // Output
#include "fuse_pack.hpp"
#include "json.hpp"
#include "track.hpp"

namespace corr::fuse {

struct Entity {
    std::string key;
    std::string source;                    // track.source_id
    std::int64_t last_time_ms = 0;
    Filter filter;                         // correlate.md "Track estimate"
    Json report;                           // the last normalized report
    std::optional<std::string> group;      // fuse.group of that report; nullopt is its own unnamed group
};

// One group at a tick: its name (nullopt for an unnamed group) and its
// members in key order.
struct Group {
    std::optional<std::string> name;
    std::vector<const Entity*> members;
};

class Engine {
public:
    explicit Engine(Pack pack);

    Output ingest(const Json& report);
    Output tick(std::int64_t now_ms);
    Json snapshot() const;

private:
    // A member's filter predicted to now_ms (fuse.md "On each tick", 2.1).
    struct Predicted {
        const Entity* entity;
        Filter f;
        double var() const { return f.east.pp + f.north.pp; }   // "Position variance"
    };
    // The combined kinematics (fuse.md "Kinematics") and the member it came from.
    struct Kinematics {
        Filter f;
        const Entity* from = nullptr;
    };

    std::vector<Group> groups_in_output_order() const;
    std::optional<std::int64_t> rank(const Entity& e) const;
    std::int64_t rank_order(const Entity& e) const;

    Kinematics combine(const Group& g, const std::vector<Predicted>& members, Output& out) const;
    Kinematics inverse_variance(const std::vector<Predicted>& members) const;
    Kinematics covariance_intersection(const Group& g, const std::vector<Predicted>& members,
                                       Output& out) const;
    void decide_attribute(const Group& g, const Attribute& a, Json& attributes, Output& out) const;
    Json fused_event(const Group& g, const Kinematics& k, Json attributes) const;

    Pack pack_;
    std::optional<std::pair<double, double>> ref_;   // lat0, lon0
    std::map<std::string, Entity> entities_;         // key order
};

} // namespace corr::fuse
