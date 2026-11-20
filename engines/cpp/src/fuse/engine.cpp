// fuse.md, section by section. Frame and Track estimate are correlate.md's,
// from track.hpp; the reading of report keys is correlate.md's, from
// report.hpp (fuse.md "Shared with correlate.md").
#include "fuse/engine.hpp"

#include "fuse/attributes.hpp"
#include "fuse/kinematics.hpp"
#include "model/report.hpp"
#include "snapshot/snapshot.hpp"
#include "trace/trace.hpp"

#include <cmath>

namespace corr::fuse {

namespace {

using report::ce_at;
using report::is_integer;
using report::missing_required;
using report::number_at;

using trace::event;
using trace::name_or_null;

// fuse.md "Reports": `fuse.group` is absent when it is `null`, not a string,
// or the empty string.
std::optional<std::string> group_of(const Json& report) {
    const Json* g = report.find("fuse.group");
    if (!g || !g->is_string() || g->string.empty()) return std::nullopt;
    return g->string;
}

// fuse.md "Reports", the normalized report: every key removed that is `null`,
// or that correlate.md Reports or the `fuse.group` rule treats as absent.
Json normalize(const Json& r) {
    Json out = Json::make_object();
    for (const auto& kv : r.object) {
        const std::string& key = kv.first;
        const Json& v = kv.second;
        if (v.is_null()) continue;
        bool numeric = key == "hae" || key == "ce" || key == "course" || key == "speed_ms";
        if (numeric && !v.is_number()) continue;                // optional key of the wrong type
        if (key == "ce" && v.number <= 0) continue;             // a `ce` of 0 or below
        if (key == "type" && !v.is_string()) continue;
        if (key == "stale_ms" && !is_integer(&v)) continue;
        if (key == "fuse.group" && (!v.is_string() || v.string.empty())) continue;
        out[key] = v;
    }
    return out;
}

} // namespace

Engine::Engine(Pack pack) : pack_(std::move(pack)) {}

// ---- Reports and Groups (ingest) -------------------------------------------

Output Engine::ingest(const Json& r) {
    Output out;

    // Reports: a missing required key rejects, as in correlate.md.
    if (auto missing = missing_required(r)) {
        Json ev = event("reject");
        ev["reason"] = "missing:" + *missing;
        out.events.push(ev);
        return out;
    }
    const std::string source = r.find("track.source_id")->string;
    const std::string key = source + "/" + r.find("uid")->string;
    const std::int64_t time_ms = r.find("time_ms")->integer;

    // Reports: earlier than the entity's last accepted report is ignored
    // (stale-report); equal is accepted with dt = 0.
    auto it = entities_.find(key);
    if (it != entities_.end() && time_ms < it->second.last_time_ms) {
        Json ev = event("stale-report");
        ev["entity"] = key;
        ev["time_ms"] = static_cast<long long>(time_ms);
        ev["last_time_ms"] = static_cast<long long>(it->second.last_time_ms);
        out.events.push(ev);
        return out;
    }

    // Every value read from here on comes from the normalized report.
    Json report = normalize(r);
    const double lat = report.find("lat")->number, lon = report.find("lon")->number;

    // correlate.md "Frame": the reference is the first accepted report.
    if (!ref_) ref_ = std::make_pair(lat, lon);
    Point z = to_plane(ref_->first, ref_->second, lat, lon);
    std::optional<Point> vel = measured_velocity(report);
    double ce = ce_at(report).value_or(pack_.filter.default_ce_m);
    std::optional<std::string> group = group_of(report);

    if (it == entities_.end()) {
        // correlate.md "Track estimate", first report; Groups: a first report gives `new`.
        Entity e;
        e.key = key;
        e.source = source;
        e.filter = filter_first(pack_.filter, z, vel, ce);
        e.last_time_ms = time_ms;
        e.report = std::move(report);
        e.group = group;
        entities_.emplace(key, std::move(e));
        Json ev = event("new");
        ev["entity"] = key;
        ev["group"] = name_or_null(group);
        out.events.push(ev);
        return out;
    }

    // correlate.md "Track estimate", later reports.
    Entity& e = it->second;
    double dt = static_cast<double>(time_ms - e.last_time_ms) / 1000;
    filter_update(e.filter, pack_.filter, z, vel, ce, dt);
    e.last_time_ms = time_ms;
    e.report = std::move(report);

    // Groups: a move is applied when the report is accepted, after the filter update.
    if (group != e.group) {
        Json ev = event("move");
        ev["entity"] = key;
        ev["from"] = name_or_null(e.group);
        ev["to"] = name_or_null(group);
        out.events.push(ev);
        e.group = group;
    }
    return out;
}

// ---- Groups, "Output order of groups" ---------------------------------------

// Named groups in byte order of their name, then the unnamed groups in key
// order of their one member; members in key order.
std::vector<Group> Engine::groups_in_output_order() const {
    std::map<std::string, std::vector<const Entity*>> named;
    std::vector<Group> unnamed;
    for (const auto& kv : entities_) {
        const Entity& e = kv.second;
        if (e.group) named[*e.group].push_back(&e);
        else unnamed.push_back({std::nullopt, {&e}});
    }
    std::vector<Group> out;
    for (auto& kv : named) out.push_back({kv.first, std::move(kv.second)});
    for (auto& g : unnamed) out.push_back(std::move(g));
    return out;
}

// ---- Fused event -----------------------------------------------------------

Json Engine::fused_event(const Group& g, const Kinematics& k, Json attributes) const {
    Json ev = event("fused");
    ev["group"] = name_or_null(g.name);
    Json members = Json::make_array();
    for (const Entity* e : g.members) members.push(e->key);
    ev["members"] = members;
    ev["from"] = k.from ? Json(k.from->key) : Json();

    auto pos = to_degrees(ref_->first, ref_->second, k.f.east.p, k.f.north.p);
    ev["lat"] = pos.first;
    ev["lon"] = pos.second;
    double course = deg(std::atan2(k.f.east.v, k.f.north.v));
    if (course < 0) course += 360;
    if (course >= 360) course -= 360;
    ev["course"] = course;
    ev["speed_ms"] = std::hypot(k.f.east.v, k.f.north.v);
    ev["ce"] = std::sqrt((k.f.east.pp + k.f.north.pp) / 2);

    // "Height": the kinematics member's `hae` for best, priority and latest;
    // for the two weighted methods, the member with the greatest
    // last_time_ms whose last report has `hae`, ties to key order.
    const Entity* hae_from = nullptr;
    if (k.from) {
        if (number_at(k.from->report, "hae")) hae_from = k.from;
    } else {
        for (const Entity* e : g.members)
            if (number_at(e->report, "hae") && (!hae_from || e->last_time_ms > hae_from->last_time_ms))
                hae_from = e;
    }
    if (hae_from) {
        ev["hae"] = *number_at(hae_from->report, "hae");
        ev["hae_from"] = hae_from->key;
    }
    ev["attributes"] = std::move(attributes);
    return ev;
}

// ---- On each tick ----------------------------------------------------------

Output Engine::tick(std::int64_t now_ms) {
    Output out;

    // 1. Staleness, entities in key order.
    for (auto it = entities_.begin(); it != entities_.end();) {
        const Entity& e = it->second;
        const Json* report_stale = e.report.find("stale_ms");
        bool stale = now_ms - e.last_time_ms > pack_.stale_ms ||
                     (is_integer(report_stale) && now_ms >= report_stale->integer);
        if (!stale) {
            ++it;
            continue;
        }
        Json ev = event("drop");
        ev["entity"] = e.key;
        ev["group"] = name_or_null(e.group);
        out.events.push(ev);
        it = entities_.erase(it);
    }

    // 2. Fused output, groups in output order.
    for (const Group& g : groups_in_output_order()) {
        // 2.1 Predict every member to now_ms.
        std::vector<Predicted> members;
        for (const Entity* e : g.members)
            members.push_back({e, filter_predict(e->filter, e->last_time_ms, now_ms, pack_.filter.accel_var)});

        // 2.2 Combine by the kinematics method; Trace records 1 and 2.
        Kinematics k = combine(pack_.kinematics, g, members, pack_.sources, out);
        Json rec = Json::make_object();
        rec["stage"] = "kinematics";
        rec["group"] = name_or_null(g.name);
        rec["method"] = method_name(pack_.kinematics);
        Json list = Json::make_array();
        for (const Predicted& m : members) {
            Json j = Json::make_object();
            j["member"] = m.entity->key;
            j["var"] = m.var();
            j["time_ms"] = static_cast<long long>(m.entity->last_time_ms);
            auto r = rank(pack_.sources, m.entity->source);
            j["rank"] = r ? Json(static_cast<long long>(*r)) : Json();
            list.push(j);
        }
        rec["candidates"] = list;
        rec["winner"] = k.from ? Json(k.from->key) : Json();
        out.trace.push(rec);

        // 2.3 Decide every attribute, in pack order; Trace record 3.
        Json attributes = Json::make_object();
        for (const Attribute& a : pack_.attributes) decide_attribute(g, a, pack_.sources, attributes, out);

        // 2.4 The fused event.
        out.events.push(fused_event(g, k, std::move(attributes)));
    }
    return out;
}

// ---- Snapshot --------------------------------------------------------------

Json Engine::snapshot() const {
    Json s = Json::make_object();
    s["ref"] = snapshot::ref_json(ref_);
    Json entities = Json::make_object();
    for (const auto& kv : entities_) {
        const Entity& e = kv.second;
        Json j = Json::make_object();
        j["last_time_ms"] = static_cast<long long>(e.last_time_ms);
        j["group"] = name_or_null(e.group);
        j["filter"] = snapshot::filter_json(e.filter);
        j["report"] = e.report;
        entities[kv.first] = j;
    }
    s["entities"] = entities;
    return s;
}

} // namespace corr::fuse
