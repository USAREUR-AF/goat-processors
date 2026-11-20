// The filter function (filter.md "What the filter does"): load_pack (in
// filter/pack.hpp), then ingest, tick and snapshot.
#pragma once

#include <cstdint>
#include <map>
#include <string>

#include "filter/conditions.hpp"
#include "filter/pack.hpp"
#include "model/json.hpp"
#include "model/output.hpp"

namespace corr::filter {

class Engine {
public:
    explicit Engine(Pack pack);

    Output ingest(const Json& report);
    Output tick(std::int64_t now_ms);
    Json snapshot() const;

private:
    Pack pack_;
    std::map<std::string, EntityState> entities_;  // key order
};

} // namespace corr::filter
