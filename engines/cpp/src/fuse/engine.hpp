// The fuse function (fuse.md "What fuse does"): load_pack (in fuse/pack.hpp),
// then ingest, tick and snapshot.
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "fuse/entity.hpp"
#include "fuse/kinematics.hpp"
#include "fuse/pack.hpp"
#include "model/json.hpp"
#include "model/output.hpp"

namespace corr::fuse {

class Engine {
public:
    explicit Engine(Pack pack);

    Output ingest(const Json& report);
    Output tick(std::int64_t now_ms);
    Json snapshot() const;

private:
    std::vector<Group> groups_in_output_order() const;
    Json fused_event(const Group& g, const Kinematics& k, Json attributes) const;

    Pack pack_;
    std::optional<std::pair<double, double>> ref_;   // lat0, lon0
    std::map<std::string, Entity> entities_;         // key order
};

} // namespace corr::fuse
