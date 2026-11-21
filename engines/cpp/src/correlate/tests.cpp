// correlate.md "Tests".
#include "correlate/tests.hpp"

#include "correlate/motion.hpp"
#include "correlate/pack.hpp"


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

// ---- The kinds -------------------------------------------------------------

double param(const TestSpec& t, const char* name) { return t.num.at(name); }

TestResult skipped() { return TestResult{Json(), Json(), true, true}; }

// The distance between A's position and B's prediction.
double distance_of(const TestInput& in) {
    double de = in.a.filter.east.p - in.bp.east.p, dn = in.a.filter.north.p - in.bp.north.p;
    return std::sqrt(de * de + dn * dn);
}

TestResult distance(const TestSpec& t, const TestInput& in) {
    double dist = distance_of(in);
    double max_m = param(t, "max_m");
    return {dist, max_m, dist < max_m, false};
}

// d² of A against B's prediction for comparison, r A's measurement variance
// on each axis (ce_a² when A's time error is 0).
TestResult mahalanobis(const TestSpec& t, const TestInput& in) {
    double v = d2(in.a, in.bp), gate = param(t, "gate");
    return {v, gate, v < gate, false};
}

TestResult course(const TestSpec& t, const TestInput& in) {
    auto ca = number_at(in.a.last, "course"), cb = number_at(in.b.last, "course");
    auto sa = number_at(in.a.last, "speed_ms"), sb = number_at(in.b.last, "speed_ms");
    double min_speed = param(t, "min_speed_ms");
    if (!sa || !sb || *sa < min_speed || *sb < min_speed) return skipped();
    if (!ca || !cb) return skipped();
    double diff = std::abs(*ca - *cb);
    double v = std::min(diff, 360 - diff), max_deg = param(t, "max_deg");
    return {v, max_deg, v <= max_deg, false};
}

TestResult speed(const TestSpec& t, const TestInput& in) {
    auto sa = number_at(in.a.last, "speed_ms"), sb = number_at(in.b.last, "speed_ms");
    double min_speed = param(t, "min_speed_ms");
    if (!sa || !sb || *sa < min_speed || *sb < min_speed) return skipped();
    double slow = std::min(*sa, *sb), fast = std::max(*sa, *sb);
    double v = fast == 0 ? 0.0 : std::abs(1 - slow / fast) * 100, max_pct = param(t, "max_pct");
    return {v, max_pct, v <= max_pct, false};
}

TestResult altitude(const TestSpec& t, const TestInput& in) {
    auto ha = number_at(in.a.last, "hae"), hb = number_at(in.b.last, "hae");
    if (!ha || !hb) return skipped();
    double v = std::abs(*ha - *hb), max_m = param(t, "max_m");
    return {v, max_m, v <= max_m, false};
}

TestResult same(const TestSpec& t, const TestInput& in) {
    auto va = same_value(in.a.last, t.key), vb = same_value(in.b.last, t.key);
    bool pass = (!va && !vb) || (va && vb && json_equal(*va, *vb));
    return {va ? *va : Json(), vb ? *vb : Json(), pass, false};
}

// The `state` test's limits (Abramowitz and Stegun 1964, table 26.8):
// probability, 4 dof, 5 dof.
struct ChiSquareRow {
    double probability, dof4, dof5;
};
constexpr ChiSquareRow kChiSquare[] = {
    {0.95, 9.4877, 11.0705},
    {0.99, 13.2767, 15.0863},
    {0.995, 14.8603, 16.7496},
    {0.999, 18.4668, 20.5150},
};

const ChiSquareRow* chi_square_row(double probability) {
    for (const ChiSquareRow& row : kChiSquare)
        if (row.probability == probability) return &row;
    return nullptr;
}

// The full-state track-to-track statistic, 4 dof, or 5 with both heights.
TestResult state(const TestSpec& t, const TestInput& in) {
    const StateAxis e = state_axis(in.a.filter.east, in.a.timing.east, in.bp.east);
    const StateAxis n = state_axis(in.a.filter.north, in.a.timing.north, in.bp.north);
    double v = e.q + n.q;
    auto ha = number_at(in.a.last, "hae"), hb = number_at(in.b.last, "hae");
    const ChiSquareRow& row = *chi_square_row(param(t, "probability"));
    double limit = row.dof4;
    long long dof = 4;
    if (ha && hb) {
        const double dh = *ha - *hb, h = param(t, "hae_sigma_m");
        v = v + dh * dh / (2 * h * h);
        limit = row.dof5;
        dof = 5;
    }
    Json extra = Json::make_object();
    extra["dof"] = dof;
    return {v, limit, v < limit, false, std::move(extra)};
}

const char* check_state(const TestSpec& t) {
    if (!chi_square_row(param(t, "probability"))) return "state probability is 0.95, 0.99, 0.995 or 0.999";
    if (!(param(t, "hae_sigma_m") > 0)) return "state hae_sigma_m must be above 0";
    return nullptr;
}

} // namespace

// ---- The registration point ---------------------------------------------------

void TestRegistry::add(TestKind kind) {
    for (TestKind& k : kinds_)
        if (k.name == kind.name) {
            k = std::move(kind);
            return;
        }
    kinds_.push_back(std::move(kind));
}

const TestKind* TestRegistry::find(const std::string& name) const {
    for (const TestKind& k : kinds_)
        if (k.name == name) return &k;
    return nullptr;
}

const TestRegistry& builtin_tests() {
    static const TestRegistry registry = [] {
        TestRegistry r;
        r.add({"distance", {"max_m"}, false, distance});
        r.add({"mahalanobis", {"gate"}, false, mahalanobis});
        r.add({"course", {"max_deg", "min_speed_ms"}, false, course});
        r.add({"speed", {"max_pct", "min_speed_ms"}, false, speed});
        r.add({"altitude", {"max_m"}, false, altitude});
        r.add({"same", {"key"}, true, same});
        r.add({"state", {"probability", "hae_sigma_m"}, false, state, check_state});
        return r;
    }();
    return registry;
}

} // namespace corr::correlate
