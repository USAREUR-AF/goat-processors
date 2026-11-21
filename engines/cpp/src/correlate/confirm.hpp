// Method confirm (correlate.md "Association", "On each tick", "Snapshot"):
// gate, confirm and hold, or with `sprt` the sequential test; groups; the
// fused output.
#pragma once

#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

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
    Json fused_event(int g, const std::set<std::string>& members, std::int64_t now_ms) const;
    std::vector<std::string> candidates(const Entity& a) const;
    void choose(Entity& a, const std::vector<std::string>& reached, Output& out);

    // Sequential test (with `sprt`).
    void sprt_linked(Entity& a, Output& out);
    void sprt_associate(Entity& a, Output& out);
    bool same_tests_pass(const Entity& a, const Entity& b, const Filter& bp, Output* out) const;
    // Updates the pair's L (from 0 when it has none) with A's evidence
    // against B, or forced to lo; writes the `sprt` record; returns the new L.
    double sprt_update(const Entity& a, const Entity& b, const Filter& bp, bool forced, Output& out);
    bool group_has_source(int g, const std::string& source) const;

    static std::string group_name(int g) { return "g" + std::to_string(g); }
    static std::pair<std::string, std::string> pair_key(const std::string& a, const std::string& b) {
        return a < b ? std::make_pair(a, b) : std::make_pair(b, a);
    }

    std::map<int, std::set<std::string>> groups_;           // creation order, members in key order
    std::map<std::pair<std::string, std::string>, std::int64_t> counts_;
    std::map<std::pair<std::string, std::string>, double> llr_;   // with `sprt`: each pair's L
    int next_group_ = 1;
};

} // namespace corr::correlate
