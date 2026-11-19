#include "engine.hpp"

#include <algorithm>
#include <cmath>
#include <vector>

namespace corr {

namespace {

// Spec "Frame".
constexpr double R = 6371008.8;
constexpr double PI = 3.141592653589793;
double rad(double x) { return x * PI / 180; }
double deg(double x) { return x * 180 / PI; }
double wrap180(double lon) {
    while (lon > 180) lon -= 360;
    while (lon <= -180) lon += 360;
    return lon;
}

// Report values; a null value counts as absent.
std::optional<double> number_at(const Json& r, const std::string& key) {
    const Json* v = r.find(key);
    if (!v || !v->is_number()) return std::nullopt;
    return v->number;
}

std::int64_t integer_of(const Json& v) {
    return v.is_int ? v.integer : static_cast<std::int64_t>(v.number);
}

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

// Spec "Track estimate", step 1.
void axis_predict(Axis& a, double dt, double q) {
    const Axis b = a;
    a.p = b.p + b.v * dt;
    a.pp = b.pp + 2 * dt * b.pv + dt * dt * b.vv + q * (dt * dt * dt * dt) / 4;
    a.pv = b.pv + dt * b.vv + q * (dt * dt * dt) / 2;
    a.vv = b.vv + q * (dt * dt);
}

// Spec "Track estimate", step 2.
void axis_position_update(Axis& a, double z, double r) {
    const Axis b = a;
    double s = b.pp + r, k1 = b.pp / s, k2 = b.pv / s, y = z - b.p;
    a.p = b.p + k1 * y;
    a.v = b.v + k2 * y;
    a.pp = (1 - k1) * b.pp;
    a.pv = (1 - k1) * b.pv;
    a.vv = b.vv - k2 * b.pv;
}

// Spec "Track estimate", step 3.
void axis_velocity_update(Axis& a, double z, double r) {
    const Axis b = a;
    double s = b.vv + r, k1 = b.pv / s, k2 = b.vv / s, y = z - b.v;
    a.p = b.p + k1 * y;
    a.v = b.v + k2 * y;
    a.pp = b.pp - k1 * b.pv;
    a.pv = (1 - k2) * b.pv;
    a.vv = (1 - k2) * b.vv;
}

Json axis_json(const Axis& a) {
    Json j = Json::make_array();
    for (double x : {a.p, a.v, a.pp, a.pv, a.vv}) j.push(x);
    return j;
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
    const double lat0 = ref_->first, lon0 = ref_->second;
    double dlon = wrap180(lon - lon0);
    return {R * rad(dlon) * std::cos(rad(lat0)), R * rad(lat - lat0)};
}

std::pair<double, double> Engine::to_degrees(double east, double north) const {
    const double lat0 = ref_->first, lon0 = ref_->second;
    double lat = lat0 + deg(north / R);
    double lon = lon0 + deg(east / (R * std::cos(rad(lat0))));
    return {lat, wrap180(lon)};
}

// ---- Track estimate --------------------------------------------------------

void Engine::filter_first(Entity& e, const Point& z, const std::optional<Point>& vel, double ce) const {
    const auto& f = pack_.filter;
    double vv = vel ? f.vel_sigma_ms * f.vel_sigma_ms : f.unknown_vel_ms * f.unknown_vel_ms;
    e.filter.east = {z.east, vel ? vel->east : 0.0, ce * ce, 0.0, vv};
    e.filter.north = {z.north, vel ? vel->north : 0.0, ce * ce, 0.0, vv};
}

void Engine::filter_update(Entity& e, const Point& z, const std::optional<Point>& vel, double ce,
                           double dt) const {
    const auto& f = pack_.filter;
    for (int axis = 0; axis < 2; ++axis) {
        Axis& a = axis == 0 ? e.filter.east : e.filter.north;
        axis_predict(a, dt, f.accel_var);
        axis_position_update(a, axis == 0 ? z.east : z.north, ce * ce);
        if (vel) axis_velocity_update(a, axis == 0 ? vel->east : vel->north, f.vel_sigma_ms * f.vel_sigma_ms);
    }
}

// Spec "Track estimate", Prediction: step 1 on a copy.
Filter Engine::predict(const Entity& e, std::int64_t t) const {
    Filter f = e.filter;
    double dt = static_cast<double>(t - e.last_time_ms) / 1000;
    axis_predict(f.east, dt, pack_.filter.accel_var);
    axis_predict(f.north, dt, pack_.filter.accel_var);
    return f;
}

// ---- Tests -----------------------------------------------------------------

double Engine::ce_of(const Entity& e) const {
    return number_at(e.last, "ce").value_or(pack_.filter.default_ce_m);
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
        entities_.at(last).group = 0;
        Json d = event("dissolve");
        d["group"] = group_name(g);
        d["entity"] = last;
        out.events.push(d);
        groups_.erase(g);
    }
}

// Spec "Association": A is in a group G: hold.
void Engine::hold(Entity& a, Output& out) {
    bool any = false;
    for (const std::string& bk : groups_.at(a.group)) {
        if (bk == a.key) continue;
        const Entity& b = entities_.at(bk);
        if (run_stage("hold", pack_.hold, a, b, predict(b, a.last_time_ms), out)) any = true;
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
    const std::pair<const char*, bool> required[] = {
        {"track.source_id", true}, {"uid", true}, {"time_ms", false}, {"lat", false}, {"lon", false}};
    for (const auto& req : required) {
        const Json* v = r.find(req.first);
        bool ok = v && (req.second ? v->is_string() : v->is_number());
        if (!ok) {
            Json ev = event("reject");
            ev["reason"] = std::string("missing:") + req.first;
            out.events.push(ev);
            return out;
        }
    }
    const std::string source = r.find("track.source_id")->string;
    const std::string key = source + "/" + r.find("uid")->string;
    const std::int64_t time_ms = integer_of(*r.find("time_ms"));
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
    if (course && speed) vel = Point{*speed * std::sin(rad(*course)), *speed * std::cos(rad(*course))};
    double ce = number_at(r, "ce").value_or(pack_.filter.default_ce_m);

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

    if (a.group) hold(a, out);
    else associate(a, out);
    return out;
}

Output Engine::tick(std::int64_t now_ms) {
    Output out;

    // 1. Staleness, entities in key order.
    std::vector<std::string> keys;
    for (const auto& kv : entities_) keys.push_back(kv.first);
    for (const std::string& k : keys) {
        Entity& e = entities_.at(k);
        auto report_stale = e.last.find("stale_ms");
        bool stale = now_ms - e.last_time_ms > pack_.stale_ms ||
                     (report_stale && report_stale->is_number() && now_ms >= integer_of(*report_stale));
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

} // namespace corr
