// Method confirm (correlate.md "Association", "On each tick", "Snapshot"):
// gate, confirm and hold, groups, fused output.
#pragma once

#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <utility>

#include "correlate/method.hpp"

namespace corr::correlate {

class ConfirmMethod final : public CoreMethod {
public:
    explicit ConfirmMethod(Core& core) : CoreMethod(core) {}

    void accepted(Entity& a, Output& out) override;
    Output tick(std::int64_t now_ms) override;
    Json snapshot() const override;

private:
    void hold(Entity& a, Output& out);
    void associate(Entity& a, Output& out);
    void leave_group(Entity& e, const char* reason, Output& out);
    bool group_has_source(int g, const std::string& source) const;

    static std::string group_name(int g) { return "g" + std::to_string(g); }
    static std::pair<std::string, std::string> pair_key(const std::string& a, const std::string& b) {
        return a < b ? std::make_pair(a, b) : std::make_pair(b, a);
    }

    std::map<int, std::set<std::string>> groups_;           // creation order, members in key order
    std::map<std::pair<std::string, std::string>, std::int64_t> counts_;
    int next_group_ = 1;
};

} // namespace corr::correlate
