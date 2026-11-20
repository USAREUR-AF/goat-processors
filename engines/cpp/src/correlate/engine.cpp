// correlate.md "What the correlator does": ingest (with "Reports" and
// "Frame"), tick and snapshot, and the snapshot form of an entity's filter.
#include "correlate/engine.hpp"

#include "correlate/common.hpp"
#include "model/report.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

namespace corr::correlate {

namespace {

using namespace detail;

// Spec "Reports" helpers live in report.hpp, shared with the filter and fuse.
using report::ce_at;
using report::is_integer;
using report::number_at;

} // namespace

Engine::Engine(Pack pack) : pack_(std::move(pack)) {}

// ---- Frame -----------------------------------------------------------------

Point Engine::to_plane(double lat, double lon) const {
    return corr::to_plane(ref_->first, ref_->second, lat, lon);
}

std::pair<double, double> Engine::to_degrees(double east, double north) const {
    return corr::to_degrees(ref_->first, ref_->second, east, north);
}

// ---- Track estimate --------------------------------------------------------

// Snapshot: `filter`, `time` when the last report had a time error above 0,
// and with `maneuver` also `models` and `mode`.
void Engine::filter_json(const Entity& e, Json& into) const {
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

// ---- Operations ------------------------------------------------------------

Output Engine::ingest(const Json& r) {
    Output out;

    // Spec "Reports": required keys, in table order.
    if (auto missing = report::missing_required(r)) {
        Json ev = event("reject");
        ev["reason"] = "missing:" + *missing;
        out.events.push(ev);
        return out;
    }
    const std::string source = r.find("track.source_id")->string;
    const std::string key = source + "/" + r.find("uid")->string;
    const std::int64_t time_ms = r.find("time_ms")->integer;
    const double lat = r.find("lat")->number, lon = r.find("lon")->number;

    // correlate-assign.md "Window": a retiring entity's report, after the
    // required keys and before the out-of-order check.
    if (retiring_.count(key)) {
        Json ev = event("reject");
        ev["entity"] = key;
        ev["reason"] = "retiring";
        out.events.push(ev);
        return out;
    }

    auto it = entities_.find(key);
    if (it != entities_.end() && time_ms < it->second.last_time_ms) {
        Json ev = event("reject");
        ev["entity"] = key;
        ev["reason"] = "out-of-order";
        out.events.push(ev);
        return out;
    }

    // Spec "Frame": the reference is the first accepted report.
    if (!ref_) ref_ = std::make_pair(lat, lon);
    Point z = to_plane(lat, lon);
    std::optional<Point> vel = measured_velocity(r);
    double ce = ce_at(r).value_or(pack_.filter.default_ce_m);

    // correlate.md "Reports", "Time quality": per key, the report's own
    // value, else the pack's time_default for this source, else error 0 and
    // state coherent.
    const report::TimeQuality tq = report::time_quality(r, source, pack_.time_default);
    const double te = tq.error_ms().value_or(0);
    const std::string time_state = tq.state().value_or("coherent");

    // correlate.md "Track estimate", Measurement variance, and its `time`
    // record before any other record of this report.
    const bool first = it == entities_.end();
    const MeasurementVariance mv = measurement_variance(first ? nullptr : &it->second, time_ms, vel, ce, te);
    if (te > 0) {
        Json rec = filter_record(key, "time", nullptr, te);
        rec["var_east"] = mv.timing.east;
        rec["var_north"] = mv.timing.north;
        out.trace.push(rec);
    }

    if (first) {
        Entity e;
        e.key = key;
        e.source = source;
        filter_first(e, z, vel, mv.r);
        it = entities_.emplace(key, std::move(e)).first;
        Json ev = event("new");
        ev["entity"] = key;
        out.events.push(ev);
    } else if (restart_test(it->second, time_ms, z, mv.r, out)) {
        double dt = static_cast<double>(time_ms - it->second.last_time_ms) / 1000;
        filter_update(it->second, z, vel, mv.r, dt, out);
    } else {
        // correlate.md "Restart": the filter starts again from this report as
        // a first report, with pp this report's measurement variance (found
        // above from the prediction's velocity); the entity keeps its key,
        // group, pair counts and hold failure count. With method assign it is
        // restarted until the next tick.
        filter_first(it->second, z, vel, mv.r);
        if (pack_.method_assign) restarted_.insert(key);
    }
    Entity& a = it->second;
    a.last_time_ms = time_ms;
    a.last = r;
    a.time_error_ms = te;
    a.time_state = time_state;
    a.r = mv.r;
    a.timing = mv.timing;

    if (pack_.method_assign) {
        reported_.insert(a.key);    // decided at the next tick
        return out;
    }
    if (a.group) hold(a, out);
    else associate(a, out);
    return out;
}

Output Engine::tick(std::int64_t now_ms) {
    return pack_.method_assign ? tick_assign(now_ms) : tick_confirm(now_ms);
}

Json Engine::snapshot() const { return pack_.method_assign ? snapshot_assign() : snapshot_confirm(); }

} // namespace corr::correlate
