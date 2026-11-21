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

Engine::Engine(Pack pack) : core_(std::make_unique<Core>(std::move(pack))) {
    method_ = find_method(core_->pack_.method)->make(*core_);
}

// ---- Operations ------------------------------------------------------------

Output Engine::ingest(const Json& r) {
    Output out;
    Core& c = *core_;

    // Spec "Reports": required keys, in table order.
    if (auto missing = report::missing_required(r)) {
        Json ev = event("reject");
        ev["reason"] = "missing:" + *missing;
        out.events.push(std::move(ev));
        return out;
    }
    const std::string source = r.find("track.source_id")->string;
    const std::string key = source + "/" + r.find("uid")->string;
    const std::int64_t time_ms = r.find("time_ms")->integer;
    const double lat = r.find("lat")->number, lon = r.find("lon")->number;

    // The method's own refusal (correlate-assign.md "Window": a retiring
    // entity's report), after the required keys and before the out-of-order check.
    if (const char* reason = method_->refuse(key)) {
        Json ev = event("reject");
        ev["entity"] = key;
        ev["reason"] = reason;
        out.events.push(std::move(ev));
        return out;
    }

    auto it = c.entities_.find(key);
    if (it != c.entities_.end() && time_ms < it->second.last_time_ms) {
        Json ev = event("reject");
        ev["entity"] = key;
        ev["reason"] = "out-of-order";
        out.events.push(std::move(ev));
        return out;
    }

    // Spec "Frame": the reference is the first accepted report.
    if (!c.ref_) c.ref_ = std::make_pair(lat, lon);
    Point z = c.to_plane(lat, lon);
    std::optional<Point> vel = measured_velocity(r);
    double ce = ce_at(r).value_or(c.pack_.filter.default_ce_m);

    // correlate.md "Reports", "Time quality": per key, the report's own
    // value, else the pack's time_default for this source, else error 0 and
    // state coherent.
    const report::TimeQuality tq = report::time_quality(r, source, c.pack_.time_default);
    const double te = tq.error_ms().value_or(0);
    const std::string time_state = tq.state().value_or("coherent");

    // correlate.md "Track estimate", Measurement variance, and its `time`
    // record before any other record of this report.
    const bool first = it == c.entities_.end();
    // The velocity is the entity's prediction to time_ms for a later report,
    // the measured velocity (or 0) for a first; only read when te is above 0.
    Point v = {0, 0};
    if (te != 0) {
        if (!first) {
            Filter p = c.predict(it->second, time_ms);
            v = {p.east.v, p.north.v};
        } else if (vel) {
            v = *vel;
        }
    }
    const MeasurementVariance mv = measurement_variance(ce, te, v);
    if (te > 0) {
        Json rec = filter_record(key, "time", nullptr, te);
        rec["var_east"] = mv.timing.east;
        rec["var_north"] = mv.timing.north;
        out.trace.push(std::move(rec));
    }

    if (first) {
        Entity e;
        e.key = key;
        e.source = source;
        static_cast<Track&>(e) = first_track(c.motion_, z, vel, mv.r);
        it = c.entities_.emplace(key, std::move(e)).first;
        Json ev = event("new");
        ev["entity"] = key;
        out.events.push(std::move(ev));
    } else if (c.restart_test(it->second, time_ms, z, mv.r, out)) {
        double dt = static_cast<double>(time_ms - it->second.last_time_ms) / 1000;
        const TrackUpdate u = update_track(it->second, c.motion_, z, vel, mv.r, dt);
        static_cast<Track&>(it->second) = u.track;
        if (c.motion_.maneuver) {
            // correlate.md "Two-model filter", Trace: likelihoods, then modes.
            out.trace.push(filter_record(key, "likelihood", "quiet", u.lambda[0]));
            out.trace.push(filter_record(key, "likelihood", "maneuver", u.lambda[1]));
            out.trace.push(filter_record(key, "mode", "quiet", u.track.mu[0]));
            out.trace.push(filter_record(key, "mode", "maneuver", u.track.mu[1]));
        }
    } else {
        // correlate.md "Restart": the filter starts again from this report as
        // a first report, with pp this report's measurement variance (found
        // above from the prediction's velocity); the entity keeps its key,
        // group, pair counts and hold failure count. With method assign it is
        // restarted until the next tick.
        static_cast<Track&>(it->second) = first_track(c.motion_, z, vel, mv.r);
        method_->restarted(key);
    }
    // correlate.md "Stale time of a source": an accepted report of an entity
    // that already existed appends its interval to its source's list.
    if (!first) c.record_interval(source, time_ms - it->second.last_time_ms);
    Entity& a = it->second;
    a.last_time_ms = time_ms;
    a.last = r;
    a.time_error_ms = te;
    a.time_state = time_state;
    a.r = mv.r;
    a.timing = mv.timing;

    method_->accepted(a, out);
    return out;
}

Output Engine::tick(std::int64_t now_ms) {
    return method_->tick(now_ms);
}

Json Engine::snapshot() const { return method_->snapshot(); }

} // namespace corr::correlate
