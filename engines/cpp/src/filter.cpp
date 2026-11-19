// spec/filter.md. Each section is marked where it is implemented.
#include "filter.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <utility>
#include <vector>

#include "report.hpp"

namespace corr::filter {

namespace {

// ---- Geometry --------------------------------------------------------------

constexpr double R = 6371008.8;
constexpr double PI = 3.141592653589793;
double rad(double x) { return x * PI / 180; }
double deg(double x) { return x * 180 / PI; }

// wrap(x): add or subtract 360 until x is in (-180, 180]. A value too large
// for the loop to end (only near a pole, an open point; see DISAGREEMENTS.md)
// is first reduced with the exact fmod; a non-finite value is returned as is.
double wrap(double x) {
    if (!std::isfinite(x)) return x;
    if (std::abs(x) > 1e6) x = std::fmod(x, 360.0);
    while (x > 180) x -= 360;
    while (x <= -180) x += 360;
    return x;
}

// Distance: haversine from point 1 (the report) to point 2, in the spec's order.
double distance(double lat1, double lon1, double lat2, double lon2) {
    double p1 = rad(lat1), p2 = rad(lat2), dp = rad(lat2 - lat1), dl = rad(wrap(lon2 - lon1));  // 1
    double s1 = std::sin(dp / 2), s2 = std::sin(dl / 2);                                         // 2
    double h = s1 * s1 + ((std::cos(p1) * std::cos(p2)) * s2) * s2;                              // 3
    return (2 * R) * std::asin(std::min(1.0, std::sqrt(h)));                                      // 4
}

// Polygon: "boundary", "inside" or "outside".
const char* polygon_test(const std::vector<std::pair<double, double>>& vertices, double lat, double lon) {
    const size_t n = vertices.size();
    const double lon0 = vertices[0].second;
    std::vector<double> x(n), y(n);
    for (size_t i = 0; i < n; ++i) {
        x[i] = i == 0 ? lon0 : lon0 + wrap(vertices[i].second - lon0);
        y[i] = vertices[i].first;
    }
    const double px = lon0 + wrap(lon - lon0), py = lat;

    // 1. Boundary.
    for (size_t i = 0; i < n; ++i) {
        size_t j = (i + 1) % n;
        double c = (x[j] - x[i]) * (py - y[i]) - (y[j] - y[i]) * (px - x[i]);
        if (c == 0 && std::min(x[i], x[j]) <= px && px <= std::max(x[i], x[j]) &&
            std::min(y[i], y[j]) <= py && py <= std::max(y[i], y[j]))
            return "boundary";
    }
    // 2. Crossings (even-odd).
    bool inside = false;
    for (size_t i = 0; i < n; ++i) {
        size_t j = (i + 1) % n;
        if ((y[i] > py) != (y[j] > py)) {
            double xc = (x[j] - x[i]) * (py - y[i]) / (y[j] - y[i]) + x[i];
            if (px < xc) inside = !inside;
        }
    }
    return inside ? "inside" : "outside";
}

// Reference prediction: the reference's stored position predicted to time t.
std::pair<double, double> predict(const EntityState& ref, std::int64_t t) {
    double dt = static_cast<double>(t - ref.time_ms) / 1000;                     // 1
    double dn = 0, de = 0;                                                       // 2
    if (ref.course && ref.speed_ms) {
        dn = *ref.speed_ms * std::cos(rad(*ref.course)) * dt;
        de = *ref.speed_ms * std::sin(rad(*ref.course)) * dt;
    }
    double lat_p = ref.lat + deg(dn / R);                                        // 3
    double lon_p = wrap(ref.lon + deg(de / (R * std::cos(rad(ref.lat)))));
    return {lat_p, lon_p};
}

// ---- Conditions helpers ----------------------------------------------------

Json list_json(const std::vector<std::string>& items) {
    Json j = Json::make_array();
    for (const auto& s : items) j.push(Json(s));
    return j;
}

bool in_list(const std::string& v, const std::vector<std::string>& items) {
    return std::find(items.begin(), items.end(), v) != items.end();
}

Json opt_json(const std::optional<double>& v) { return v ? Json(*v) : Json(); }
Json opt_json(const std::optional<std::int64_t>& v) { return v ? Json(static_cast<long long>(*v)) : Json(); }

// Ranges: `[min, max]`, an omitted bound null; both bounds inclusive.
Json range_limit(const Condition& c) {
    Json j = Json::make_array();
    j.push(opt_json(c.min));
    j.push(opt_json(c.max));
    return j;
}
bool in_range(double v, const Condition& c) {
    return (!c.min || *c.min <= v) && (!c.max || v <= *c.max);
}

// `key` equality between a report value v and a pack text t.
bool key_equal(const Json& v, const std::string& t) {
    switch (v.kind) {
        case Json::Kind::String: return v.string == t;
        case Json::Kind::Number: return is_pack_number(t) && std::strtod(t.c_str(), nullptr) == v.number;
        case Json::Kind::Bool: return t == (v.boolean ? "true" : "false");
        default: return false;  // arrays and objects are never equal
    }
}

Json event(const char* ev, const std::string& entity) {
    Json e = Json::make_object();
    e["ev"] = ev;
    e["entity"] = entity;
    return e;
}

} // namespace

Engine::Engine(Pack pack) : pack_(std::move(pack)) {}

// ---- Conditions ------------------------------------------------------------
//
// One row of the Conditions table per branch: the value, the limit, and the
// result (true, false or unknown) before negation. `own` is the state of the
// report's entity before this report, or null.

Engine::Evaluation Engine::evaluate(const Condition& c, const Json& r, const EntityState* own) const {
    using report::present;
    using report::type_element;
    auto truth = [](bool b) { return b ? Result::True : Result::False; };
    const std::int64_t time_ms = r.find("time_ms")->integer;
    const double lat = r.find("lat")->number, lon = r.find("lon")->number;
    Evaluation e;
    const std::string& t = c.test;

    if (t == "circle") {
        double d = distance(lat, lon, c.lat, c.lon);
        e.value = d;
        e.limit = c.radius_m;
        e.result = truth(d <= c.radius_m);
    } else if (t == "polygon") {
        const char* where = polygon_test(c.vertices, lat, lon);
        e.value = where;
        e.result = truth(std::string(where) != "outside");
    } else if (t == "near") {
        e.limit = c.radius_m;
        auto it = entities_.find(c.reference);
        const EntityState* ref = it == entities_.end() ? nullptr : &it->second;
        // Stale: the age above max_age_ms, or the reference's own stale_ms reached.
        bool stale = ref && (std::llabs(time_ms - ref->time_ms) > c.max_age_ms ||
                             (ref->stale_ms && time_ms >= *ref->stale_ms));
        if (!ref || stale) {
            e.result = Result::Unknown;  // value stays null
        } else {
            auto [lat_p, lon_p] = predict(*ref, time_ms);
            double d = distance(lat, lon, lat_p, lon_p);
            e.value = d;
            e.result = truth(d <= c.radius_m);
        }
    } else if (t == "env" || t == "affiliation") {
        e.limit = list_json(c.in);
        std::optional<std::string> v;
        if (t == "env") {
            v = type_element(r, 2);  // the third element of `type`
        } else if (type_element(r, 0) == std::optional<std::string>("a")) {
            v = type_element(r, 1);  // the second element, when the first is exactly `a`
        }
        if (!v) {
            e.result = Result::Unknown;
        } else {
            e.value = *v;
            e.result = truth(in_list(*v, c.in));
        }
    } else if (t == "source" || t == "uid") {
        const std::string& v = r.find(t == "source" ? "track.source_id" : "uid")->string;
        e.value = v;
        e.limit = list_json(c.in);
        e.result = truth(in_list(v, c.in));
    } else if (t == "key") {
        const Json* v = present(r, c.name);
        if (v) e.value = *v;
        switch (c.key_form) {
            case Condition::KeyForm::Eq:
                e.limit = c.eq;
                e.result = !v ? Result::Unknown : truth(key_equal(*v, c.eq));
                break;
            case Condition::KeyForm::In: {
                e.limit = list_json(c.in);
                bool any = false;
                if (v)
                    for (const auto& item : c.in) any = any || key_equal(*v, item);
                e.result = !v ? Result::Unknown : truth(any);
                break;
            }
            case Condition::KeyForm::Range:
                e.limit = range_limit(c);
                e.result = !v || !v->is_number() ? Result::Unknown : truth(in_range(v->number, c));
                break;
        }
    } else if (t == "has") {
        bool has = present(r, c.name) != nullptr;
        e.value = has;
        e.result = truth(has);
    } else if (t == "speed" || t == "altitude") {
        const Json* v = present(r, t == "speed" ? "speed_ms" : "hae");
        e.limit = range_limit(c);
        if (!v) {
            e.result = Result::Unknown;
        } else {
            e.value = *v;
            e.result = truth(in_range(v->number, c));
        }
    } else if (t == "interval") {
        e.limit = static_cast<long long>(c.min_ms);
        if (own && own->kept_ms) {
            std::int64_t since = time_ms - *own->kept_ms;
            e.value = static_cast<long long>(since);
            e.result = truth(since < c.min_ms);
        }  // no kept report: value null, false
    } else if (t == "order") {
        e.value = static_cast<long long>(time_ms);
        if (own && own->kept_ms) {
            e.limit = static_cast<long long>(*own->kept_ms);
            e.result = truth(time_ms < *own->kept_ms);
        }  // no kept report: limit null, false
    }
    return e;
}

// ---- Rules -----------------------------------------------------------------

Output Engine::ingest(const Json& r) {
    Output out;

    // Reports: a rejected report gives no trace and changes no state.
    if (auto missing = report::missing_required(r)) {
        Json ev = Json::make_object();
        ev["ev"] = "reject";
        ev["reason"] = "missing:" + *missing;
        out.events.push(ev);
        return out;
    }
    const std::string key = r.find("track.source_id")->string + "/" + r.find("uid")->string;
    const std::int64_t time_ms = r.find("time_ms")->integer;
    auto found = entities_.find(key);
    const EntityState* own = found == entities_.end() ? nullptr : &found->second;

    // 1. Rules in pack order; conditions in pack order, up to the first that
    //    does not pass. 2. The first rule that matches decides.
    bool keep = pack_.default_keep;
    std::string decided_by = "default";
    for (const Rule& rule : pack_.rules) {
        bool matches = true;
        for (const Condition& c : rule.when) {
            Evaluation e = evaluate(c, r, own);
            // `not` swaps true and false; unknown stays unknown and never passes.
            Result result = e.result;
            if (c.negated && result != Result::Unknown)
                result = result == Result::True ? Result::False : Result::True;
            bool pass = result == Result::True;

            Json rec = Json::make_object();
            rec["stage"] = "rule";
            rec["rule"] = rule.name;
            rec["entity"] = key;
            rec["test"] = c.test;
            rec["negated"] = c.negated;
            rec["value"] = e.value;
            rec["limit"] = e.limit;
            rec["pass"] = pass;
            if (e.result == Result::Unknown) rec["unknown"] = true;
            out.trace.push(rec);

            if (!pass) {
                matches = false;
                break;
            }
        }
        if (matches) {
            keep = rule.keep;
            decided_by = rule.name;
            break;
        }
    }

    // 3. Event.
    Json ev = event(keep ? "keep" : "drop", key);
    ev["rule"] = decided_by;
    out.events.push(ev);

    // 4. State, after the decision.
    auto take_report = [&](EntityState& s) {
        s.time_ms = time_ms;
        s.lat = r.find("lat")->number;
        s.lon = r.find("lon")->number;
        s.course = report::number_at(r, "course");
        s.speed_ms = report::number_at(r, "speed_ms");
        s.stale_ms = report::stale_ms_at(r);
    };
    if (found == entities_.end()) {
        found = entities_.emplace(key, EntityState{}).first;  // kept_ms null
        take_report(found->second);
    } else if (time_ms >= found->second.time_ms) {
        take_report(found->second);  // an older report replaces none of them
    }
    EntityState& s = found->second;
    if (keep && (!s.kept_ms || *s.kept_ms < time_ms)) s.kept_ms = time_ms;
    return out;
}

// ---- Tick ------------------------------------------------------------------

Output Engine::tick(std::int64_t now_ms) {
    Output out;
    for (auto it = entities_.begin(); it != entities_.end();) {  // key order
        std::int64_t age = now_ms - it->second.time_ms;
        bool forget = age > pack_.forget_ms;

        Json rec = Json::make_object();
        rec["stage"] = "forget";
        rec["entity"] = it->first;
        rec["test"] = "age";
        rec["value"] = static_cast<long long>(age);
        rec["limit"] = static_cast<long long>(pack_.forget_ms);
        rec["pass"] = forget;
        out.trace.push(rec);

        if (forget) {
            out.events.push(event("forget", it->first));
            it = entities_.erase(it);
        } else {
            ++it;
        }
    }
    return out;
}

// ---- Snapshot --------------------------------------------------------------

Json Engine::snapshot() const {
    Json entities = Json::make_object();
    for (const auto& [key, s] : entities_) {
        Json e = Json::make_object();
        e["time_ms"] = static_cast<long long>(s.time_ms);
        e["lat"] = s.lat;
        e["lon"] = s.lon;
        e["course"] = opt_json(s.course);
        e["speed_ms"] = opt_json(s.speed_ms);
        e["stale_ms"] = opt_json(s.stale_ms);
        e["kept_ms"] = opt_json(s.kept_ms);
        entities[key] = e;
    }
    Json out = Json::make_object();
    out["entities"] = entities;
    return out;
}

} // namespace corr::filter
