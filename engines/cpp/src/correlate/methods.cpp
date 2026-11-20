// The registration point of correlate's methods: one row per method.
#include "correlate/method.hpp"

#include "assign/assign.hpp"
#include "correlate/confirm.hpp"

namespace corr::correlate {

namespace {

template <typename M>
std::unique_ptr<Method> make(Core& core) {
    return std::make_unique<M>(core);
}

} // namespace

const std::vector<MethodKind>& methods() {
    static const std::vector<MethodKind> table = {
        // correlate.md "Pack"
        {"confirm",
         {"pack", "version", "filter", "confirm_count", "hold_failures", "stale_ms"},
         {"new_cost", "keep_bonus", "window", "hypotheses", "margin", "bias", "time_offset"},
         make<ConfirmMethod>},
        // correlate-assign.md "Pack"
        {"assign",
         {"pack", "version", "filter", "new_cost", "keep_bonus", "stale_ms"},
         {"confirm", "hold", "confirm_count", "hold_failures", "same_source", "output", "priority"},
         make<AssignMethod>},
    };
    return table;
}

const MethodKind* find_method(const std::string& name) {
    for (const MethodKind& m : methods())
        if (name == m.name) return &m;
    return nullptr;
}

} // namespace corr::correlate
