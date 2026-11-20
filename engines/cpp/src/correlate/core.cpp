// What every correlate method shares: the frame, the prediction of a
// stored entity, Restart, running a stage of tests, staleness and the
// snapshot form of an entity's filter.
#include "correlate/core.hpp"

#include "correlate/common.hpp"
#include "correlate/tests.hpp"

namespace corr::correlate {

using namespace detail;

Core::Core(Pack pack) : pack_(std::move(pack)), motion_(motion_of(pack_)) {}

// ---- Track estimate, Two-model filter, Restart -------------------------------

Filter Core::predict(const Entity& e, std::int64_t t) const {
    return correlate::predict(e, motion_, static_cast<double>(t - e.last_time_ms) / 1000);
}

// correlate.md "Track estimate": B predicted to t to be compared with another
// entity, with B's timing variance added to the predicted pp on each axis
// before any other change to the prediction (Tests, rank, and
// correlate-assign.md Cost). Restart, the bias update and output use
// `predict`, without it.
Filter Core::predict_for_comparison(const Entity& b, std::int64_t t) const {
    return for_comparison(predict(b, t), b.timing);
}

// correlate.md "Restart": for a later report, before the filter update.
// Returns true when the report updates the filter (no `restart` directive, or
// d² < g); writes the `restart` record first of the report's records.
bool Core::restart_test(const Entity& e, std::int64_t time_ms, const Point& z, const Point& r,
                          Output& out) const {
    if (!pack_.restart_gate) return true;
    const double g = *pack_.restart_gate;
    const double v = d2(z, r, predict(e, time_ms));
    Json rec = Json::make_object();
    rec["stage"] = "filter";
    rec["a"] = e.key;
    rec["b"] = Json();
    rec["test"] = "restart";
    rec["value"] = v;
    rec["limit"] = g;
    rec["pass"] = v < g;
    out.trace.push(std::move(rec));
    return v < g;
}

// ---- Frame -----------------------------------------------------------------

Point Core::to_plane(double lat, double lon) const {
    return corr::to_plane(ref_->first, ref_->second, lat, lon);
}

std::pair<double, double> Core::to_degrees(double east, double north) const {
    return corr::to_degrees(ref_->first, ref_->second, east, north);
}

// ---- Track estimate --------------------------------------------------------

// Snapshot: `filter`, `time` when the last report had a time error above 0,
// and with `maneuver` also `models` and `mode`.
void Core::filter_json(const Entity& e, Json& into) const {
    into["filter"] = filter_json_of(e.filter);
    if (e.time_error_ms > 0) {
        Json time = Json::make_object();
        time["var_east"] = e.timing.east;
        time["var_north"] = e.timing.north;
        into["time"] = time;
    }
    if (!pack_.maneuver) return;
    Json models = Json::make_object();
    models["quiet"] = filter_json_of(e.models[0]);
    models["maneuver"] = filter_json_of(e.models[1]);
    into["models"] = models;
    Json mode = Json::make_array();
    mode.push(e.mu[0]);
    mode.push(e.mu[1]);
    into["mode"] = mode;
}

// Runs one stage's tests in pack order, writing each to the trace; stops at
// the first failure. Returns true when every test ran and passed. `extra`,
// when given, is an object whose keys are added to each record.
bool Core::run_stage(const char* stage, const std::vector<TestSpec>& tests, const Entity& a,
                       const Entity& b, const Filter& bp, Output& out, const Json* extra) const {
    for (const TestSpec& t : tests) {
        TestResult r = t.run(t, {a, b, bp, pack_.filter.default_ce_m});
        Json rec = Json::make_object();
        rec["stage"] = stage;
        rec["a"] = a.key;
        rec["b"] = b.key;
        rec["test"] = t.name;
        rec["value"] = std::move(r.value);
        rec["limit"] = std::move(r.limit);
        rec["pass"] = r.pass;
        if (r.skipped) rec["skipped"] = true;
        if (extra)
            for (const auto& kv : extra->object) rec[kv.first] = kv.second;
        out.trace.push(std::move(rec));
        if (!r.pass) return false;
    }
    return true;
}

// Spec "On each tick", 1: the pack's stale_ms, or the report's own stale_ms.
bool Core::is_stale(const Entity& e, std::int64_t now_ms) const {
    auto report_stale = e.last.find("stale_ms");
    return now_ms - e.last_time_ms > pack_.stale_ms ||
           (is_integer(report_stale) && now_ms >= report_stale->integer);
}

} // namespace corr::correlate
