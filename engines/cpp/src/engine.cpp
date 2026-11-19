#include "engine.hpp"

#include "common.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

namespace corr {

namespace {

using namespace detail;

// Spec "Reports": a `ce` of 0 or below is absent.
std::optional<double> ce_at(const Json& r) {
    auto ce = number_at(r, "ce");
    if (ce && *ce <= 0) return std::nullopt;
    return ce;
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

// Spec "Track estimate", step 2. Returns the innovation's likelihood term
// y*y/s + ln(s) (spec "Two-model filter", step 3).
double axis_position_update(Axis& a, double z, double r) {
    const Axis b = a;
    double s = b.pp + r, k1 = b.pp / s, k2 = b.pv / s, y = z - b.p;
    a.p = b.p + k1 * y;
    a.v = b.v + k2 * y;
    a.pp = (1 - k1) * b.pp;
    a.pv = (1 - k1) * b.pv;
    a.vv = b.vv - k2 * b.pv;
    return y * y / s + std::log(s);
}

// Spec "Track estimate", step 3. Returns the likelihood term, as step 2.
double axis_velocity_update(Axis& a, double z, double r) {
    const Axis b = a;
    double s = b.vv + r, k1 = b.pv / s, k2 = b.vv / s, y = z - b.v;
    a.p = b.p + k1 * y;
    a.v = b.v + k2 * y;
    a.pp = b.pp - k1 * b.pv;
    a.pv = (1 - k2) * b.pv;
    a.vv = (1 - k2) * b.vv;
    return y * y / s + std::log(s);
}

// Spec "Two-model filter", step 1: blend(w1, w2) of one axis.
Axis blend(double w1, double w2, const Axis& m1, const Axis& m2) {
    Axis o;
    o.p = w1 * m1.p + w2 * m2.p;
    o.v = w1 * m1.v + w2 * m2.v;
    double d1 = m1.p - o.p, e1 = m1.v - o.v, d2 = m2.p - o.p, e2 = m2.v - o.v;
    o.pp = w1 * (m1.pp + d1 * d1) + w2 * (m2.pp + d2 * d2);
    o.pv = w1 * (m1.pv + d1 * e1) + w2 * (m2.pv + d2 * e2);
    o.vv = w1 * (m1.vv + e1 * e1) + w2 * (m2.vv + e2 * e2);
    return o;
}

Filter blend(double w1, double w2, const Filter& m1, const Filter& m2) {
    return {blend(w1, w2, m1.east, m2.east), blend(w1, w2, m1.north, m2.north)};
}

// Spec "Track estimate", steps 1 to 3 on one filter, with acceleration
// variance q. Returns g, the likelihood terms added left to right from 0 in
// the order east position, north position, east velocity, north velocity.
double kalman_step(Filter& f, double dt, double q, double z_east, double z_north,
                   const double* vel_east, const double* vel_north, double r_pos, double r_vel) {
    axis_predict(f.east, dt, q);
    axis_predict(f.north, dt, q);
    double term[4] = {0, 0, 0, 0};
    term[0] = axis_position_update(f.east, z_east, r_pos);
    term[1] = axis_position_update(f.north, z_north, r_pos);
    if (vel_east) {
        term[2] = axis_velocity_update(f.east, *vel_east, r_vel);
        term[3] = axis_velocity_update(f.north, *vel_north, r_vel);
    }
    double g = 0;
    g = g + term[0];
    g = g + term[1];
    if (vel_east) {
        g = g + term[2];
        g = g + term[3];
    }
    return g;
}

Json filter_record(const std::string& entity, const char* test, const char* model, double value) {
    Json rec = Json::make_object();
    rec["stage"] = "filter";
    rec["a"] = entity;
    rec["b"] = model;
    rec["test"] = test;
    rec["value"] = value;
    rec["limit"] = Json();
    rec["pass"] = true;
    return rec;
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
    // Spec "Two-model filter", First report: both models are this filter,
    // with the long-run share of each model.
    if (pack_.manoeuvre) {
        double a = pack_.manoeuvre->p_enter, b = pack_.manoeuvre->p_leave, s = a + b;
        e.models[0] = e.models[1] = e.filter;
        e.mu[0] = b / s;
        e.mu[1] = a / s;
    }
}

void Engine::filter_update(Entity& e, const Point& z, const std::optional<Point>& vel, double ce, double dt,
                           Output& out) const {
    const auto& f = pack_.filter;
    const double r_pos = ce * ce, r_vel = f.vel_sigma_ms * f.vel_sigma_ms;
    const double* ve = vel ? &vel->east : nullptr;
    const double* vn = vel ? &vel->north : nullptr;
    if (!pack_.manoeuvre) {
        kalman_step(e.filter, dt, f.accel_var, z.east, z.north, ve, vn, r_pos, r_vel);
        return;
    }

    // Spec "Two-model filter", Later reports.
    const double a = pack_.manoeuvre->p_enter, b = pack_.manoeuvre->p_leave;
    const double q[2] = {f.accel_var, pack_.manoeuvre->accel_var};

    // Switching over dt seconds: t[i][j] is model i -> model j.
    double s = a + b;
    double l = std::pow(1 - s, dt);
    double t12 = a / s * (1 - l), t21 = b / s * (1 - l);
    double t[2][2] = {{1 - t12, t12}, {t21, 1 - t21}};
    const double mu1 = e.mu[0], mu2 = e.mu[1];

    // 1. Mixing, both mixed states from the model states before mixing.
    double c[2];
    Filter mixed[2];
    for (int j = 0; j < 2; ++j) {
        c[j] = t[0][j] * mu1 + t[1][j] * mu2;
        if (c[j] == 0) {
            mixed[j] = e.models[j];
        } else {
            double w1 = t[0][j] * mu1 / c[j], w2 = t[1][j] * mu2 / c[j];
            mixed[j] = blend(w1, w2, e.models[0], e.models[1]);
        }
    }

    // 2. Predict and update, and 3. likelihood lambda = -0.5 * g.
    double lambda[2];
    for (int j = 0; j < 2; ++j) {
        e.models[j] = mixed[j];
        double g = kalman_step(e.models[j], dt, q[j], z.east, z.north, ve, vn, r_pos, r_vel);
        lambda[j] = -0.5 * g;
    }

    // 4. Mode probabilities, relative to the larger lambda of the models with c above 0.
    bool have_m = false;
    double m = 0;
    for (int j = 0; j < 2; ++j)
        if (c[j] > 0 && (!have_m || lambda[j] > m)) { m = lambda[j]; have_m = true; }
    double ev[2];
    for (int j = 0; j < 2; ++j) ev[j] = c[j] > 0 ? c[j] * std::exp(lambda[j] - m) : 0.0;
    double sum = ev[0] + ev[1];
    e.mu[0] = ev[0] / sum;
    e.mu[1] = ev[1] / sum;

    // 5. Combination.
    e.filter = blend(e.mu[0], e.mu[1], e.models[0], e.models[1]);

    // Trace: likelihoods, then modes.
    out.trace.push(filter_record(e.key, "likelihood", "quiet", lambda[0]));
    out.trace.push(filter_record(e.key, "likelihood", "manoeuvre", lambda[1]));
    out.trace.push(filter_record(e.key, "mode", "quiet", e.mu[0]));
    out.trace.push(filter_record(e.key, "mode", "manoeuvre", e.mu[1]));
}

// Spec "Track estimate", Prediction: step 1 on a copy. With two models, each
// is predicted with its own q and the two are blended with the current mu.
Filter Engine::predict(const Entity& e, std::int64_t t) const {
    double dt = static_cast<double>(t - e.last_time_ms) / 1000;
    auto step1 = [dt](Filter f, double q) {
        axis_predict(f.east, dt, q);
        axis_predict(f.north, dt, q);
        return f;
    };
    if (!pack_.manoeuvre) return step1(e.filter, pack_.filter.accel_var);
    return blend(e.mu[0], e.mu[1], step1(e.models[0], pack_.filter.accel_var),
                 step1(e.models[1], pack_.manoeuvre->accel_var));
}

// Snapshot: `filter`, and with `manoeuvre` also `models` and `mode`.
void Engine::filter_json(const Entity& e, Json& into) const {
    into["filter"] = filter_json_of(e.filter);
    if (!pack_.manoeuvre) return;
    Json models = Json::make_object();
    models["quiet"] = filter_json_of(e.models[0]);
    models["manoeuvre"] = filter_json_of(e.models[1]);
    into["models"] = models;
    Json mode = Json::make_array();
    mode.push(e.mu[0]);
    mode.push(e.mu[1]);
    into["mode"] = mode;
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
// the first failure. Returns true when every test ran and passed. `extra`,
// when given, is an object whose keys are added to each record.
bool Engine::run_stage(const char* stage, const std::vector<TestSpec>& tests, const Entity& a,
                       const Entity& b, const Filter& bp, Output& out, const Json* extra) const {
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
        if (extra)
            for (const auto& kv : extra->object) rec[kv.first] = kv.second;
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
    std::optional<Point> vel;
    auto course = number_at(r, "course"), speed = number_at(r, "speed_ms");
    if (course && speed) vel = Point{*speed * std::sin(rad(*course)), *speed * std::cos(rad(*course))};
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
        filter_update(it->second, z, vel, ce, dt, out);
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

// Spec "On each tick", 1: the pack's stale_ms, or the report's own stale_ms.
bool Engine::is_stale(const Entity& e, std::int64_t now_ms) const {
    auto report_stale = e.last.find("stale_ms");
    return now_ms - e.last_time_ms > pack_.stale_ms ||
           (is_integer(report_stale) && now_ms >= report_stale->integer);
}

Output Engine::tick(std::int64_t now_ms) {
    if (pack_.method_assign) return tick_assign(now_ms);
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

} // namespace corr
