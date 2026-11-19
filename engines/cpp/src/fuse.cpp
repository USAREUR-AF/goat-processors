// fuse.md, section by section. Frame, Track estimate and the reading of
// report keys are correlate.md's, from track.hpp (fuse.md "Shared with
// correlate.md").
#include "fuse.hpp"

#include <cmath>

namespace corr::fuse {

namespace {

Json event(const char* ev) {
    Json e = Json::make_object();
    e["ev"] = ev;
    return e;
}

Json name_or_null(const std::optional<std::string>& name) { return name ? Json(*name) : Json(); }

// fuse.md "Reports": `fuse.group` is absent when it is `null`, not a string,
// or the empty string.
std::optional<std::string> group_of(const Json& report) {
    const Json* g = report.find("fuse.group");
    if (!g || !g->is_string() || g->string.empty()) return std::nullopt;
    return g->string;
}

// fuse.md "Reports", the normalised report: every key removed that is `null`,
// or that correlate.md Reports or the `fuse.group` rule treats as absent.
Json normalise(const Json& r) {
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

// fuse.md "Attributes": a usable value is a string, a number or a boolean
// for `priority`, `latest` and `majority`; a number for `max` and `min`.
bool usable(const Json& v, Rule rule) {
    if (rule == Rule::Max || rule == Rule::Min) return v.is_number();
    return v.is_string() || v.is_number() || v.kind == Json::Kind::Bool;
}

// fuse.md "Attributes", equality for `majority`: strings by bytes, numbers by
// value (`1` equals `1.0`), booleans by value; different kinds never equal.
bool majority_equal(const Json& a, const Json& b) {
    if (a.kind != b.kind) return false;
    if (a.is_number()) return a.number == b.number;
    return json_equal(a, b);
}

} // namespace

Engine::Engine(Pack pack) : pack_(std::move(pack)) {}

// ---- Kinematics, "Rank" ----------------------------------------------------

// The index of the member's source among the `source` lines, or nullopt
// when the source is not listed.
std::optional<std::int64_t> Engine::rank(const Entity& e) const {
    for (size_t i = 0; i < pack_.sources.size(); ++i)
        if (pack_.sources[i] == e.source) return static_cast<std::int64_t>(i);
    return std::nullopt;
}

// Rank for comparison: an unlisted source ranks after every listed source.
std::int64_t Engine::rank_order(const Entity& e) const {
    return rank(e).value_or(static_cast<std::int64_t>(pack_.sources.size()));
}

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

    // Every value read from here on comes from the normalised report.
    Json report = normalise(r);
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

// ---- Kinematics ------------------------------------------------------------

Engine::Kinematics Engine::combine(const Group& g, const std::vector<Predicted>& members,
                                   Output& out) const {
    switch (pack_.kinematics) {
        case Method::InverseVariance:
            return inverse_variance(members);
        case Method::CovarianceIntersection:
            return covariance_intersection(g, members, out);
        case Method::Best: {
            // The member with the smallest var, ties to key order.
            const Predicted* w = &members[0];
            for (const Predicted& m : members)
                if (m.var() < w->var()) w = &m;
            return {w->f, w->entity};
        }
        case Method::Priority: {
            // The member with the smallest rank, ties to key order.
            const Predicted* w = &members[0];
            for (const Predicted& m : members)
                if (rank_order(*m.entity) < rank_order(*w->entity)) w = &m;
            return {w->f, w->entity};
        }
        case Method::Latest: {
            // The member with the greatest last_time_ms, ties to key order.
            const Predicted* w = &members[0];
            for (const Predicted& m : members)
                if (m.entity->last_time_ms > w->entity->last_time_ms) w = &m;
            return {w->f, w->entity};
        }
    }
    return {};
}

// "inverse_variance": per axis, members in key order, sums of the inverse
// variances and of the variance-weighted values. With one member, that
// member's predicted filter.
Engine::Kinematics Engine::inverse_variance(const std::vector<Predicted>& members) const {
    if (members.size() == 1) return {members[0].f, nullptr};
    Filter out;
    for (int axis = 0; axis < 2; ++axis) {
        double ip = 0, sp = 0, iv = 0, sv = 0;
        for (const Predicted& m : members) {
            const Axis& a = axis == 0 ? m.f.east : m.f.north;
            ip = ip + 1 / a.pp;
            sp = sp + a.p / a.pp;
            iv = iv + 1 / a.vv;
            sv = sv + a.v / a.vv;
        }
        Axis& r = axis == 0 ? out.east : out.north;
        r.pp = 1 / ip;
        r.p = r.pp * sp;
        r.vv = 1 / iv;
        r.v = r.vv * sv;
    }
    return {out, nullptr};
}

// "covariance_intersection": fold the members in key order into X, which
// starts as the first member; each fold is one `intersect` trace record.
Engine::Kinematics Engine::covariance_intersection(const Group& g, const std::vector<Predicted>& members,
                                                   Output& out) const {
    Filter x = members[0].f;
    for (size_t k = 1; k < members.size(); ++k) {
        const Filter& y = members[k].f;

        // "Weight", steps 1 to 5.
        double ae = 1 / y.east.pp, an = 1 / y.north.pp;
        double de = 1 / x.east.pp - ae, dn = 1 / x.north.pp - an;
        double c2 = de * dn;
        double c1 = ae * dn + an * de;
        double w;
        if (c2 < 0) {
            w = -c1 / (2 * c2);
            if (w < 0) w = 0;
            if (w > 1) w = 1;
        } else if (c1 + c2 > 0) {
            w = 1;
        } else if (c1 + c2 < 0) {
            w = 0;
        } else {
            w = 0.5;
        }

        Json rec = Json::make_object();
        rec["stage"] = "intersect";
        rec["group"] = name_or_null(g.name);
        rec["member"] = members[k].entity->key;
        rec["value"] = w;
        out.trace.push(rec);

        // "Fold": w = 1 keeps X, w = 0 takes Y, otherwise per axis.
        if (w == 1) continue;
        if (w == 0) {
            x = y;
            continue;
        }
        Filter folded;
        for (int axis = 0; axis < 2; ++axis) {
            const Axis& xa = axis == 0 ? x.east : x.north;
            const Axis& ya = axis == 0 ? y.east : y.north;
            Axis& r = axis == 0 ? folded.east : folded.north;
            double a = w / xa.pp, b = (1 - w) / ya.pp;
            r.pp = 1 / (a + b);
            r.p = r.pp * (a * xa.p + b * ya.p);
            double c = w / xa.vv, d = (1 - w) / ya.vv;
            r.vv = 1 / (c + d);
            r.v = r.vv * (c * xa.v + d * ya.v);
        }
        x = folded;
    }
    return {x, nullptr};
}

// ---- Attributes ------------------------------------------------------------

// Decides one `attribute` line for a group: adds `{value, from}` to
// `attributes` when there is a candidate, and gives its trace record.
void Engine::decide_attribute(const Group& g, const Attribute& attr, Json& attributes, Output& out) const {
    // Candidates: members in key order whose last report holds a usable value.
    struct Candidate {
        const Entity* entity;
        const Json* value;
    };
    std::vector<Candidate> candidates;
    for (const Entity* e : g.members) {
        const Json* v = e->report.find(attr.key);
        if (v && usable(*v, attr.rule)) candidates.push_back({e, v});
    }

    const Candidate* winner = nullptr;
    if (!candidates.empty()) {
        winner = &candidates[0];
        switch (attr.rule) {
            case Rule::Priority:   // smallest rank, ties to key order
                for (const Candidate& c : candidates)
                    if (rank_order(*c.entity) < rank_order(*winner->entity)) winner = &c;
                break;
            case Rule::Latest:     // greatest last_time_ms, ties to key order
                for (const Candidate& c : candidates)
                    if (c.entity->last_time_ms > winner->entity->last_time_ms) winner = &c;
                break;
            case Rule::Max:        // greatest value, ties to key order
                for (const Candidate& c : candidates)
                    if (c.value->number > winner->value->number) winner = &c;
                break;
            case Rule::Min:        // smallest value, ties to key order
                for (const Candidate& c : candidates)
                    if (c.value->number < winner->value->number) winner = &c;
                break;
            case Rule::Majority: {
                // Count each distinct value; distinct values are kept in the
                // order of their first holder, so a strict `>` gives a tie to
                // the value whose first holder comes first. The winner is that
                // first holder.
                struct Tally {
                    const Candidate* first;
                    int count;
                };
                std::vector<Tally> tallies;
                for (const Candidate& c : candidates) {
                    bool counted = false;
                    for (Tally& t : tallies)
                        if (majority_equal(*t.first->value, *c.value)) {
                            ++t.count;
                            counted = true;
                            break;
                        }
                    if (!counted) tallies.push_back({&c, 1});
                }
                const Tally* best = &tallies[0];
                for (const Tally& t : tallies)
                    if (t.count > best->count) best = &t;
                winner = best->first;
                break;
            }
        }
    }

    if (winner) {
        Json a = Json::make_object();
        a["value"] = *winner->value;
        a["from"] = winner->entity->key;
        attributes[attr.key] = a;
    }

    // Trace, record 3.
    Json rec = Json::make_object();
    rec["stage"] = "attribute";
    rec["group"] = name_or_null(g.name);
    rec["key"] = attr.key;
    rec["rule"] = rule_name(attr.rule);
    Json list = Json::make_array();
    for (const Candidate& c : candidates) {
        Json j = Json::make_object();
        j["member"] = c.entity->key;
        j["value"] = *c.value;
        j["time_ms"] = static_cast<long long>(c.entity->last_time_ms);
        auto r = rank(*c.entity);
        j["rank"] = r ? Json(static_cast<long long>(*r)) : Json();
        list.push(j);
    }
    rec["candidates"] = list;
    rec["winner"] = winner ? Json(winner->entity->key) : Json();
    rec["value"] = winner ? *winner->value : Json();
    out.trace.push(rec);
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
        Kinematics k = combine(g, members, out);
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
            auto r = rank(*m.entity);
            j["rank"] = r ? Json(static_cast<long long>(*r)) : Json();
            list.push(j);
        }
        rec["candidates"] = list;
        rec["winner"] = k.from ? Json(k.from->key) : Json();
        out.trace.push(rec);

        // 2.3 Decide every attribute, in pack order; Trace record 3.
        Json attributes = Json::make_object();
        for (const Attribute& a : pack_.attributes) decide_attribute(g, a, attributes, out);

        // 2.4 The fused event.
        out.events.push(fused_event(g, k, std::move(attributes)));
    }
    return out;
}

// ---- Snapshot --------------------------------------------------------------

Json Engine::snapshot() const {
    Json s = Json::make_object();
    if (ref_) {
        Json ref = Json::make_array();
        ref.push(ref_->first);
        ref.push(ref_->second);
        s["ref"] = ref;
    } else {
        s["ref"] = Json();
    }
    Json entities = Json::make_object();
    for (const auto& kv : entities_) {
        const Entity& e = kv.second;
        Json j = Json::make_object();
        j["last_time_ms"] = static_cast<long long>(e.last_time_ms);
        j["group"] = name_or_null(e.group);
        Json f = Json::make_object();
        f["east"] = axis_json(e.filter.east);
        f["north"] = axis_json(e.filter.north);
        j["filter"] = f;
        j["report"] = e.report;
        entities[kv.first] = j;
    }
    s["entities"] = entities;
    return s;
}

} // namespace corr::fuse
