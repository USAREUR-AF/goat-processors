// correlate.md "Association", "On each tick" (method confirm), "Snapshot"
// (method confirm). The confirm method's pipeline, moved here unchanged.
#include "correlate/confirm.hpp"

#include "model/report.hpp"
#include "snapshot/snapshot.hpp"

#include "correlate/common.hpp"

namespace corr::correlate {

using namespace detail;

// Spec "Association": A in a group holds, else associates.
void ConfirmMethod::accepted(Entity& a, Output& out) {
    if (a.group) hold(a, out);
    else associate(a, out);
}

// ---- Association -----------------------------------------------------------

bool ConfirmMethod::group_has_source(int g, const std::string& source) const {
    for (const auto& k : groups_.at(g))
        if (entities_.at(k).source == source) return true;
    return false;
}

// `leave`, then `dissolve` when one member is left.
void ConfirmMethod::leave_group(Entity& e, const char* reason, Output& out) {
    int g = e.group;
    auto& members = groups_.at(g);
    members.erase(e.key);
    e.group = 0;
    Json ev = event("leave");
    ev["group"] = group_name(g);
    ev["entity"] = e.key;
    ev["reason"] = reason;
    out.events.push(ev);
    if (members.size() == 1) {
        std::string last = *members.begin();
        Entity& rest = entities_.at(last);
        rest.group = 0;
        rest.hold_failures = 0;
        Json d = event("dissolve");
        d["group"] = group_name(g);
        d["entity"] = last;
        out.events.push(d);
        groups_.erase(g);
    }
}

// Spec "Association": A is in a group G: hold. Other members in key order;
// the hold passes at the first member for which every test passes.
void ConfirmMethod::hold(Entity& a, Output& out) {
    bool any = false;
    for (const std::string& bk : groups_.at(a.group)) {
        if (bk == a.key) continue;
        const Entity& b = entities_.at(bk);
        if (run_stage("hold", pack_.hold, a, b, predict_for_comparison(b, a.last_time_ms), out)) {
            any = true;
            break;
        }
    }
    if (any) {
        a.hold_failures = 0;
    } else if (++a.hold_failures >= pack_.hold_failures) {
        a.hold_failures = 0;
        leave_group(a, "hold", out);
    }
}

// Spec "Association": A is not in a group: associate.
void ConfirmMethod::associate(Entity& a, Output& out) {
    std::vector<std::string> reached;
    for (const auto& kv : entities_) {
        const Entity& b = kv.second;
        if (b.key == a.key) continue;
        if (!pack_.same_source_allow) {
            if (b.source == a.source) continue;
            if (b.group && group_has_source(b.group, a.source)) continue;
        }
        Filter bp = predict_for_comparison(b, a.last_time_ms);
        bool ok = run_stage("gate", pack_.gate, a, b, bp, out) && run_stage("confirm", pack_.confirm, a, b, bp, out);

        std::int64_t& count = counts_[pair_key(a.key, b.key)];
        count = ok ? count + 1 : 0;
        Json rec = Json::make_object();
        rec["stage"] = "confirm";
        rec["a"] = a.key;
        rec["b"] = b.key;
        rec["test"] = "count";
        rec["value"] = static_cast<long long>(count);
        rec["limit"] = static_cast<long long>(pack_.confirm_count);
        rec["pass"] = count >= pack_.confirm_count;
        out.trace.push(rec);
        if (count >= pack_.confirm_count) reached.push_back(b.key);
    }

    // Choice by smallest d², ties to key order; each is a `rank` record.
    std::string chosen;
    double best = 0;
    for (const std::string& bk : reached) {
        double v = d2(a, predict_for_comparison(entities_.at(bk), a.last_time_ms));
        Json rec = Json::make_object();
        rec["stage"] = "rank";
        rec["a"] = a.key;
        rec["b"] = bk;
        rec["test"] = "rank";
        rec["value"] = v;
        rec["limit"] = Json();
        rec["pass"] = true;
        out.trace.push(rec);
        if (chosen.empty() || v < best) { chosen = bk; best = v; }
    }
    if (chosen.empty()) return;

    Entity& b = entities_.at(chosen);
    counts_[pair_key(a.key, b.key)] = 0;
    if (b.group) {
        groups_.at(b.group).insert(a.key);
        a.group = b.group;
        Json ev = event("join");
        ev["group"] = group_name(a.group);
        ev["entity"] = a.key;
        out.events.push(ev);
    } else {
        int g = next_group_++;
        groups_[g] = {a.key, b.key};
        a.group = b.group = g;
        Json ev = event("correlate");
        ev["group"] = group_name(g);
        Json members = Json::make_array();
        for (const auto& m : groups_[g]) members.push(m);
        ev["members"] = members;
        out.events.push(ev);
    }
}

Output ConfirmMethod::tick(std::int64_t now_ms) {
    Output out;

    // 1. Staleness, entities in key order.
    std::vector<std::string> keys;
    for (const auto& kv : entities_) keys.push_back(kv.first);
    for (const std::string& k : keys) {
        Entity& e = entities_.at(k);
        if (!is_stale(e, now_ms)) continue;
        if (e.group) leave_group(e, "stale", out);
        for (auto c = counts_.begin(); c != counts_.end();) {
            if (c->first.first == k || c->first.second == k) c = counts_.erase(c);
            else ++c;
        }
        entities_.erase(k);
        Json ev = event("drop");
        ev["entity"] = k;
        out.events.push(ev);
    }

    // 2. Fused output, groups in creation order.
    for (const auto& kv : groups_) {
        const Entity* primary = nullptr;
        for (const std::string& m : kv.second) {
            const Entity& e = entities_.at(m);
            if (!primary) { primary = &e; continue; }
            if (pack_.output_latest) {
                if (e.last_time_ms > primary->last_time_ms) primary = &e;
            } else {
                auto prio = [&](const Entity& x) {
                    auto p = pack_.priority.find(x.source);
                    return p == pack_.priority.end() ? std::int64_t{100} : p->second;
                };
                if (prio(e) < prio(*primary)) primary = &e;
            }
        }
        Filter f = predict(*primary, now_ms);
        auto pos = to_degrees(f.east.p, f.north.p);
        double ve = f.east.v, vn = f.north.v;

        Json ev = event("fused");
        ev["group"] = group_name(kv.first);
        ev["primary"] = primary->key;
        Json members = Json::make_array();
        for (const auto& m : kv.second) members.push(m);
        ev["members"] = members;
        ev["lat"] = pos.first;
        ev["lon"] = pos.second;
        ev["course"] = course_of(ve, vn);
        ev["speed_ms"] = std::hypot(ve, vn);
        if (auto hae = number_at(primary->last, "hae")) ev["hae"] = *hae;
        out.events.push(ev);
    }
    return out;
}

Json ConfirmMethod::snapshot() const {
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
        j["group"] = e.group ? Json(group_name(e.group)) : Json();
        j["hold_failures"] = static_cast<long long>(e.hold_failures);
        filter_json(e, j);
        entities[kv.first] = j;
    }
    s["entities"] = entities;
    Json groups = Json::make_object();
    for (const auto& kv : groups_) {
        Json members = Json::make_array();
        for (const auto& m : kv.second) members.push(m);
        groups[group_name(kv.first)] = members;
    }
    s["groups"] = groups;
    Json counts = Json::make_object();
    for (const auto& kv : counts_)
        counts[kv.first.first + "|" + kv.first.second] = static_cast<long long>(kv.second);
    s["counts"] = counts;
    s["next_group"] = next_group_;
    return s;
}

} // namespace corr::correlate
