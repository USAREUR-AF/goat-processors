// spec/quality.md, version 0.2: ingest, tick, snapshot. Each block names the
// section it implements.

#include "quality.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <set>

#include "report.hpp"

namespace corr::quality {

namespace {

Json event(const char* ev) {
    Json e = Json::make_object();
    e["ev"] = ev;
    return e;
}

// "Reports": optional keys. A null or wrong-typed value is absent; a boolean
// is never a number (the JSON reader gives booleans their own kind).
std::optional<double> number_at(const Json& r, const char* key) {
    const Json* v = r.find(key);
    if (!v || !v->is_number()) return std::nullopt;
    return v->number;
}

std::optional<std::int64_t> integer_at(const Json& r, const char* key) {
    const Json* v = r.find(key);
    if (!v || !v->is_number() || !v->is_int) return std::nullopt;
    return v->integer;
}

// "Reports": a `ce` of 0 or below is absent.
std::optional<double> ce_at(const Json& r) {
    auto ce = number_at(r, "ce");
    if (ce && *ce <= 0) return std::nullopt;
    return ce;
}

template <typename T>
Json opt(const std::optional<T>& v) {
    return v ? Json(*v) : Json();
}

Json opt(const std::optional<std::int64_t>& v) {
    return v ? Json(static_cast<long long>(*v)) : Json();
}

Json sample_trace(const std::string& entity, const char* sample, Json value, Json inputs) {
    Json t = Json::make_object();
    t["stage"] = "sample";
    t["entity"] = entity;
    t["sample"] = sample;
    t["value"] = std::move(value);
    t["inputs"] = std::move(inputs);
    return t;
}

Json list(std::initializer_list<Json> items) {
    Json a = Json::make_array();
    for (const auto& x : items) a.push(x);
    return a;
}

// "Entity measures": a mean is s / n, s from 0.0 adding each sample in order.
double mean(const std::vector<double>& xs) {
    double s = 0.0;
    for (double x : xs) s += x;
    return s / static_cast<double>(xs.size());
}

// "Reports", "Time quality": the code of a time state for measures. Higher is worse.
std::int64_t time_state_code(const std::string& state) {
    if (state == "coherent") return 0;
    if (state == "drifting") return 1;
    return 2;   // free-running
}

bool condition_met(Op op, double v, double limit) {
    switch (op) {
        case Op::Lt: return v < limit;
        case Op::Le: return v <= limit;
        case Op::Gt: return v > limit;
        case Op::Ge: return v >= limit;
    }
    return false;
}

// "Rules": for op > or >= a rule clears when v < clear; for < or <=, when v > clear.
bool clears(Op op, double v, double clear) {
    return (op == Op::Gt || op == Op::Ge) ? v < clear : v > clear;
}

Json record_json(const Record& r) {
    Json j = Json::make_object();
    j["wt"] = static_cast<long long>(r.wt);
    j["time_ms"] = static_cast<long long>(r.time_ms);
    j["order"] = r.order;
    j["interval"] = opt(r.interval);
    j["latency"] = opt(r.latency);
    j["lateness"] = r.lateness;
    j["source_out_of_order"] = r.source_out_of_order;
    j["time_error"] = opt(r.time_error);
    j["time_state"] = opt(r.time_state);
    j["nis"] = opt(r.nis);
    j["speed_err"] = opt(r.speed_err);
    j["ce"] = r.ce;
    j["vel"] = r.vel;
    j["hae"] = r.hae;
    return j;
}

} // namespace

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

// ---- Input clock (spec "Input clock") ------------------------------------

std::optional<Json> Engine::input_clock(const std::string& source) const {
    // 1. Each other source's latest time: the greatest `last` among its entities.
    std::map<std::string, std::int64_t> latest_of;
    for (const auto& [key, e] : entities_) {
        if (e.source == source) continue;
        auto [it, inserted] = latest_of.emplace(e.source, e.last);
        if (!inserted) it->second = std::max(it->second, e.last);
    }
    // 3. With no other source, there is no input clock.
    if (latest_of.empty()) return std::nullopt;
    // 2. The median of those times, sorted ascending.
    std::vector<std::int64_t> times;
    for (const auto& [s, t] : latest_of) times.push_back(t);
    std::sort(times.begin(), times.end());
    const size_t n = times.size();
    if (n % 2 == 1) return Json(static_cast<long long>(times[n / 2]));
    const double a = static_cast<double>(times[n / 2 - 1]), b = static_cast<double>(times[n / 2]);
    return Json((a + b) / 2);
}

std::optional<std::int64_t> Engine::source_latest(const std::string& source) const {
    // The greatest `last` among the entities whose source is `source` (the
    // report's own entity among them when it is that source's).
    std::optional<std::int64_t> latest;
    for (const auto& [key, e] : entities_)
        if (e.source == source && (!latest || e.last > *latest)) latest = e.last;
    return latest;
}

// ---- Forwarding (spec "Rules", Actions; "Forwarding") ---------------------

// Rule i is in force for a report when it is active for the report's entity
// (scope entity) or for its source (scope source).
bool Engine::in_force(size_t i, const std::string& key, const std::string& source) const {
    const auto& states = rule_states_[i];
    auto s = states.find(pack_.rules[i].scope == Scope::Entity ? key : source);
    return s != states.end() && s->second.active;
}

Json Engine::pass_event(const Json& report, const std::string& key, const std::string& source) const {
    // The actions in force other than alert, in pack order.
    std::vector<const Rule*> acting;
    for (size_t i = 0; i < pack_.rules.size(); ++i)
        if (pack_.rules[i].action != Action::Alert && in_force(i, key, source)) acting.push_back(&pack_.rules[i]);

    Json ev = event("pass");
    ev["entity"] = key;
    Json names = Json::make_array();
    bool drop = false, downgrade = false, mark = false;
    for (const Rule* rule : acting) {
        names.push(rule->name);
        drop = drop || rule->action == Action::Drop;
        downgrade = downgrade || rule->action == Action::Downgrade;
        mark = mark || rule->action == Action::Mark;
    }
    ev["rules"] = names;
    if (drop) {
        ev["withheld"] = true;
        return ev;
    }
    ev["withheld"] = false;

    Json fwd = report;    // exactly as received, then the changes below
    if (downgrade) {
        double x = ce_at(report).value_or(pack_.filter.default_ce_m);
        for (const Rule* rule : acting)
            if (rule->action == Action::Downgrade) x = x * rule->factor;
        // A product that overflowed to infinity is forwarded as the largest finite binary64.
        if (std::isinf(x)) x = std::numeric_limits<double>::max();
        fwd["ce"] = x;
    }
    if (mark) {
        Json marks = Json::make_array();
        const Json* received = report.find("quality.marks");
        if (received && received->is_array() &&
            std::all_of(received->array.begin(), received->array.end(),
                        [](const Json& m) { return m.is_string(); }))
            marks = *received;
        for (const Rule* rule : acting) {
            if (rule->action != Action::Mark) continue;
            bool held = std::any_of(marks.array.begin(), marks.array.end(),
                                    [&](const Json& m) { return m.string == rule->name; });
            if (!held) marks.push(rule->name);
        }
        fwd["quality.marks"] = marks;
    }
    ev["report"] = fwd;
    return ev;
}

// ---- Entity measures (spec "Entity measures") -----------------------------

Json Engine::entity_measures(const Entity& e, std::int64_t now_ms) const {
    const auto k = static_cast<size_t>(pack_.min_samples);
    const std::vector<Record>& w = e.window;

    // The samples of each kind, in window order, as numbers (integer or binary64).
    std::vector<Json> intervals, latencies, lateness, nis, speed_err, time_errors, time_states;
    std::int64_t out_of_order = 0, duplicate = 0, source_out_of_order = 0;
    std::int64_t no_ce = 0, no_vel = 0, no_hae = 0, no_time = 0;
    for (const Record& r : w) {
        if (r.interval) intervals.push_back(static_cast<long long>(*r.interval));
        if (r.latency) latencies.push_back(static_cast<long long>(*r.latency));
        if (!r.lateness.is_null()) lateness.push_back(r.lateness);
        if (r.nis) nis.push_back(*r.nis);
        if (r.speed_err) speed_err.push_back(*r.speed_err);
        if (r.time_error) time_errors.push_back(*r.time_error);
        if (r.time_state) time_states.push_back(static_cast<long long>(time_state_code(*r.time_state)));
        if (r.order == "out-of-order") ++out_of_order;
        if (r.order == "duplicate") ++duplicate;
        if (r.source_out_of_order) ++source_out_of_order;
        if (!r.ce) ++no_ce;
        if (!r.vel) ++no_vel;
        if (!r.hae) ++no_hae;
        if (!r.time_state) ++no_time;
    }

    // A statistic is null when fewer than k records hold its sample.
    auto stat = [&](const std::vector<Json>& xs, auto compute) { return xs.size() < k ? Json() : compute(xs); };
    auto last_of = [](const std::vector<Json>& xs) { return xs.back(); };
    auto mean_of = [](const std::vector<Json>& xs) {
        std::vector<double> ds;
        for (const Json& x : xs) ds.push_back(x.number);
        return Json(mean(ds));
    };
    // The largest (or smallest) sample, kept as written (integer or binary64).
    auto largest = [](const std::vector<Json>& xs) {
        return *std::max_element(xs.begin(), xs.end(), [](const Json& a, const Json& b) { return a.number < b.number; });
    };
    auto smallest = [](const std::vector<Json>& xs) {
        return *std::min_element(xs.begin(), xs.end(), [](const Json& a, const Json& b) { return a.number < b.number; });
    };
    const std::int64_t reports = static_cast<std::int64_t>(w.size());
    auto fraction = [&](std::int64_t count) {
        return w.size() < k ? Json() : Json(static_cast<double>(count) / static_cast<double>(reports));
    };

    Json m = Json::make_object();
    m["reports"] = static_cast<long long>(reports);
    m["interval_last"] = stat(intervals, last_of);
    m["interval_mean"] = stat(intervals, mean_of);
    m["interval_max"] = stat(intervals, largest);
    m["age"] = static_cast<long long>(now_ms - e.last);
    m["latency_mean"] = stat(latencies, mean_of);
    m["latency_max"] = stat(latencies, largest);
    m["lateness_mean"] = stat(lateness, mean_of);
    m["lateness_max"] = stat(lateness, largest);
    m["lateness_min"] = stat(lateness, smallest);
    m["nis_mean"] = stat(nis, mean_of);
    m["speed_err_mean"] = stat(speed_err, mean_of);
    m["out_of_order"] = static_cast<long long>(out_of_order);
    m["duplicate"] = static_cast<long long>(duplicate);
    m["source_out_of_order"] = static_cast<long long>(source_out_of_order);
    m["missing_ce"] = fraction(no_ce);
    m["missing_vel"] = fraction(no_vel);
    m["missing_hae"] = fraction(no_hae);
    m["time_error_mean"] = stat(time_errors, mean_of);
    m["time_error_max"] = stat(time_errors, largest);
    m["time_state_last"] = stat(time_states, last_of);
    m["time_state_worst"] = stat(time_states, largest);
    m["missing_time"] = fraction(no_time);
    return m;
}

// ---- Source measures (spec "Source measures") -----------------------------

Json Engine::source_measures(const std::vector<const Json*>& ems) const {
    // "Present" values of one measure across the entities, in entity key order.
    auto present = [&](const char* name) {
        std::vector<const Json*> vs;
        for (const Json* em : ems) {
            const Json* v = em->find(name);
            if (v && v->is_number()) vs.push_back(v);
        }
        return vs;
    };
    auto sum = [&](const char* name) {
        long long s = 0;
        for (const Json* v : present(name)) s += v->integer;
        return Json(s);
    };
    auto mean_of = [&](const char* name) {
        auto vs = present(name);
        if (vs.empty()) return Json();
        std::vector<double> xs;
        for (const Json* v : vs) xs.push_back(v->number);
        return Json(mean(xs));
    };
    auto pick = [&](const char* name, bool largest) {
        auto vs = present(name);
        if (vs.empty()) return Json();
        const Json* best = vs[0];
        for (const Json* v : vs)
            if (largest ? v->number > best->number : v->number < best->number) best = v;
        return *best;
    };

    Json m = Json::make_object();
    for (const char* name : {"reports", "out_of_order", "duplicate", "source_out_of_order"}) m[name] = sum(name);
    for (const char* name : {"interval_last", "interval_mean", "latency_mean", "lateness_mean", "nis_mean",
                             "speed_err_mean", "missing_ce", "missing_vel", "missing_hae", "time_error_mean",
                             "missing_time"})
        m[name] = mean_of(name);
    for (const char* name : {"interval_max", "latency_max", "lateness_max", "time_error_max", "time_state_last",
                             "time_state_worst"})
        m[name] = pick(name, true);
    m["lateness_min"] = pick("lateness_min", false);
    m["age"] = pick("age", false);
    m["entities"] = static_cast<long long>(ems.size());
    return m;
}

// ---- Rules (spec "Rules", Evaluation; "Trace" for tick) --------------------

void Engine::evaluate_rules(Scope scope, const std::string& subject, const Json& measures, Output& out) {
    for (size_t i = 0; i < pack_.rules.size(); ++i) {
        const Rule& rule = pack_.rules[i];
        if (rule.scope != scope) continue;
        RuleState& st = rule_states_[i][subject];    // created {0, false} on first evaluation

        const Json v = *measures.find(rule.measure);
        const bool present = v.is_number();
        const bool was_active = st.active;
        bool pass;
        if (!was_active) {
            pass = present && condition_met(rule.op, v.number, rule.limit);
            st.count = pass ? st.count + 1 : 0;
            if (st.count >= rule.for_count) {
                st.active = true;
                st.count = 0;
                Json ev = event("action-start");
                ev["rule"] = rule.name;
                ev["scope"] = scope_name(scope);
                ev["subject"] = subject;
                ev["action"] = action_name(rule.action);
                ev["value"] = v;
                out.events.push(ev);
            }
        } else {
            // An absent v never clears a rule.
            pass = present && clears(rule.op, v.number, rule.clear);
            if (pass) {
                st.active = false;
                Json ev = event("action-end");
                ev["rule"] = rule.name;
                ev["scope"] = scope_name(scope);
                ev["subject"] = subject;
                ev["action"] = action_name(rule.action);
                ev["reason"] = "clear";
                ev["value"] = v;
                out.events.push(ev);
            }
        }

        Json t = Json::make_object();
        t["stage"] = "rule";
        t["rule"] = rule.name;
        t["subject"] = subject;
        t["measure"] = rule.measure;
        t["value"] = v;
        t["limit"] = was_active ? rule.clear : rule.limit;
        t["pass"] = pass;
        t["count"] = static_cast<long long>(st.count);
        t["active"] = st.active;
        out.trace.push(t);
    }
}

void Engine::forget_subject(Scope scope, const std::string& subject, Output& out) {
    for (size_t i = 0; i < pack_.rules.size(); ++i) {
        const Rule& rule = pack_.rules[i];
        if (rule.scope != scope) continue;
        auto s = rule_states_[i].find(subject);
        if (s == rule_states_[i].end()) continue;
        if (s->second.active) {
            Json ev = event("action-end");
            ev["rule"] = rule.name;
            ev["scope"] = scope_name(scope);
            ev["subject"] = subject;
            ev["action"] = action_name(rule.action);
            ev["reason"] = "forget";
            ev["value"] = nullptr;
            out.events.push(ev);
        }
        rule_states_[i].erase(s);
    }
    Json ev = event("forget");
    ev[scope == Scope::Entity ? "entity" : "source"] = subject;
    out.events.push(ev);
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
        Json f = Json::make_object();
        f["east"] = axis_json(e.filter.east);
        f["north"] = axis_json(e.filter.north);
        j["filter"] = f;
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
