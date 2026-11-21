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

// correlate.md "Pack": without `sprt`, confirm_count and hold_failures are
// required; with it, they and `hold` are load errors.
void check_confirm(const std::set<std::string>& seen) {
    const bool sprt = seen.count("sprt") != 0;
    for (const char* d : {"confirm_count", "hold_failures"})
        if (!sprt && !seen.count(d)) throw PackError(std::string("pack.def: missing directive ") + d);
    for (const char* d : {"confirm_count", "hold_failures", "hold"})
        if (sprt && seen.count(d))
            throw PackError(std::string("pack.def: directive ") + d + " is not allowed with sprt");
}

} // namespace

const std::vector<MethodKind>& methods() {
    static const std::vector<MethodKind> table = {
        // correlate.md "Pack"; one of stale_ms and stale_rate is checked for both methods
        {"confirm",
         {"pack", "version", "filter"},
         {"new_cost", "keep_bonus", "window", "hypotheses", "margin", "bias", "time_offset"},
         make<ConfirmMethod>, check_confirm},
        // correlate-assign.md "Pack"
        {"assign",
         {"pack", "version", "filter", "new_cost", "keep_bonus"},
         {"confirm", "hold", "confirm_count", "hold_failures", "same_source", "output", "priority", "sprt"},
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
