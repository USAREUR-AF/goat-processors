// filter.md "Rules", "Tick", "Events", "Trace" and "Snapshot".
#include "filter/engine.hpp"

#include "filter/conditions.hpp"
#include "model/report.hpp"
#include "trace/trace.hpp"

namespace corr::filter {

namespace {

Json event(const char* ev, const std::string& entity) {
    Json e = Json::make_object();
    e["ev"] = ev;
    e["entity"] = entity;
    return e;
}

Json opt_json(const std::optional<double>& v) { return v ? Json(*v) : Json(); }
Json opt_json(const std::optional<std::int64_t>& v) { return v ? Json(static_cast<long long>(*v)) : Json(); }

} // namespace

Engine::Engine(Pack pack) : pack_(std::move(pack)) {}

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
            Evaluation e = evaluate(c, r, own, entities_);
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
