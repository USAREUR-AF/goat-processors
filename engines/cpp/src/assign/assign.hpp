// Method assign (correlate-assign.md): memberships by assignment over a
// window of ticks, with sensor bias and time offset.
#pragma once

#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "assign/bias.hpp"
#include "assign/membership.hpp"
#include "assign/ranking.hpp"
#include "correlate/method.hpp"

namespace corr::correlate {

class AssignMethod final : public CoreMethod {
public:
    explicit AssignMethod(Core& core) : CoreMethod(core) {}

    const char* refuse(const std::string& key) const override;
    void restarted(const std::string& key) override { restarted_.insert(key); }
    void accepted(Entity& a, Output& out) override;
    Output tick(std::int64_t now_ms) override;
    Json snapshot() const override;

private:
    Filter fuse(const std::set<std::string>& members, std::int64_t t, const Entity* frame = nullptr) const;
    BiasState bias_state(const std::string& pair) const;
    Filter predict_into_frame(const Entity& a, const Entity& b, std::int64_t t) const;
    void bias_update(std::int64_t now_ms, const std::set<std::string>& rows, Output& out);
    std::vector<RankedAssignment> rank_source(const std::vector<std::string>& rows, const Membership& m,
                                              int h, std::vector<int>& columns,
                                              std::vector<std::vector<double>>& entries, Output& out) const;
    void apply_assignment(const std::vector<std::string>& rows, const std::vector<int>& columns,
                          const RankedAssignment& r, Record& rec) const;
    void system_output(std::int64_t now_ms, const Membership& reported, Output& out) const;

    Membership committed_;
    std::vector<History> histories_ = {History{}};           // rank order
    std::set<std::string> retiring_;
    std::set<std::string> reported_;                        // accepted a report since the previous tick
    std::set<std::string> restarted_;                       // filter started again since the previous tick
    std::map<std::string, BiasState> bias_;                 // stored pair states, by "<S>|<T>"
};

} // namespace corr::correlate
