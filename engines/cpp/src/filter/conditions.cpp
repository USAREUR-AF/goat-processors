// filter.md "Conditions".
#include "filter/conditions.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <vector>

#include "model/report.hpp"

namespace corr::filter {

namespace {

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

} // namespace

Evaluation evaluate(const Condition& c, const Json& r, const EntityState* own,
                    const std::map<std::string, EntityState>& entities) {
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
        auto it = entities.find(c.reference);
        const EntityState* ref = it == entities.end() ? nullptr : &it->second;
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

} // namespace corr::filter
