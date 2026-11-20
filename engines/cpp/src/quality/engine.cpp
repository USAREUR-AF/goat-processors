// spec/quality.md, version 0.2: ingest, tick, snapshot. Each block names the
// section it implements.

#include "quality/engine.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>

#include "model/report.hpp"
#include "quality/common.hpp"
#include "snapshot/snapshot.hpp"

namespace corr::quality {

using namespace detail;


Engine::Engine(Pack pack) : pack_(std::move(pack)), rule_states_(pack_.rules.size()) {}

// ---- Ingest (spec "Ingest", with "Reports", "Order", "Frame and filter", "Samples")

Output Engine::ingest(const Json& r) {
    Output out;

    // "Reports": required keys, in the order of the table.
    const std::pair<const char*, char> required[] = {
        {"track.source_id", 's'}, {"uid", 's'}, {"time_ms", 'i'}, {"lat", 'n'}, {"lon", 'n'}};
    for (const auto& [key, type] : required) {
        const Json* v = r.find(key);
        bool ok = type == 's' ? v && v->is_string()
                : type == 'i' ? v && v->is_number() && v->is_int
                              : v && v->is_number();
        if (!ok) {
            Json ev = event("reject");
            ev["reason"] = std::string("missing:") + key;
            out.events.push(ev);
            return out;
        }
    }
    const std::string source = r.find("track.source_id")->string;
    const std::string key = source + "/" + r.find("uid")->string;
    const std::int64_t t = r.find("time_ms")->integer;
    const double lat = r.find("lat")->number, lon = r.find("lon")->number;

    // Optional keys and the presence flags of "Samples".
    const std::optional<double> ce_valid = ce_at(r);
    const std::optional<double> course = number_at(r, "course");
    const std::optional<double> speed = number_at(r, "speed_ms");
    const std::optional<double> hae = number_at(r, "hae");
    const std::optional<std::int64_t> received = integer_at(r, "received_ms");
    const double ce = ce_valid.value_or(pack_.filter.default_ce_m);
    std::optional<Point> vel;
    if (course && speed) vel = Point{*speed * std::sin(rad(*course)), *speed * std::cos(rad(*course))};

    // "Frame and filter": the reference is the first accepted report, of any order.
    if (!ref_) ref_ = std::make_pair(lat, lon);
    const Point z = to_plane(ref_->first, ref_->second, lat, lon);

    // "Order".
    auto it = entities_.find(key);
    const bool exists = it != entities_.end();
    const std::int64_t last = exists ? it->second.last : 0;
    const char* order = !exists ? "first" : t > last ? "advance" : t == last ? "duplicate" : "out-of-order";
    const bool moves = !exists || t > last;    // first or advance

    Record rec;
    rec.wt = moves ? t : last;
    rec.time_ms = t;
    rec.order = order;
    rec.ce = ce_valid.has_value();
    rec.vel = course && speed;
    rec.hae = hae.has_value();

    out.trace.push(sample_trace(key, "order", order,
                                list({Json(static_cast<long long>(t)),
                                      exists ? Json(static_cast<long long>(last)) : Json()})));

    // "Input clock", built from the entities as they are before this report.
    const std::optional<Json> clock = input_clock(source);
    const std::optional<std::int64_t> latest = source_latest(source);

    // "Samples", in the order interval, latency, lateness, time_error,
    // time_state, source_order, nis, speed_err.
    const bool advance = exists && t > last;
    if (advance) {
        rec.interval = t - last;
        out.trace.push(sample_trace(key, "interval", static_cast<long long>(*rec.interval),
                                    list({Json(static_cast<long long>(t)), Json(static_cast<long long>(last))})));
    }
    if (received) {
        rec.latency = *received - t;
        out.trace.push(sample_trace(key, "latency", static_cast<long long>(*rec.latency),
                                    list({Json(static_cast<long long>(*received)), Json(static_cast<long long>(t))})));
    }
    if (clock) {
        // lateness = clock - t: an integer when the clock is one, else a binary64.
        rec.lateness = clock->is_int ? Json(static_cast<long long>(clock->integer - t))
                                     : Json(clock->number - static_cast<double>(t));
        out.trace.push(sample_trace(key, "lateness", rec.lateness, list({*clock, Json(static_cast<long long>(t))})));
    }
    // "Reports", "Time quality": steps 1 and 2 as correlate.md; step 3, unstated, takes no sample.
    const report::TimeQuality tq = report::time_quality(r, source, pack_.time_default);
    rec.time_error = tq.error_ms();
    if (rec.time_error)
        out.trace.push(sample_trace(key, "time_error", *rec.time_error,
                                    list({opt(tq.report_error_ms), opt(tq.default_error_ms)})));
    rec.time_state = tq.state();
    if (rec.time_state)
        out.trace.push(sample_trace(key, "time_state", *rec.time_state,
                                    list({opt(tq.report_state), opt(tq.default_state)})));
    // source_order: out-of-order when the source latest exists and t is below it.
    rec.source_out_of_order = latest && t < *latest;
    out.trace.push(sample_trace(key, "source_order", rec.source_out_of_order ? "out-of-order" : "in-order",
                                list({Json(static_cast<long long>(t)),
                                      latest ? Json(static_cast<long long>(*latest)) : Json()})));
    Filter predicted;
    if (advance) {
        // nis: the entity's filter predicted to t, against the report.
        predicted = filter_predict(it->second.filter, last, t, pack_.filter.accel_var);
        const double rr = ce * ce;
        const double de = z.east - predicted.east.p, dn = z.north - predicted.north.p;
        const double se = predicted.east.pp + rr, sn = predicted.north.pp + rr;
        rec.nis = de * de / se + dn * dn / sn;
        out.trace.push(sample_trace(key, "nis", *rec.nis, list({de, dn, se, sn})));
    }
    if (advance && speed) {
        // speed_err: speed implied by the movement since last_pos, against speed_ms.
        const double dt = static_cast<double>(t - last) / 1000;
        const Point& lp = it->second.last_pos;
        const double implied = std::hypot(z.east - lp.east, z.north - lp.north) / dt;
        rec.speed_err = std::abs(implied - *speed);
        out.trace.push(sample_trace(key, "speed_err", *rec.speed_err, list({implied, *speed})));
    }

    // Create the entity, or update its filter, last and last_pos as the order says.
    if (!exists) {
        Entity e;
        e.source = source;
        e.last = t;
        e.last_pos = z;
        e.filter = filter_first(pack_.filter, z, vel, ce);
        it = entities_.emplace(key, std::move(e)).first;
        Json ev = event("new");
        ev["entity"] = key;
        out.events.push(ev);
    } else if (advance) {
        // The filter is updated from the prediction that gave nis.
        it->second.filter = predicted;
        filter_correct(it->second.filter, pack_.filter, z, vel, ce);
        it->second.last = t;
        it->second.last_pos = z;
    }
    it->second.window.push_back(rec);

    out.events.push(pass_event(r, key, it->second.source));
    return out;
}

// ---- Tick (spec "Tick") ----------------------------------------------------

Output Engine::tick(std::int64_t now_ms) {
    Output out;

    // 1. Order.
    if (last_tick_ && now_ms < *last_tick_) {
        Json ev = event("reject");
        ev["reason"] = "tick-out-of-order";
        out.events.push(ev);
        return out;
    }
    last_tick_ = now_ms;

    std::set<std::string> sources_at_start;
    for (const auto& [key, e] : entities_) sources_at_start.insert(e.source);

    // 2. Forget entities, key order.
    for (auto it = entities_.begin(); it != entities_.end();) {
        if (now_ms - it->second.last > pack_.forget_ms) {
            forget_subject(Scope::Entity, it->first, out);
            it = entities_.erase(it);
        } else {
            ++it;
        }
    }

    // 3. Forget sources that had entities at the start of the tick and have none now.
    std::set<std::string> sources_now;
    for (const auto& [key, e] : entities_) sources_now.insert(e.source);
    for (const std::string& s : sources_at_start)
        if (!sources_now.count(s)) forget_subject(Scope::Source, s, out);

    // 4. Window: drop records with wt <= now_ms - window_ms.
    const std::int64_t cutoff = now_ms - pack_.window_ms;
    for (auto& [key, e] : entities_)
        e.window.erase(std::remove_if(e.window.begin(), e.window.end(),
                                      [&](const Record& r) { return r.wt <= cutoff; }),
                       e.window.end());

    // 5. Entities, key order: measures, quality event, entity rules.
    std::map<std::string, Json> measures;
    for (const auto& [key, e] : entities_) {
        Json m = entity_measures(e, now_ms);
        Json ev = event("quality");
        ev["scope"] = "entity";
        ev["subject"] = key;
        ev["measures"] = m;
        out.events.push(ev);
        evaluate_rules(Scope::Entity, key, m, out);
        measures.emplace(key, std::move(m));
    }

    // 6. Sources, key order: measures over their entities (in key order), quality event, source rules.
    for (const std::string& s : sources_now) {
        std::vector<const Json*> ems;
        for (const auto& [key, e] : entities_)
            if (e.source == s) ems.push_back(&measures.at(key));
        Json m = source_measures(ems);
        Json ev = event("quality");
        ev["scope"] = "source";
        ev["subject"] = s;
        ev["measures"] = m;
        out.events.push(ev);
        evaluate_rules(Scope::Source, s, m, out);
    }
    return out;
}

// ---- Snapshot (spec "Snapshot") --------------------------------------------

Json Engine::snapshot() const {
    Json snap = Json::make_object();
    snap["ref"] = ref_ ? list({ref_->first, ref_->second}) : Json();
    snap["last_tick"] = last_tick_ ? Json(static_cast<long long>(*last_tick_)) : Json();

    Json entities = Json::make_object();
    for (const auto& [key, e] : entities_) {
        Json j = Json::make_object();
        j["source"] = e.source;
        j["last_time_ms"] = static_cast<long long>(e.last);
        j["last_pos"] = list({e.last_pos.east, e.last_pos.north});
        j["filter"] = snapshot::filter_json(e.filter);
        Json w = Json::make_array();
        for (const Record& r : e.window) w.push(record_json(r));
        j["window"] = w;
        entities[key] = j;
    }
    snap["entities"] = entities;

    Json rules = Json::make_object();
    for (size_t i = 0; i < pack_.rules.size(); ++i) {
        Json states = Json::make_object();
        for (const auto& [subject, st] : rule_states_[i]) {
            Json s = Json::make_object();
            s["count"] = static_cast<long long>(st.count);
            s["active"] = st.active;
            states[subject] = s;
        }
        rules[pack_.rules[i].name] = states;
    }
    snap["rules"] = rules;
    return snap;
}

} // namespace corr::quality
