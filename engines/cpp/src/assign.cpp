// Method assign: spec/correlate-assign.md. Section names in comments are
// that document's unless they name correlate.md.

#include <algorithm>
#include <functional>
#include <limits>

#include "common.hpp"
#include "engine.hpp"

namespace corr {

using namespace detail;

namespace {

const double INF = std::numeric_limits<double>::infinity();

Json trace_record(const char* stage, Json a, Json b, const char* test, Json value, bool pass) {
    Json rec = Json::make_object();
    rec["stage"] = stage;
    rec["a"] = std::move(a);
    rec["b"] = std::move(b);
    rec["test"] = test;
    rec["value"] = std::move(value);
    rec["limit"] = Json();
    rec["pass"] = pass;
    return rec;
}

std::string system_label(int s) { return "s" + std::to_string(s); }

// "Assignment of one source", step 4: A leaves its system track (event
// `leave`); a system track left empty ends (event `end`).
void leave_system(Membership& m, const std::string& key, const char* reason, Json& events) {
    int s = m.system_of(key);
    auto& members = m.systems.at(s);
    members.erase(key);
    Json ev = event("leave");
    ev["system"] = system_label(s);
    ev["entity"] = key;
    ev["reason"] = reason;
    events.push(ev);
    if (members.empty()) {
        m.systems.erase(s);
        Json end = event("end");
        end["system"] = system_label(s);
        events.push(end);
    }
}

Json membership_systems_json(const Membership& m) {
    Json systems = Json::make_object();
    for (const auto& kv : m.systems) {
        Json members = Json::make_array();
        for (const auto& k : kv.second) members.push(k);
        systems[system_label(kv.first)] = members;
    }
    return systems;
}

} // namespace

// ---- Memberships -------------------------------------------------------------

int Membership::system_of(const std::string& key) const {
    for (const auto& kv : systems)
        if (kv.second.count(key)) return kv.first;
    return 0;
}

// A history's total: its records' cost, oldest first, added left to right from 0.
double History::total() const {
    double t = 0;
    for (const Record& r : records) t = t + r.cost;
    return t;
}

// ---- Ranking -------------------------------------------------------------------

// The total of an assignment: its chosen entries in ascending order of value,
// added left to right from 0.
static double assignment_total(std::vector<double> values) {
    std::sort(values.begin(), values.end());
    double t = 0;
    for (double v : values) t = t + v;
    return t;
}

// X ranks before Y: smaller total, or equal totals and the smaller choice
// vector at the first entity where they differ.
static bool ranks_before(const RankedAssignment& x, const RankedAssignment& y) {
    if (x.total != y.total) return x.total < y.total;
    return x.choice < y.choice;   // lexicographic
}

// Brute force: every assignment (each column at most once, no forbidden
// entry), then the first k in Ranking order.
std::vector<RankedAssignment> rank_assignments(const std::vector<std::vector<double>>& entries,
                                               size_t columns, size_t k) {
    const size_t n = entries.size();
    std::vector<RankedAssignment> all;
    std::vector<size_t> choice(n, 0);
    std::vector<bool> used(columns, false);
    std::function<void(size_t)> visit = [&](size_t i) {
        if (i == n) {
            std::vector<double> values;
            for (size_t r = 0; r < n; ++r) values.push_back(entries[r][choice[r]]);
            all.push_back({choice, assignment_total(values)});
            return;
        }
        for (size_t j = 0; j <= columns; ++j) {          // j == columns is alone
            if (entries[i][j] == INF) continue;
            if (j < columns && used[j]) continue;
            choice[i] = j;
            if (j < columns) used[j] = true;
            visit(i + 1);
            if (j < columns) used[j] = false;
        }
    };
    visit(0);
    std::sort(all.begin(), all.end(), ranks_before);
    if (all.size() > k) all.resize(k);
    return all;
}

// ---- Assignment of one source ----------------------------------------------------

// "Fused estimate": members predicted to t, inverse-variance weighted per
// axis, summing over members in key order. Only p, v, pp, vv are meaningful.
Filter Engine::fuse(const std::set<std::string>& members, std::int64_t t) const {
    double sp[2] = {0, 0}, spp[2] = {0, 0}, sv[2] = {0, 0}, svv[2] = {0, 0};
    for (const std::string& k : members) {
        Filter f = predict(entities_.at(k), t);
        const Axis* ax[2] = {&f.east, &f.north};
        for (int i = 0; i < 2; ++i) {
            spp[i] = spp[i] + 1 / ax[i]->pp;
            sp[i] = sp[i] + ax[i]->p / ax[i]->pp;
            svv[i] = svv[i] + 1 / ax[i]->vv;
            sv[i] = sv[i] + ax[i]->v / ax[i]->vv;
        }
    }
    Filter out;
    Axis* ax[2] = {&out.east, &out.north};
    for (int i = 0; i < 2; ++i) {
        ax[i]->pp = 1 / spp[i];
        ax[i]->p = ax[i]->pp * sp[i];
        ax[i]->vv = 1 / svv[i];
        ax[i]->v = ax[i]->vv * sv[i];
        ax[i]->pv = 0;
    }
    return out;
}

// Steps 1 to 3 for source S with rows R (key order) against membership m:
// fills `columns` (system track numbers, creation order) and `entries`
// (entries[i][j], j == columns.size() for alone; +infinity when forbidden),
// writes the gate and cost records, and returns the ranked assignments.
// `h` is the history's rank, written to the trace when window is above 1.
std::vector<RankedAssignment> Engine::rank_source(const std::vector<std::string>& rows, const Membership& m,
                                                  int h, std::vector<int>& columns,
                                                  std::vector<std::vector<double>>& entries,
                                                  Output& out) const {
    const bool windowed = pack_.window > 1;
    Json extra = Json::make_object();
    if (windowed) extra["h"] = h;
    const std::string& source = entities_.at(rows.front()).source;
    const std::set<std::string> in_r(rows.begin(), rows.end());

    // 1. Columns: system tracks whose members outside R are not empty and
    //    include no entity of S; those members are the track's others.
    columns.clear();
    std::vector<std::set<std::string>> others;
    for (const auto& kv : m.systems) {
        std::set<std::string> rest;
        bool has_source = false;
        for (const std::string& k : kv.second) {
            if (in_r.count(k)) continue;
            if (entities_.at(k).source == source) has_source = true;
            rest.insert(k);
        }
        if (rest.empty() || has_source) continue;
        columns.push_back(kv.first);
        others.push_back(std::move(rest));
    }

    // 2. Entries.
    const size_t n = rows.size(), ncol = columns.size();
    entries.assign(n, std::vector<double>(ncol + 1, INF));
    for (size_t i = 0; i < n; ++i) {
        const Entity& a = entities_.at(rows[i]);
        const int a_system = m.system_of(a.key);
        for (size_t j = 0; j < ncol; ++j) {
            // Gate against each other in key order; the first failure ends the entry.
            bool ok = true;
            for (const std::string& bk : others[j]) {
                const Entity& b = entities_.at(bk);
                if (!run_stage("gate", pack_.gate, a, b, predict(b, a.last_time_ms), out, &extra)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;
            // "Cost": d² of A against the fused estimate of the others.
            Filter f = fuse(others[j], a.last_time_ms);
            double de = a.filter.east.p - f.east.p, dn = a.filter.north.p - f.north.p;
            double d2 = de * de / (a.filter.east.pp + f.east.pp) + dn * dn / (a.filter.north.pp + f.north.pp);
            if (a_system == columns[j]) d2 = d2 - pack_.keep_bonus;
            entries[i][j] = d2;
        }
        double alone = pack_.new_cost;
        if (a_system && m.systems.at(a_system).size() == 1) alone = alone - pack_.keep_bonus;
        entries[i][ncol] = alone;
    }
    for (size_t i = 0; i < n; ++i) {
        for (size_t j = 0; j <= ncol; ++j) {
            double v = entries[i][j];
            Json rec = trace_record("assign", rows[i], j < ncol ? system_label(columns[j]) : "alone", "cost",
                                    v == INF ? Json() : Json(v), v != INF);
            if (windowed) rec["h"] = h;
            out.trace.push(rec);
        }
    }

    // 3. Assignments, ranked.
    return rank_assignments(entries, ncol, static_cast<size_t>(pack_.hypotheses));
}

// Step 4, apply, to the record's membership, rows in key order; the events,
// choices and cost go to the record.
void Engine::apply_assignment(const std::vector<std::string>& rows, const std::vector<int>& columns,
                              const RankedAssignment& r, Record& rec) const {
    Membership& m = rec.membership;
    const size_t ncol = columns.size();
    for (size_t i = 0; i < rows.size(); ++i) {
        const std::string& key = rows[i];
        const size_t j = r.choice[i];
        Json choice = Json::make_array();
        choice.push(key);
        choice.push(j < ncol ? system_label(columns[j]) : "alone");
        rec.choices.push(choice);

        int current = m.system_of(key);
        if (j < ncol && current == columns[j]) continue;                        // stays
        if (j == ncol && current && m.systems.at(current).size() == 1) continue; // already alone
        if (current) leave_system(m, key, "assign", rec.events);
        Json ev;
        int target;
        if (j < ncol) {
            target = columns[j];
            ev = event("join");
        } else {
            target = m.next_system++;
            ev = event("start");
        }
        m.systems[target].insert(key);
        ev["system"] = system_label(target);
        ev["entity"] = key;
        rec.events.push(ev);
    }
    rec.cost = rec.cost + r.total;
}

// ---- Window: on each tick -----------------------------------------------------------

Output Engine::tick_assign(std::int64_t now_ms) {
    Output out;
    const bool windowed = pack_.window > 1;
    const size_t k = static_cast<size_t>(pack_.hypotheses);

    // 1. Staleness: among entities that are not retiring, in key order. Every
    //    history gets a new record copying its latest membership, with the
    //    stale entities' leave, end and drop events.
    std::vector<std::string> stale;
    for (const auto& kv : entities_)
        if (!retiring_.count(kv.first) && is_stale(kv.second, now_ms)) stale.push_back(kv.first);
    for (History& h : histories_) {
        Record rec;
        rec.membership = h.records.empty() ? committed_ : h.records.back().membership;
        for (const std::string& key : stale) {
            if (rec.membership.system_of(key)) leave_system(rec.membership, key, "stale", rec.events);
            Json drop = event("drop");
            drop["entity"] = key;
            rec.events.push(drop);
        }
        h.records.push_back(std::move(rec));
    }
    for (const std::string& key : stale) {
        retiring_.insert(key);
        reported_.erase(key);
    }

    // 2. Rows: entities reported since the previous tick, by source.
    std::map<std::string, std::vector<std::string>> by_source;   // key order
    for (const std::string& key : reported_) by_source[entities_.at(key).source].push_back(key);
    reported_.clear();

    // 3. Sources in key order; each history in rank order gives one candidate
    //    per ranked assignment; the first k candidates are kept.
    struct Candidate {
        History history;
        double total;
        int h, r;
    };
    for (const auto& src : by_source) {
        const std::vector<std::string>& rows = src.second;
        std::vector<Candidate> candidates;
        for (size_t h = 0; h < histories_.size(); ++h) {
            std::vector<int> columns;
            std::vector<std::vector<double>> entries;
            auto ranked = rank_source(rows, histories_[h].records.back().membership, static_cast<int>(h),
                                      columns, entries, out);
            for (size_t r = 0; r < ranked.size(); ++r) {
                for (size_t i = 0; i < rows.size(); ++i) {
                    size_t j = ranked[r].choice[i];
                    Json rec = trace_record("assign", rows[i],
                                            j < columns.size() ? system_label(columns[j]) : "alone", "choice",
                                            entries[i][j], true);
                    if (windowed) {
                        rec["h"] = static_cast<int>(h);
                        rec["r"] = static_cast<int>(r);
                    }
                    out.trace.push(rec);
                }
                Candidate c{histories_[h], 0, static_cast<int>(h), static_cast<int>(r)};
                apply_assignment(rows, columns, ranked[r], c.history.records.back());
                c.total = c.history.total();   // recomputed from its records
                candidates.push_back(std::move(c));
            }
        }
        // Candidates are built in (h, r) order, so a stable sort on the total
        // orders them by total, then h, then r.
        std::stable_sort(candidates.begin(), candidates.end(),
                         [](const Candidate& x, const Candidate& y) { return x.total < y.total; });
        const size_t keep = std::min(k, candidates.size());
        if (windowed)
            for (size_t c = 0; c < candidates.size(); ++c)
                out.trace.push(trace_record("history", candidates[c].h, candidates[c].r, "total",
                                            candidates[c].total, c < keep));
        histories_.clear();
        for (size_t c = 0; c < keep; ++c) histories_.push_back(std::move(candidates[c].history));
    }

    // 4. Commit when the best history has n records.
    if (histories_[0].records.size() == static_cast<size_t>(pack_.window)) {
        const Record committed = histories_[0].records.front();
        std::vector<History> kept;
        for (size_t h = 0; h < histories_.size(); ++h) {
            bool same = json_equal(histories_[h].records.front().choices, committed.choices);
            if (windowed)
                out.trace.push(trace_record("history", static_cast<int>(h), Json(), "commit",
                                            histories_[h].total(), same));
            if (!same) continue;
            History rest = std::move(histories_[h]);
            rest.records.erase(rest.records.begin());
            kept.push_back(std::move(rest));
        }
        histories_ = std::move(kept);

        for (const Json& ev : committed.events.array) {
            out.events.push(ev);
            if (ev.find("ev")->string == "drop") {
                const std::string& key = ev.find("entity")->string;
                entities_.erase(key);
                retiring_.erase(key);
            }
        }
        committed_ = committed.membership;
        for (auto& kv : entities_) kv.second.system = committed_.system_of(kv.first);
    }

    // 5. Output.
    system_output(now_ms, out);
    return out;
}

// Step 5: one `system` per committed system track, retiring members included;
// with a window, one `provisional` per system track of the best history.
void Engine::system_output(std::int64_t now_ms, Output& out) const {
    for (const auto& kv : committed_.systems) {
        const Entity* latest_hae = nullptr;   // greatest last_time_ms with hae, ties to key order
        Json names = Json::make_array();
        for (const std::string& key : kv.second) {
            const Entity& e = entities_.at(key);
            names.push(key);
            if (number_at(e.last, "hae") && (!latest_hae || e.last_time_ms > latest_hae->last_time_ms))
                latest_hae = &e;
        }
        Filter f = fuse(kv.second, now_ms);
        auto pos = to_degrees(f.east.p, f.north.p);
        double ve = f.east.v, vn = f.north.v;

        Json ev = event("system");
        ev["system"] = system_label(kv.first);
        ev["members"] = names;
        ev["lat"] = pos.first;
        ev["lon"] = pos.second;
        ev["course"] = course_of(ve, vn);
        ev["speed_ms"] = std::hypot(ve, vn);
        if (latest_hae) ev["hae"] = *number_at(latest_hae->last, "hae");
        out.events.push(ev);
    }
    if (pack_.window <= 1) return;
    const History& best = histories_[0];
    const Membership& latest = best.records.empty() ? committed_ : best.records.back().membership;
    for (const auto& kv : latest.systems) {
        Json ev = event("provisional");
        ev["system"] = system_label(kv.first);
        Json names = Json::make_array();
        for (const std::string& key : kv.second) names.push(key);
        ev["members"] = names;
        out.events.push(ev);
    }
}

// ---- Snapshot ---------------------------------------------------------------------

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
        j["system"] = e.system ? Json(system_label(e.system)) : Json();
        filter_json(e, j);
        entities[kv.first] = j;
    }
    s["entities"] = entities;
    s["systems"] = membership_systems_json(committed_);
    s["next_system"] = committed_.next_system;
    Json reported = Json::make_array();
    for (const auto& key : reported_) reported.push(key);   // std::set: key order
    s["reported"] = reported;
    if (pack_.window <= 1) return s;

    Json retiring = Json::make_array();
    for (const auto& key : retiring_) retiring.push(key);
    s["retiring"] = retiring;
    Json histories = Json::make_array();
    for (const History& h : histories_) {
        Json hj = Json::make_object();
        hj["total"] = h.total();
        Json records = Json::make_array();
        for (const Record& r : h.records) {
            Json rj = Json::make_object();
            rj["cost"] = r.cost;
            rj["choices"] = r.choices;
            rj["events"] = r.events;
            rj["systems"] = membership_systems_json(r.membership);
            rj["next_system"] = r.membership.next_system;
            records.push(rj);
        }
        hj["records"] = records;
        histories.push(hj);
    }
    s["histories"] = histories;
    return s;
}

} // namespace corr
