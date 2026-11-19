#include "engine.hpp"
#include "kalman.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

namespace corr {

namespace {

// Report values; a null value counts as absent.
std::optional<double> number_at(const Json& r, const std::string& key) {
    const Json* v = r.find(key);
    if (!v || !v->is_number()) return std::nullopt;
    return v->number;
}

// Spec "Reports": a `ce` of 0 or below is absent.
std::optional<double> ce_at(const Json& r) {
    auto ce = number_at(r, "ce");
    if (ce && *ce <= 0) return std::nullopt;
    return ce;
}

// Spec "Reports": `time_ms` and `stale_ms` must be integers.
bool is_integer(const Json* v) { return v && v->is_number() && v->is_int; }

// Spec "Reports": `@env` is the third `-`-separated element of `type`.
std::optional<Json> same_value(const Json& r, const std::string& key) {
    if (key == "@env") {
        const Json* t = r.find("type");
        if (!t || !t->is_string()) return std::nullopt;
        std::vector<std::string> parts;
        std::string cur;
        for (char c : t->string) {
            if (c == '-') { parts.push_back(cur); cur.clear(); }
            else cur += c;
        }
        parts.push_back(cur);
        if (parts.size() < 3) return std::nullopt;
        return Json(parts[2]);
    }
    const Json* v = r.find(key);
    if (!v || v->is_null()) return std::nullopt;
    return *v;
}

Json event(const char* ev) {
    Json e = Json::make_object();
    e["ev"] = ev;
    return e;
}

} // namespace

Engine::Engine(Pack pack) : pack_(std::move(pack)) {}

// ---- Frame -----------------------------------------------------------------

Engine::Point Engine::to_plane(double lat, double lon) const {
    return corr::to_plane(ref_->first, ref_->second, lat, lon);
}

std::pair<double, double> Engine::to_degrees(double east, double north) const {
    const double lat0 = ref_->first, lon0 = ref_->second;
    double lat = lat0 + deg(north / EARTH_R);
    double lon = lon0 + deg(east / (EARTH_R * std::cos(rad(lat0))));
    return {lat, wrap180(lon)};
}

// ---- Track estimate --------------------------------------------------------

void Engine::filter_first(Entity& e, const Point& z, const std::optional<Point>& vel, double ce) const {
    corr::filter_first(e.filter, z, vel, ce, pack_.filter);
}

void Engine::filter_update(Entity& e, const Point& z, const std::optional<Point>& vel, double ce,
                           double dt) const {
    corr::filter_update(e.filter, z, vel, ce, dt, pack_.filter);
}

// Spec "Track estimate", Prediction: step 1 on a copy.
Filter Engine::predict(const Entity& e, std::int64_t t) const {
    double dt = static_cast<double>(t - e.last_time_ms) / 1000;
    return filter_predict(e.filter, dt, pack_.filter.accel_var);
}

// ---- Tests -----------------------------------------------------------------

double Engine::ce_of(const Entity& e) const {
    return ce_at(e.last).value_or(pack_.filter.default_ce_m);
}

// Spec "Tests": d² = sum over east, north of (pa - pb)² / (pp_b + ce_a²).
double Engine::d2(const Entity& a, const Filter& b) const {
    double ce = ce_of(a), r = ce * ce;
    double de = a.filter.east.p - b.east.p, dn = a.filter.north.p - b.north.p;
    return de * de / (b.east.pp + r) + dn * dn / (b.north.pp + r);
}

Engine::TestResult Engine::run_test(const TestSpec& t, const Entity& a, const Entity& b,
                                    const Filter& bp) const {
    auto param = [&](const char* name) { return t.num.at(name); };
    auto skipped = [] { return TestResult{Json(), Json(), true, true}; };
    double de = a.filter.east.p - bp.east.p, dn = a.filter.north.p - bp.north.p;
    double dist = std::sqrt(de * de + dn * dn);

    if (t.name == "distance") {
        double max_m = param("max_m");
        return {dist, max_m, dist < max_m, false};
    }
    if (t.name == "window") {
        auto clamp = [&](double e) { return std::min(std::max(e, param("err_min_m")), param("err_max_m")); };
        double ea = clamp(ce_of(a)), eb = clamp(ce_of(b));
        double limit = param("multiplier") * std::sqrt(ea * ea + eb * eb) + param("window_m");
        return {dist, limit, dist < limit, false};
    }
    if (t.name == "mahalanobis") {
        double v = d2(a, bp), gate = param("gate");
        return {v, gate, v < gate, false};
    }
    if (t.name == "course" || t.name == "speed") {
        auto ca = number_at(a.last, "course"), cb = number_at(b.last, "course");
        auto sa = number_at(a.last, "speed_ms"), sb = number_at(b.last, "speed_ms");
        double min_speed = param("min_speed_ms");
        if (!sa || !sb || *sa < min_speed || *sb < min_speed) return skipped();
        if (t.name == "course") {
            if (!ca || !cb) return skipped();
            double diff = std::abs(*ca - *cb);
            double v = std::min(diff, 360 - diff), max_deg = param("max_deg");
            return {v, max_deg, v <= max_deg, false};
        }
        double slow = std::min(*sa, *sb), fast = std::max(*sa, *sb);
        double v = fast == 0 ? 0.0 : std::abs(1 - slow / fast) * 100, max_pct = param("max_pct");
        return {v, max_pct, v <= max_pct, false};
    }
    if (t.name == "altitude") {
        auto ha = number_at(a.last, "hae"), hb = number_at(b.last, "hae");
        if (!ha || !hb) return skipped();
        double v = std::abs(*ha - *hb), max_m = param("max_m");
        return {v, max_m, v <= max_m, false};
    }
    // same
    auto va = same_value(a.last, t.key), vb = same_value(b.last, t.key);
    bool pass = (!va && !vb) || (va && vb && json_equal(*va, *vb));
    return {va ? *va : Json(), vb ? *vb : Json(), pass, false};
}

// Runs one stage's tests in pack order, writing each to the trace; stops at
// the first failure. Returns true when every test ran and passed.
bool Engine::run_stage(const char* stage, const std::vector<TestSpec>& tests, const Entity& a,
                       const Entity& b, const Filter& bp, Output& out) const {
    for (const TestSpec& t : tests) {
        TestResult r = run_test(t, a, b, bp);
        Json rec = Json::make_object();
        rec["stage"] = stage;
        rec["a"] = a.key;
        rec["b"] = b.key;
        rec["test"] = t.name;
        rec["value"] = r.value;
        rec["limit"] = r.limit;
        rec["pass"] = r.pass;
        if (r.skipped) rec["skipped"] = true;
        out.trace.push(rec);
        if (!r.pass) return false;
    }
    return true;
}

// ---- Association -----------------------------------------------------------

bool Engine::group_has_source(int g, const std::string& source) const {
    for (const auto& k : groups_.at(g))
        if (entities_.at(k).source == source) return true;
    return false;
}

// `leave`, then `dissolve` when one member is left.
void Engine::leave_group(Entity& e, const char* reason, Output& out) {
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
void Engine::hold(Entity& a, Output& out) {
    bool any = false;
    for (const std::string& bk : groups_.at(a.group)) {
        if (bk == a.key) continue;
        const Entity& b = entities_.at(bk);
        if (run_stage("hold", pack_.hold, a, b, predict(b, a.last_time_ms), out)) {
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
void Engine::associate(Entity& a, Output& out) {
    std::vector<std::string> reached;
    for (const auto& kv : entities_) {
        const Entity& b = kv.second;
        if (b.key == a.key) continue;
        if (!pack_.same_source_allow) {
            if (b.source == a.source) continue;
            if (b.group && group_has_source(b.group, a.source)) continue;
        }
        Filter bp = predict(b, a.last_time_ms);
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
        double v = d2(a, predict(entities_.at(bk), a.last_time_ms));
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

// ---- Operations ------------------------------------------------------------

Output Engine::ingest(const Json& r) {
    Output out;

    // Spec "Reports": required keys, in table order.
    const std::pair<const char*, char> required[] = {
        {"track.source_id", 's'}, {"uid", 's'}, {"time_ms", 'i'}, {"lat", 'n'}, {"lon", 'n'}};
    for (const auto& req : required) {
        const Json* v = r.find(req.first);
        bool ok = req.second == 's' ? v && v->is_string()
                : req.second == 'i' ? is_integer(v)
                                    : v && v->is_number();
        if (!ok) {
            Json ev = event("reject");
            ev["reason"] = std::string("missing:") + req.first;
            out.events.push(ev);
            return out;
        }
    }
    const std::string source = r.find("track.source_id")->string;
    const std::string key = source + "/" + r.find("uid")->string;
    const std::int64_t time_ms = r.find("time_ms")->integer;
    const double lat = r.find("lat")->number, lon = r.find("lon")->number;

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
    std::optional<Point> vel;
    auto course = number_at(r, "course"), speed = number_at(r, "speed_ms");
    if (course && speed) vel = velocity_of(*course, *speed);
    double ce = ce_at(r).value_or(pack_.filter.default_ce_m);

    if (it == entities_.end()) {
        Entity e;
        e.key = key;
        e.source = source;
        filter_first(e, z, vel, ce);
        it = entities_.emplace(key, std::move(e)).first;
        Json ev = event("new");
        ev["entity"] = key;
        out.events.push(ev);
    } else {
        double dt = static_cast<double>(time_ms - it->second.last_time_ms) / 1000;
        filter_update(it->second, z, vel, ce, dt);
    }
    Entity& a = it->second;
    a.last_time_ms = time_ms;
    a.last = r;

    if (pack_.method_assign) {
        reported_.insert(a.key);    // decided at the next tick
        return out;
    }
    if (a.group) hold(a, out);
    else associate(a, out);
    return out;
}

Output Engine::tick(std::int64_t now_ms) {
    if (pack_.method_assign) return tick_assign(now_ms);
    Output out;

    // 1. Staleness, entities in key order.
    std::vector<std::string> keys;
    for (const auto& kv : entities_) keys.push_back(kv.first);
    for (const std::string& k : keys) {
        Entity& e = entities_.at(k);
        auto report_stale = e.last.find("stale_ms");
        bool stale = now_ms - e.last_time_ms > pack_.stale_ms ||
                     (is_integer(report_stale) && now_ms >= report_stale->integer);
        if (!stale) continue;
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
        double course = deg(std::atan2(ve, vn));
        if (course < 0) course += 360;
        if (course >= 360) course -= 360;

        Json ev = event("fused");
        ev["group"] = group_name(kv.first);
        ev["primary"] = primary->key;
        Json members = Json::make_array();
        for (const auto& m : kv.second) members.push(m);
        ev["members"] = members;
        ev["lat"] = pos.first;
        ev["lon"] = pos.second;
        ev["course"] = course;
        ev["speed_ms"] = std::hypot(ve, vn);
        if (auto hae = number_at(primary->last, "hae")) ev["hae"] = *hae;
        out.events.push(ev);
    }
    return out;
}

Json Engine::snapshot() const {
    if (pack_.method_assign) return snapshot_assign();
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
        Json f = Json::make_object();
        f["east"] = axis_json(e.filter.east);
        f["north"] = axis_json(e.filter.north);
        j["filter"] = f;
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

// ---- Method assign (correlate-assign.md) ---------------------------------

// Hungarian method with row and column potentials (shortest augmenting paths).
// Rows and columns are 1-based inside; column 0 is the virtual start.
std::vector<int> min_cost_assignment(const std::vector<std::vector<double>>& cost) {
    const double INF = std::numeric_limits<double>::infinity();
    const size_t n = cost.size();
    if (n == 0) return {};
    const size_t m = cost[0].size();
    std::vector<double> u(n + 1, 0), v(m + 1, 0);
    std::vector<size_t> match(m + 1, 0), way(m + 1, 0);   // match[j]: row of column j
    for (size_t i = 1; i <= n; ++i) {
        match[0] = i;
        size_t j0 = 0;
        std::vector<double> minv(m + 1, INF);
        std::vector<bool> used(m + 1, false);
        do {
            used[j0] = true;
            size_t i0 = match[j0], j1 = 0;
            double delta = INF;
            for (size_t j = 1; j <= m; ++j) {
                if (used[j]) continue;
                double c = cost[i0 - 1][j - 1];
                if (c != INF) {
                    double cur = c - u[i0] - v[j];
                    if (cur < minv[j]) { minv[j] = cur; way[j] = j0; }
                }
                if (minv[j] < delta) { delta = minv[j]; j1 = j; }
            }
            if (j1 == 0) return {};   // no finite assignment
            for (size_t j = 0; j <= m; ++j) {
                if (used[j]) { u[match[j]] += delta; v[j] -= delta; }
                else if (minv[j] != INF) minv[j] -= delta;
            }
            j0 = j1;
        } while (match[j0] != 0);
        do {
            size_t j1 = way[j0];
            match[j0] = match[j1];
            j0 = j1;
        } while (j0 != 0);
    }
    std::vector<int> out(n, -1);
    for (size_t j = 1; j <= m; ++j)
        if (match[j]) out[match[j] - 1] = static_cast<int>(j - 1);
    return out;
}

// "Fused estimate": per axis, inverse-variance weights of the members
// predicted to t. Only p, v, pp and vv are meaningful.
Filter Engine::fuse(const std::vector<const Entity*>& members, std::int64_t t) const {
    double sp[2] = {0, 0}, spp[2] = {0, 0}, sv[2] = {0, 0}, svv[2] = {0, 0};
    for (const Entity* e : members) {
        Filter f = predict(*e, t);
        const Axis* ax[2] = {&f.east, &f.north};
        for (int k = 0; k < 2; ++k) {
            spp[k] += 1 / ax[k]->pp;
            sp[k] += ax[k]->p / ax[k]->pp;
            svv[k] += 1 / ax[k]->vv;
            sv[k] += ax[k]->v / ax[k]->vv;
        }
    }
    Filter out;
    Axis* ax[2] = {&out.east, &out.north};
    for (int k = 0; k < 2; ++k) {
        ax[k]->pp = 1 / spp[k];
        ax[k]->p = ax[k]->pp * sp[k];
        ax[k]->vv = 1 / svv[k];
        ax[k]->v = ax[k]->vv * sv[k];
        ax[k]->pv = 0;
    }
    return out;
}

// `leave`, then `end` when the system track is left empty.
void Engine::leave_system(Entity& e, const char* reason, Output& out) {
    int s = e.system;
    auto& members = systems_.at(s);
    members.erase(e.key);
    e.system = 0;
    Json ev = event("leave");
    ev["system"] = system_name(s);
    ev["entity"] = e.key;
    ev["reason"] = reason;
    out.events.push(ev);
    if (members.empty()) {
        systems_.erase(s);
        Json end = event("end");
        end["system"] = system_name(s);
        out.events.push(end);
    }
}

// "On each tick", steps 1 to 4 for one source S; `reported` is R in key order.
void Engine::assign_source(const std::vector<std::string>& reported, Output& out) {
    const double INF = std::numeric_limits<double>::infinity();
    const std::string& source = entities_.at(reported.front()).source;
    const std::set<std::string> in_r(reported.begin(), reported.end());

    // 1. Columns: system tracks whose members outside R are not empty and
    //    hold no entity of S; those members are the track's others.
    std::vector<int> columns;
    std::vector<std::vector<const Entity*>> others;
    for (const auto& kv : systems_) {
        std::vector<const Entity*> rest;
        bool has_source = false;
        for (const std::string& k : kv.second) {
            if (in_r.count(k)) continue;
            const Entity& e = entities_.at(k);
            if (e.source == source) has_source = true;
            rest.push_back(&e);
        }
        if (rest.empty() || has_source) continue;
        columns.push_back(kv.first);
        others.push_back(std::move(rest));
    }

    // 2. Entries: row i is reported[i]; column j < m is columns[j], column
    //    m + i is row i's own `alone`.
    const size_t n = reported.size(), m = columns.size();
    std::vector<std::vector<double>> cost(n, std::vector<double>(m + n, INF));
    for (size_t i = 0; i < n; ++i) {
        const Entity& a = entities_.at(reported[i]);
        for (size_t j = 0; j < m; ++j) {
            bool ok = true;
            for (const Entity* b : others[j]) {
                if (!run_stage("gate", pack_.gate, a, *b, predict(*b, a.last_time_ms), out)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;
            Filter f = fuse(others[j], a.last_time_ms);
            double de = a.filter.east.p - f.east.p, dn = a.filter.north.p - f.north.p;
            double d2 = de * de / (a.filter.east.pp + f.east.pp) + dn * dn / (a.filter.north.pp + f.north.pp);
            if (a.system == columns[j]) d2 -= pack_.keep_bonus;
            cost[i][j] = d2;
        }
        double alone = pack_.new_cost;
        if (a.system && systems_.at(a.system).size() == 1) alone -= pack_.keep_bonus;
        cost[i][m + i] = alone;
    }
    auto record = [&](const std::string& a, const std::string& b, const char* test, double value) {
        Json rec = Json::make_object();
        rec["stage"] = "assign";
        rec["a"] = a;
        rec["b"] = b;
        rec["test"] = test;
        rec["value"] = value == INF ? Json() : Json(value);
        rec["limit"] = Json();
        rec["pass"] = value != INF;
        out.trace.push(rec);
    };
    for (size_t i = 0; i < n; ++i) {
        for (size_t j = 0; j < m; ++j) record(reported[i], system_name(columns[j]), "cost", cost[i][j]);
        record(reported[i], "alone", "cost", cost[i][m + i]);
    }

    // 3. Assignment with the least total cost.
    std::vector<int> choice = min_cost_assignment(cost);
    for (size_t i = 0; i < n; ++i) {
        size_t j = static_cast<size_t>(choice[i]);
        record(reported[i], j < m ? system_name(columns[j]) : "alone", "choice", cost[i][j]);
    }

    // 4. Apply, entities of R in key order.
    for (size_t i = 0; i < n; ++i) {
        Entity& a = entities_.at(reported[i]);
        size_t j = static_cast<size_t>(choice[i]);
        if (j < m && a.system == columns[j]) continue;
        if (j >= m && a.system && systems_.at(a.system).size() == 1) continue;
        if (a.system) leave_system(a, "assign", out);
        Json ev;
        if (j < m) {
            a.system = columns[j];
            ev = event("join");
        } else {
            a.system = next_system_++;
            ev = event("start");
        }
        systems_[a.system].insert(a.key);
        ev["system"] = system_name(a.system);
        ev["entity"] = a.key;
        out.events.push(ev);
    }
}

Output Engine::tick_assign(std::int64_t now_ms) {
    Output out;

    // Staleness, entities in key order.
    std::vector<std::string> keys;
    for (const auto& kv : entities_) keys.push_back(kv.first);
    for (const std::string& k : keys) {
        Entity& e = entities_.at(k);
        auto report_stale = e.last.find("stale_ms");
        bool stale = now_ms - e.last_time_ms > pack_.stale_ms ||
                     (is_integer(report_stale) && now_ms >= report_stale->integer);
        if (!stale) continue;
        if (e.system) leave_system(e, "stale", out);
        entities_.erase(k);
        reported_.erase(k);
        Json ev = event("drop");
        ev["entity"] = k;
        out.events.push(ev);
    }

    // Assignment, sources in key order, each with its reported entities in key order.
    std::map<std::string, std::vector<std::string>> by_source;
    for (const std::string& k : reported_) by_source[entities_.at(k).source].push_back(k);
    reported_.clear();
    for (const auto& kv : by_source) assign_source(kv.second, out);

    // Output, system tracks in creation order.
    for (const auto& kv : systems_) {
        std::vector<const Entity*> members;
        const Entity* latest_hae = nullptr;
        Json names = Json::make_array();
        for (const std::string& k : kv.second) {
            const Entity& e = entities_.at(k);
            members.push_back(&e);
            names.push(k);
            if (number_at(e.last, "hae") && (!latest_hae || e.last_time_ms > latest_hae->last_time_ms))
                latest_hae = &e;
        }
        Filter f = fuse(members, now_ms);
        auto pos = to_degrees(f.east.p, f.north.p);
        double ve = f.east.v, vn = f.north.v;
        double course = deg(std::atan2(ve, vn));
        if (course < 0) course += 360;
        if (course >= 360) course -= 360;

        Json ev = event("system");
        ev["system"] = system_name(kv.first);
        ev["members"] = names;
        ev["lat"] = pos.first;
        ev["lon"] = pos.second;
        ev["course"] = course;
        ev["speed_ms"] = std::hypot(ve, vn);
        if (latest_hae) ev["hae"] = *number_at(latest_hae->last, "hae");
        out.events.push(ev);
    }
    return out;
}

Json Engine::snapshot_assign() const {
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
        j["system"] = e.system ? Json(system_name(e.system)) : Json();
        Json f = Json::make_object();
        f["east"] = axis_json(e.filter.east);
        f["north"] = axis_json(e.filter.north);
        j["filter"] = f;
        entities[kv.first] = j;
    }
    s["entities"] = entities;
    Json systems = Json::make_object();
    for (const auto& kv : systems_) {
        Json members = Json::make_array();
        for (const auto& m : kv.second) members.push(m);
        systems[system_name(kv.first)] = members;
    }
    s["systems"] = systems;
    s["next_system"] = next_system_;
    Json reported = Json::make_array();
    for (const auto& k : reported_) reported.push(k);   // std::set: key order
    s["reported"] = reported;
    return s;
}

} // namespace corr
