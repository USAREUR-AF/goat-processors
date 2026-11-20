// quality.md "Entity measures" and "Source measures".
#include "quality/measures.hpp"

#include <algorithm>

#include "quality/common.hpp"

namespace corr::quality {

using namespace detail;

namespace {

// A statistic is null when fewer than k records hold its sample.
template <typename F>
Json stat(const WindowSamples& s, const std::vector<Sample>& xs, F compute) {
    return xs.size() < s.k ? Json() : compute(xs);
}

Json last_of(const std::vector<Sample>& xs) { return xs.back().json(); }

// "Entity measures": a mean is s / n, s from 0.0 adding each sample in order.
Json mean_of(const std::vector<Sample>& xs) {
    double s = 0.0;
    for (const Sample& x : xs) s += x.number;
    return Json(s / static_cast<double>(xs.size()));
}

// The largest (or smallest) sample, kept as written (integer or binary64);
// the first of equal ones.
Json largest(const std::vector<Sample>& xs) {
    return std::max_element(xs.begin(), xs.end(), [](const Sample& a, const Sample& b) { return a.number < b.number; })
        ->json();
}

Json smallest(const std::vector<Sample>& xs) {
    return std::min_element(xs.begin(), xs.end(), [](const Sample& a, const Sample& b) { return a.number < b.number; })
        ->json();
}

// A fraction of the window's records, null below k records.
Json fraction(const WindowSamples& s, std::int64_t count) {
    return static_cast<size_t>(s.reports) < s.k
               ? Json()
               : Json(static_cast<double>(count) / static_cast<double>(s.reports));
}

Json integer(std::int64_t v) { return Json(static_cast<long long>(v)); }

} // namespace

// One row per measure, in the order of the measures tables.
const std::vector<MeasureKind>& measures() {
    static const std::vector<MeasureKind> table = {
    {"reports", [](const WindowSamples& s) { return integer(s.reports); }, Aggregate::Sum},
    {"interval_last", [](const WindowSamples& s) { return stat(s, s.intervals, last_of); }, Aggregate::Mean},
    {"interval_mean", [](const WindowSamples& s) { return stat(s, s.intervals, mean_of); }, Aggregate::Mean},
    {"interval_max", [](const WindowSamples& s) { return stat(s, s.intervals, largest); }, Aggregate::Max},
    {"age", [](const WindowSamples& s) { return integer(s.age); }, Aggregate::Min},
    {"latency_mean", [](const WindowSamples& s) { return stat(s, s.latencies, mean_of); }, Aggregate::Mean},
    {"latency_max", [](const WindowSamples& s) { return stat(s, s.latencies, largest); }, Aggregate::Max},
    {"lateness_mean", [](const WindowSamples& s) { return stat(s, s.lateness, mean_of); }, Aggregate::Mean},
    {"lateness_max", [](const WindowSamples& s) { return stat(s, s.lateness, largest); }, Aggregate::Max},
    {"lateness_min", [](const WindowSamples& s) { return stat(s, s.lateness, smallest); }, Aggregate::Min},
    {"nis_mean", [](const WindowSamples& s) { return stat(s, s.nis, mean_of); }, Aggregate::Mean},
    {"speed_err_mean", [](const WindowSamples& s) { return stat(s, s.speed_err, mean_of); }, Aggregate::Mean},
    {"out_of_order", [](const WindowSamples& s) { return integer(s.out_of_order); }, Aggregate::Sum},
    {"duplicate", [](const WindowSamples& s) { return integer(s.duplicate); }, Aggregate::Sum},
    {"source_out_of_order", [](const WindowSamples& s) { return integer(s.source_out_of_order); }, Aggregate::Sum},
    {"missing_ce", [](const WindowSamples& s) { return fraction(s, s.no_ce); }, Aggregate::Mean},
    {"missing_vel", [](const WindowSamples& s) { return fraction(s, s.no_vel); }, Aggregate::Mean},
    {"missing_hae", [](const WindowSamples& s) { return fraction(s, s.no_hae); }, Aggregate::Mean},
    {"time_error_mean", [](const WindowSamples& s) { return stat(s, s.time_errors, mean_of); }, Aggregate::Mean},
    {"time_error_max", [](const WindowSamples& s) { return stat(s, s.time_errors, largest); }, Aggregate::Max},
    {"time_state_last", [](const WindowSamples& s) { return stat(s, s.time_states, last_of); }, Aggregate::Max},
    {"time_state_worst", [](const WindowSamples& s) { return stat(s, s.time_states, largest); }, Aggregate::Max},
    {"missing_time", [](const WindowSamples& s) { return fraction(s, s.no_time); }, Aggregate::Mean},
    {"entities", nullptr, Aggregate::Count},
    };
    return table;
}

// ---- Entity measures (spec "Entity measures") -----------------------------

WindowSamples window_samples(const Entity& e, std::int64_t now_ms, std::int64_t min_samples) {
    WindowSamples s;
    s.k = static_cast<size_t>(min_samples);
    s.reports = static_cast<std::int64_t>(e.window.size());
    s.age = now_ms - e.last;
    for (auto* v : {&s.intervals, &s.latencies, &s.lateness, &s.nis, &s.speed_err, &s.time_errors, &s.time_states})
        v->reserve(e.window.size());
    for (const Record& r : e.window) {
        if (r.interval) s.intervals.push_back(Sample::of_int(*r.interval));
        if (r.latency) s.latencies.push_back(Sample::of_int(*r.latency));
        if (!r.lateness.is_null())
            s.lateness.push_back(r.lateness.is_int ? Sample::of_int(r.lateness.integer)
                                                   : Sample::of_double(r.lateness.number));
        if (r.nis) s.nis.push_back(Sample::of_double(*r.nis));
        if (r.speed_err) s.speed_err.push_back(Sample::of_double(*r.speed_err));
        if (r.time_error) s.time_errors.push_back(Sample::of_double(*r.time_error));
        if (r.time_state) s.time_states.push_back(Sample::of_int(time_state_code(*r.time_state)));
        if (r.order == "out-of-order") ++s.out_of_order;
        if (r.order == "duplicate") ++s.duplicate;
        if (r.source_out_of_order) ++s.source_out_of_order;
        if (!r.ce) ++s.no_ce;
        if (!r.vel) ++s.no_vel;
        if (!r.hae) ++s.no_hae;
        if (!r.time_state) ++s.no_time;
    }
    return s;
}

Json entity_measures(const Entity& e, std::int64_t now_ms, std::int64_t min_samples) {
    const WindowSamples s = window_samples(e, now_ms, min_samples);
    Json m = Json::make_object();
    for (const MeasureKind& kind : measures())
        if (kind.entity) m[kind.name] = kind.entity(s);
    return m;
}

// ---- Source measures (spec "Source measures") -----------------------------

Json source_measures(const std::vector<const Json*>& ems) {
    Json m = Json::make_object();
    for (const MeasureKind& kind : measures()) {
        // "Present" values of the measure across the entities, in entity key order.
        std::vector<const Json*> vs;
        if (kind.source != Aggregate::Count)
            for (const Json* em : ems) {
                const Json* v = em->find(kind.name);
                if (v && v->is_number()) vs.push_back(v);
            }
        Json value;
        switch (kind.source) {
            case Aggregate::Sum: {
                long long sum = 0;
                for (const Json* v : vs) sum += v->integer;
                value = Json(sum);
                break;
            }
            case Aggregate::Mean: {
                if (vs.empty()) break;
                std::vector<double> xs;
                for (const Json* v : vs) xs.push_back(v->number);
                value = Json(mean(xs));
                break;
            }
            case Aggregate::Max:
            case Aggregate::Min: {
                if (vs.empty()) break;
                const bool large = kind.source == Aggregate::Max;
                const Json* best = vs[0];
                for (const Json* v : vs)
                    if (large ? v->number > best->number : v->number < best->number) best = v;
                value = *best;
                break;
            }
            case Aggregate::Count:
                value = static_cast<long long>(ems.size());
                break;
        }
        m[kind.name] = value;
    }
    return m;
}

} // namespace corr::quality
