// correlate.md "Tests".
#include "correlate/tests.hpp"

#include "correlate/engine.hpp"

#include <algorithm>
#include <cmath>

#include "model/report.hpp"

#include "correlate/common.hpp"

namespace corr::correlate {

using namespace detail;

namespace {

using report::ce_at;
using report::number_at;

// Spec "Reports": `@env` is the third `-`-separated element of `type`.
std::optional<Json> same_value(const Json& r, const std::string& key) {
    if (key == "@env") {
        auto env = report::type_element(r, 2);
        if (!env) return std::nullopt;
        return Json(*env);
    }
    const Json* v = r.find(key);
    if (!v || v->is_null()) return std::nullopt;
    return *v;
}

} // namespace

// ---- Tests -----------------------------------------------------------------

TestResult run_test(const TestSpec& t, const TestInput& in) {
    const Entity& a = in.a;
    const Entity& b = in.b;
    const Filter& bp = in.bp;
    auto ce_of = [&](const Entity& e) { return ce_at(e.last).value_or(in.default_ce_m); };
    auto param = [&](const char* name) { return t.num.at(name); };
    auto skipped = [] { return TestResult{Json(), Json(), true, true}; };
    double de = a.filter.east.p - bp.east.p, dn = a.filter.north.p - bp.north.p;
    double dist = std::sqrt(de * de + dn * dn);

    if (t.name == "distance") {
        double max_m = param("max_m");
        return {dist, max_m, dist < max_m, false};
    }
    if (t.name == "window") {
        auto clamp = [&](double e) { return std::min(std::max(e, param("err_min_m")), param("err_max_m")); };
        double ea = clamp(ce_of(a)), eb = clamp(ce_of(b));
        double limit = param("multiplier") * std::sqrt(ea * ea + eb * eb) + param("window_m");
        return {dist, limit, dist < limit, false};
    }
    if (t.name == "mahalanobis") {
        // d² of A against B's prediction for comparison, r A's measurement
        // variance on each axis (ce_a² when A's time error is 0).
        double v = d2(a, bp), gate = param("gate");
        return {v, gate, v < gate, false};
    }
    if (t.name == "course" || t.name == "speed") {
        auto ca = number_at(a.last, "course"), cb = number_at(b.last, "course");
        auto sa = number_at(a.last, "speed_ms"), sb = number_at(b.last, "speed_ms");
        double min_speed = param("min_speed_ms");
        if (!sa || !sb || *sa < min_speed || *sb < min_speed) return skipped();
        if (t.name == "course") {
            if (!ca || !cb) return skipped();
            double diff = std::abs(*ca - *cb);
            double v = std::min(diff, 360 - diff), max_deg = param("max_deg");
            return {v, max_deg, v <= max_deg, false};
        }
        double slow = std::min(*sa, *sb), fast = std::max(*sa, *sb);
        double v = fast == 0 ? 0.0 : std::abs(1 - slow / fast) * 100, max_pct = param("max_pct");
        return {v, max_pct, v <= max_pct, false};
    }
    if (t.name == "altitude") {
        auto ha = number_at(a.last, "hae"), hb = number_at(b.last, "hae");
        if (!ha || !hb) return skipped();
        double v = std::abs(*ha - *hb), max_m = param("max_m");
        return {v, max_m, v <= max_m, false};
    }
    // same
    auto va = same_value(a.last, t.key), vb = same_value(b.last, t.key);
    bool pass = (!va && !vb) || (va && vb && json_equal(*va, *vb));
    return {va ? *va : Json(), vb ? *vb : Json(), pass, false};
}

// Runs one stage's tests in pack order, writing each to the trace; stops at
// the first failure. Returns true when every test ran and passed. `extra`,
// when given, is an object whose keys are added to each record.
bool Engine::run_stage(const char* stage, const std::vector<TestSpec>& tests, const Entity& a,
                       const Entity& b, const Filter& bp, Output& out, const Json* extra) const {
    for (const TestSpec& t : tests) {
        TestResult r = run_test(t, {a, b, bp, pack_.filter.default_ce_m});
        Json rec = Json::make_object();
        rec["stage"] = stage;
        rec["a"] = a.key;
        rec["b"] = b.key;
        rec["test"] = t.name;
        rec["value"] = r.value;
        rec["limit"] = r.limit;
        rec["pass"] = r.pass;
        if (r.skipped) rec["skipped"] = true;
        if (extra)
            for (const auto& kv : extra->object) rec[kv.first] = kv.second;
        out.trace.push(rec);
        if (!r.pass) return false;
    }
    return true;
}

} // namespace corr::correlate
