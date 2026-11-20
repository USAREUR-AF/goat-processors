// quality.md "Input clock".
#include "quality/input_clock.hpp"

#include <algorithm>
#include <map>

#include "quality/common.hpp"

namespace corr::quality {

using namespace detail;

// ---- Input clock (spec "Input clock") ------------------------------------

std::optional<Json> input_clock(const std::map<std::string, Entity>& entities, const std::string& source) {
    // 1. Each other source's latest time: the greatest `last` among its entities.
    std::map<std::string, std::int64_t> latest_of;
    for (const auto& [key, e] : entities) {
        if (e.source == source) continue;
        auto [it, inserted] = latest_of.emplace(e.source, e.last);
        if (!inserted) it->second = std::max(it->second, e.last);
    }
    // 3. With no other source, there is no input clock.
    if (latest_of.empty()) return std::nullopt;
    // 2. The median of those times, sorted ascending.
    std::vector<std::int64_t> times;
    for (const auto& [s, t] : latest_of) times.push_back(t);
    std::sort(times.begin(), times.end());
    const size_t n = times.size();
    if (n % 2 == 1) return Json(static_cast<long long>(times[n / 2]));
    const double a = static_cast<double>(times[n / 2 - 1]), b = static_cast<double>(times[n / 2]);
    return Json((a + b) / 2);
}

std::optional<std::int64_t> source_latest(const std::map<std::string, Entity>& entities, const std::string& source) {
    // The greatest `last` among the entities whose source is `source` (the
    // report's own entity among them when it is that source's).
    std::optional<std::int64_t> latest;
    for (const auto& [key, e] : entities)
        if (e.source == source && (!latest || e.last > *latest)) latest = e.last;
    return latest;
}

} // namespace corr::quality
