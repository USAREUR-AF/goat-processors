// correlate.md "Association", "On each tick" (method confirm), "Snapshot"
// (method confirm). The confirm method's pipeline, moved here unchanged.
#include "correlate/confirm.hpp"

#include "model/report.hpp"
#include "snapshot/snapshot.hpp"

#include "correlate/common.hpp"

#include <algorithm>
#include <cmath>

namespace corr::correlate {

using namespace detail;

// correlate.md "Association": A in a group holds (with `sprt`, updates its
// link), else associates.
void ConfirmMethod::accepted(Entity& a, Output& out) {
    if (pack_.sprt) {
        if (a.group) sprt_linked(a, out);
        else sprt_associate(a, out);
        return;
    }
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
    out.events.push(std::move(ev));
    if (members.size() == 1) {
        std::string last = *members.begin();
        Entity& rest = entities_.at(last);
        rest.group = 0;
        rest.hold_failures = 0;
        Json d = event("dissolve");
        d["group"] = group_name(g);
        d["entity"] = last;
        out.events.push(std::move(d));
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

// correlate.md "Association", associate: every other entity in key order,
// leaving out B of A's source and B in a group holding A's source (both
// unless same_source allow).
std::vector<std::string> ConfirmMethod::candidates(const Entity& a) const {
    std::vector<std::string> out;
    for (const auto& kv : entities_) {
        const Entity& b = kv.second;
        if (b.key == a.key) continue;
        if (!pack_.same_source_allow) {
            if (b.source == a.source) continue;
            if (b.group && group_has_source(b.group, a.source)) continue;
        }
        out.push_back(b.key);
    }
    return out;
}

// Spec "Association": A is not in a group: associate.
void ConfirmMethod::associate(Entity& a, Output& out) {
    std::vector<std::string> reached;
    for (const std::string& bk : candidates(a)) {
        const Entity& b = entities_.at(bk);
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
        out.trace.push(std::move(rec));
        if (count >= pack_.confirm_count) reached.push_back(b.key);
    }
    choose(a, reached, out);
}

// Of the candidates that reached confirmation (in key order), the one with
// the smallest position d², ties to key order, each with its `rank` record;
// A joins its group or correlates with it. Without `sprt` the chosen pair's
// count is reset to 0; with it the pair keeps its L.
void ConfirmMethod::choose(Entity& a, const std::vector<std::string>& reached, Output& out) {
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
        out.trace.push(std::move(rec));
        if (chosen.empty() || v < best) { chosen = bk; best = v; }
    }
    if (chosen.empty()) return;

    Entity& b = entities_.at(chosen);
    if (!pack_.sprt) counts_[pair_key(a.key, b.key)] = 0;
    if (b.group) {
        groups_.at(b.group).insert(a.key);
        a.group = b.group;
        Json ev = event("join");
        ev["group"] = group_name(a.group);
        ev["entity"] = a.key;
        out.events.push(std::move(ev));
    } else {
        int g = next_group_++;
        groups_[g] = {a.key, b.key};
        a.group = b.group = g;
        Json ev = event("correlate");
        ev["group"] = group_name(g);
        Json members = Json::make_array();
        for (const auto& m : groups_[g]) members.push(m);
        ev["members"] = std::move(members);
        out.events.push(std::move(ev));
    }
}

// ---- Sequential test (correlate.md "Association") -------------------------

// The `same` tests of the `gate` line, in pack order, up to the first that
// fails; each writes its `gate` record when `out` is given.
bool ConfirmMethod::same_tests_pass(const Entity& a, const Entity& b, const Filter& bp, Output* out) const {
    for (const TestSpec& t : pack_.gate) {
        if (t.name != "same") continue;
        if (out) {
            if (!run_stage("gate", std::vector<TestSpec>{t}, a, b, bp, *out)) return false;
        } else if (!t.run(t, {a, b, bp, pack_.filter.default_ce_m}).pass) {
            return false;
        }
    }
    return true;
}

double ConfirmMethod::sprt_update(const Entity& a, const Entity& b, const Filter& bp, bool forced, Output& out) {
    const SprtParams& sp = *pack_.sprt;
    const double up = std::log((1 - sp.missed) / sp.false_p);
    const double lo = std::log(sp.missed / (1 - sp.false_p));
    auto found = llr_.find(pair_key(a.key, b.key));
    double& L = found == llr_.end() ? llr_[pair_key(a.key, b.key)] : found->second;   // 0 when new
    Json increment, d2v;
    if (forced) {
        L = lo;
    } else {
        const SprtEvidence ev = sprt_evidence(a.filter, a.timing, bp, number_at(a.last, "hae"),
                                              number_at(b.last, "hae"), sp);
        L = std::min(std::max(L + ev.increment, lo), up);
        increment = ev.increment;
        d2v = ev.d2;
    }
    Json rec = Json::make_object();
    rec["stage"] = "sprt";
    rec["a"] = a.key;
    rec["b"] = b.key;
    rec["test"] = "llr";
    rec["value"] = L;
    rec["limit"] = up;
    rec["pass"] = L >= up;
    rec["lower"] = lo;
    rec["increment"] = std::move(increment);
    rec["d2"] = std::move(d2v);
    out.trace.push(std::move(rec));
    return L;
}

// A is in a group G: only the pair with A's link is updated; at lo or below
// A leaves G (reason `release`) and its pairs at lo or below are removed.
void ConfirmMethod::sprt_linked(Entity& a, Output& out) {
    const std::string* link = nullptr;
    double best = 0;
    for (const std::string& bk : groups_.at(a.group)) {
        if (bk == a.key) continue;
        auto it = llr_.find(pair_key(a.key, bk));
        const double L = it == llr_.end() ? 0.0 : it->second;
        if (!link || L > best) { link = &bk; best = L; }
    }
    const Entity& b = entities_.at(*link);
    const Filter bp = predict_for_comparison(b, a.last_time_ms);
    const bool forced = !same_tests_pass(a, b, bp, &out);
    const double lo = std::log(pack_.sprt->missed / (1 - pack_.sprt->false_p));
    if (sprt_update(a, b, bp, forced, out) > lo) return;
    leave_group(a, "release", out);
    for (auto it = llr_.begin(); it != llr_.end();) {
        if ((it->first.first == a.key || it->first.second == a.key) && it->second <= lo) it = llr_.erase(it);
        else ++it;
    }
}

// A is not in a group: the candidates of associate, each tested and its
// pair updated; a pair at lo or below is removed, one at up is ready.
void ConfirmMethod::sprt_associate(Entity& a, Output& out) {
    const SprtParams& sp = *pack_.sprt;
    const double up = std::log((1 - sp.missed) / sp.false_p);
    const double lo = std::log(sp.missed / (1 - sp.false_p));
    std::vector<std::string> ready;
    for (const std::string& bk : candidates(a)) {
        const Entity& b = entities_.at(bk);
        const Filter bp = predict_for_comparison(b, a.last_time_ms);
        const bool ok =
            run_stage("gate", pack_.gate, a, b, bp, out) && run_stage("confirm", pack_.confirm, a, b, bp, out);
        const auto key = pair_key(a.key, b.key);
        bool forced = false;
        if (!ok) {
            if (!llr_.count(key)) continue;
            forced = !same_tests_pass(a, b, bp, nullptr);
        }
        const double L = sprt_update(a, b, bp, forced, out);
        if (L <= lo) llr_.erase(key);
        else if (L >= up) ready.push_back(bk);
    }
    choose(a, ready, out);
}

// correlate.md "On each tick", 2: the `fused` event of group g. With
// `output fused`, the information-weighted combination of every member's
// filter predicted to now_ms (no timing variance); otherwise the primary's.
Json ConfirmMethod::fused_event(int g, const std::set<std::string>& members, std::int64_t now_ms) const {
    Filter f;
    const Entity* primary = nullptr;
    const Entity* height = nullptr;   // the member whose `hae` is given
    if (pack_.output == OutputMode::fused) {
        double pe = 0, we = 0, pn = 0, wn = 0, ve = 0, wve = 0, vn = 0, wvn = 0;
        for (const std::string& m : members) {
            const Entity& e = entities_.at(m);
            const Filter x = predict(e, now_ms);
            pe = pe + x.east.p / x.east.pp;
            we = we + 1 / x.east.pp;
            pn = pn + x.north.p / x.north.pp;
            wn = wn + 1 / x.north.pp;
            ve = ve + x.east.v / x.east.vv;
            wve = wve + 1 / x.east.vv;
            vn = vn + x.north.v / x.north.vv;
            wvn = wvn + 1 / x.north.vv;
            if (number_at(e.last, "hae") && (!height || e.last_time_ms > height->last_time_ms)) height = &e;
        }
        f.east.p = pe / we;
        f.north.p = pn / wn;
        f.east.v = ve / wve;
        f.north.v = vn / wvn;
    } else {
        auto prio = [&](const Entity& x) {
            auto p = pack_.priority.find(x.source);
            return p == pack_.priority.end() ? std::int64_t{100} : p->second;
        };
        for (const std::string& m : members) {
            const Entity& e = entities_.at(m);
            if (!primary) primary = &e;
            else if (pack_.output == OutputMode::latest ? e.last_time_ms > primary->last_time_ms
                                                       : prio(e) < prio(*primary))
                primary = &e;
        }
        f = predict(*primary, now_ms);
        height = primary;
    }
    auto pos = to_degrees(f.east.p, f.north.p);
    double ve = f.east.v, vn = f.north.v;

    Json ev = event("fused");
    ev["group"] = group_name(g);
    ev["primary"] = primary ? Json(primary->key) : Json();
    Json list = Json::make_array();
    for (const auto& m : members) list.push(m);
    ev["members"] = std::move(list);
    ev["lat"] = pos.first;
    ev["lon"] = pos.second;
    ev["course"] = course_of(ve, vn);
    ev["speed_ms"] = std::hypot(ve, vn);
    if (height)
        if (auto hae = number_at(height->last, "hae")) ev["hae"] = *hae;
    return ev;
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
        for (auto c = llr_.begin(); c != llr_.end();) {
            if (c->first.first == k || c->first.second == k) c = llr_.erase(c);
            else ++c;
        }
        entities_.erase(k);
        Json ev = event("drop");
        ev["entity"] = k;
        out.events.push(std::move(ev));
    }

    // 2. Fused output, groups in creation order.
    for (const auto& kv : groups_) out.events.push(fused_event(kv.first, kv.second, now_ms));
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
    if (pack_.sprt) {
        Json llr = Json::make_object();
        for (const auto& kv : llr_) llr[kv.first.first + "|" + kv.first.second] = kv.second;
        s["llr"] = llr;
    }
    if (pack_.stale_rate) s["intervals"] = core_.intervals_json();
    return s;
}

} // namespace corr::correlate
