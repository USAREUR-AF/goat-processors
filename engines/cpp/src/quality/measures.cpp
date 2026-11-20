// quality.md "Entity measures" and "Source measures".
#include "quality/engine.hpp"

#include <algorithm>

#include "quality/common.hpp"

namespace corr::quality {

using namespace detail;

// ---- Entity measures (spec "Entity measures") -----------------------------

Json Engine::entity_measures(const Entity& e, std::int64_t now_ms) const {
    const auto k = static_cast<size_t>(pack_.min_samples);
    const std::vector<Record>& w = e.window;

    // The samples of each kind, in window order, as numbers (integer or binary64).
    std::vector<Json> intervals, latencies, lateness, nis, speed_err, time_errors, time_states;
    std::int64_t out_of_order = 0, duplicate = 0, source_out_of_order = 0;
    std::int64_t no_ce = 0, no_vel = 0, no_hae = 0, no_time = 0;
    for (const Record& r : w) {
        if (r.interval) intervals.push_back(static_cast<long long>(*r.interval));
        if (r.latency) latencies.push_back(static_cast<long long>(*r.latency));
        if (!r.lateness.is_null()) lateness.push_back(r.lateness);
        if (r.nis) nis.push_back(*r.nis);
        if (r.speed_err) speed_err.push_back(*r.speed_err);
        if (r.time_error) time_errors.push_back(*r.time_error);
        if (r.time_state) time_states.push_back(static_cast<long long>(time_state_code(*r.time_state)));
        if (r.order == "out-of-order") ++out_of_order;
        if (r.order == "duplicate") ++duplicate;
        if (r.source_out_of_order) ++source_out_of_order;
        if (!r.ce) ++no_ce;
        if (!r.vel) ++no_vel;
        if (!r.hae) ++no_hae;
        if (!r.time_state) ++no_time;
    }

    // A statistic is null when fewer than k records hold its sample.
    auto stat = [&](const std::vector<Json>& xs, auto compute) { return xs.size() < k ? Json() : compute(xs); };
    auto last_of = [](const std::vector<Json>& xs) { return xs.back(); };
    auto mean_of = [](const std::vector<Json>& xs) {
        std::vector<double> ds;
        for (const Json& x : xs) ds.push_back(x.number);
        return Json(mean(ds));
    };
    // The largest (or smallest) sample, kept as written (integer or binary64).
    auto largest = [](const std::vector<Json>& xs) {
        return *std::max_element(xs.begin(), xs.end(), [](const Json& a, const Json& b) { return a.number < b.number; });
    };
    auto smallest = [](const std::vector<Json>& xs) {
        return *std::min_element(xs.begin(), xs.end(), [](const Json& a, const Json& b) { return a.number < b.number; });
    };
    const std::int64_t reports = static_cast<std::int64_t>(w.size());
    auto fraction = [&](std::int64_t count) {
        return w.size() < k ? Json() : Json(static_cast<double>(count) / static_cast<double>(reports));
    };

    Json m = Json::make_object();
    m["reports"] = static_cast<long long>(reports);
    m["interval_last"] = stat(intervals, last_of);
    m["interval_mean"] = stat(intervals, mean_of);
    m["interval_max"] = stat(intervals, largest);
    m["age"] = static_cast<long long>(now_ms - e.last);
    m["latency_mean"] = stat(latencies, mean_of);
    m["latency_max"] = stat(latencies, largest);
    m["lateness_mean"] = stat(lateness, mean_of);
    m["lateness_max"] = stat(lateness, largest);
    m["lateness_min"] = stat(lateness, smallest);
    m["nis_mean"] = stat(nis, mean_of);
    m["speed_err_mean"] = stat(speed_err, mean_of);
    m["out_of_order"] = static_cast<long long>(out_of_order);
    m["duplicate"] = static_cast<long long>(duplicate);
    m["source_out_of_order"] = static_cast<long long>(source_out_of_order);
    m["missing_ce"] = fraction(no_ce);
    m["missing_vel"] = fraction(no_vel);
    m["missing_hae"] = fraction(no_hae);
    m["time_error_mean"] = stat(time_errors, mean_of);
    m["time_error_max"] = stat(time_errors, largest);
    m["time_state_last"] = stat(time_states, last_of);
    m["time_state_worst"] = stat(time_states, largest);
    m["missing_time"] = fraction(no_time);
    return m;
}

// ---- Source measures (spec "Source measures") -----------------------------

Json Engine::source_measures(const std::vector<const Json*>& ems) const {
    // "Present" values of one measure across the entities, in entity key order.
    auto present = [&](const char* name) {
        std::vector<const Json*> vs;
        for (const Json* em : ems) {
            const Json* v = em->find(name);
            if (v && v->is_number()) vs.push_back(v);
        }
        return vs;
    };
    auto sum = [&](const char* name) {
        long long s = 0;
        for (const Json* v : present(name)) s += v->integer;
        return Json(s);
    };
    auto mean_of = [&](const char* name) {
        auto vs = present(name);
        if (vs.empty()) return Json();
        std::vector<double> xs;
        for (const Json* v : vs) xs.push_back(v->number);
        return Json(mean(xs));
    };
    auto pick = [&](const char* name, bool largest) {
        auto vs = present(name);
        if (vs.empty()) return Json();
        const Json* best = vs[0];
        for (const Json* v : vs)
            if (largest ? v->number > best->number : v->number < best->number) best = v;
        return *best;
    };

    Json m = Json::make_object();
    for (const char* name : {"reports", "out_of_order", "duplicate", "source_out_of_order"}) m[name] = sum(name);
    for (const char* name : {"interval_last", "interval_mean", "latency_mean", "lateness_mean", "nis_mean",
                             "speed_err_mean", "missing_ce", "missing_vel", "missing_hae", "time_error_mean",
                             "missing_time"})
        m[name] = mean_of(name);
    for (const char* name : {"interval_max", "latency_max", "lateness_max", "time_error_max", "time_state_last",
                             "time_state_worst"})
        m[name] = pick(name, true);
    m["lateness_min"] = pick("lateness_min", false);
    m["age"] = pick("age", false);
    m["entities"] = static_cast<long long>(ems.size());
    return m;
}

} // namespace corr::quality
