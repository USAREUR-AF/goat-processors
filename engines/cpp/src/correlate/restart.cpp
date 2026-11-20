// correlate.md "Restart".
#include "correlate/engine.hpp"

#include "correlate/common.hpp"

namespace corr::correlate {

using namespace detail;

// correlate.md "Restart": for a later report, before the filter update.
// Returns true when the report updates the filter (no `restart` directive, or
// d² < g); writes the `restart` record first of the report's records.
bool Engine::restart_test(const Entity& e, std::int64_t time_ms, const Point& z, const Point& r,
                          Output& out) const {
    if (!pack_.restart_gate) return true;
    const double g = *pack_.restart_gate;
    Filter p = predict(e, time_ms);
    double de = z.east - p.east.p, dn = z.north - p.north.p;
    double d2 = de * de / (p.east.pp + r.east) + dn * dn / (p.north.pp + r.north);
    Json rec = Json::make_object();
    rec["stage"] = "filter";
    rec["a"] = e.key;
    rec["b"] = Json();
    rec["test"] = "restart";
    rec["value"] = d2;
    rec["limit"] = g;
    rec["pass"] = d2 < g;
    out.trace.push(rec);
    return d2 < g;
}

} // namespace corr::correlate
