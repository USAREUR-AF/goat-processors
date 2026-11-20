// Method assign: spec/correlate-assign.md, version 0.6: "Assignment of one
// source", "Window", "Snapshot". Section names in comments are
// that document's unless they name correlate.md.

#include <algorithm>
#include <functional>
#include <limits>

#include "assign/cost.hpp"
#include "correlate/common.hpp"
#include "assign/assign.hpp"

namespace corr::correlate {

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

} // namespace

// ---- Ingest -----------------------------------------------------------------------

// "Window": a retiring entity's report is rejected.
const char* AssignMethod::refuse(const std::string& key) const {
    return retiring_.count(key) ? "retiring" : nullptr;
}

// An accepted report is decided at the next tick.
void AssignMethod::accepted(Entity& a, Output&) { reported_.insert(a.key); }

// ---- Assignment of one source ----------------------------------------------------

// "Fused estimate": members predicted to t, inverse-variance weighted per
// axis, summing over members in key order. Only p, v, pp, vv are meaningful.
// With `frame` (Cost), each member's prediction is one for comparison with
// that entity: its timing variance added (correlate.md "Track estimate"),
// then, with `bias`, moved into that entity's frame. The estimate for output
// passes no frame and gets neither.
Filter AssignMethod::fuse(const std::set<std::string>& members, std::int64_t t, const Entity* frame) const {
    std::vector<Filter> predictions;
    predictions.reserve(members.size());
    for (const std::string& k : members) {
        const Entity& member = entities_.at(k);
        predictions.push_back(frame ? predict_into_frame(*frame, member, t) : predict(member, t));
    }
    return fused_estimate(predictions);
}

// Steps 1 to 3 for source S with rows R (key order) against membership m:
// fills `columns` (system track numbers, creation order) and `entries`
// (entries[i][j], j == columns.size() for alone; +infinity when forbidden),
// writes the gate and cost records, and returns the ranked assignments.
// `h` is the history's rank, written to the trace when window is above 1.
std::vector<RankedAssignment> AssignMethod::rank_source(const std::vector<std::string>& rows, const Membership& m,
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
                if (!run_stage("gate", pack_.gate, a, b, predict_into_frame(a, b, a.last_time_ms), out,
                               &extra)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) continue;
            // "Cost": d² of A against the fused estimate of the others, each
            // with its timing variance added and then moved into A's frame
            // (Sensor bias); pp_a is A's filter pp plus A's timing variance.
            entries[i][j] = entry_cost(a, fuse(others[j], a.last_time_ms, &a), a_system == columns[j], pack_.keep_bonus);
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
void AssignMethod::apply_assignment(const std::vector<std::string>& rows, const std::vector<int>& columns,
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

Output AssignMethod::tick(std::int64_t now_ms) {
    Output out;
    const bool windowed = pack_.window > 1;
    const size_t k = static_cast<size_t>(pack_.hypotheses);

    // 1. Staleness: among entities that are not retiring, in key order. Every
    //    history gets a new record copying its latest membership, with the
    //    stale entities' leave, end and drop events.
    //    Then each restarted entity that is not stale, in key order, leaves
    //    its system track (reason `restart`).
    std::vector<std::string> stale;
    for (const auto& kv : entities_)
        if (!retiring_.count(kv.first) && is_stale(kv.second, now_ms)) stale.push_back(kv.first);
    const std::set<std::string> stale_set(stale.begin(), stale.end());
    for (History& h : histories_) {
        Record rec;
        rec.membership = h.records.empty() ? committed_ : h.records.back().membership;
        for (const std::string& key : stale) {
            if (rec.membership.system_of(key)) leave_system(rec.membership, key, "stale", rec.events);
            Json drop = event("drop");
            drop["entity"] = key;
            rec.events.push(drop);
        }
        for (const std::string& key : restarted_) {   // std::set: key order
            if (stale_set.count(key)) continue;
            if (rec.membership.system_of(key)) leave_system(rec.membership, key, "restart", rec.events);
        }
        h.records.push_back(std::move(rec));
    }
    restarted_.clear();   // no entity is restarted after this step
    for (const std::string& key : stale) {
        retiring_.insert(key);
        reported_.erase(key);
    }

    // 2. Rows: entities reported since the previous tick, by source.
    std::map<std::string, std::vector<std::string>> by_source;   // key order
    for (const std::string& key : reported_) by_source[entities_.at(key).source].push_back(key);
    const std::set<std::string> rows = reported_;   // read again by the bias update (step 5)
    reported_.clear();

    // 3. Sources in key order; each history in rank order gives one candidate
    //    per ranked assignment; the first k candidates are kept, and with
    //    `margin` of those only the ones whose total is at most best + m.
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
        size_t keep = std::min(k, candidates.size());
        Json limit;   // null without margin
        if (pack_.margin) {
            const double cut = candidates[0].total + *pack_.margin;
            limit = cut;
            while (keep > 0 && candidates[keep - 1].total > cut) --keep;
        }
        if (windowed)
            for (size_t c = 0; c < candidates.size(); ++c) {
                Json rec = trace_record("history", candidates[c].h, candidates[c].r, "total",
                                        candidates[c].total, c < keep);
                rec["limit"] = limit;
                out.trace.push(rec);
            }
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

    // 5. Bias, from the committed membership (also with margin).
    if (pack_.bias) bias_update(now_ms, rows, out);

    // 6. Output: the committed membership, or with `margin` the best
    //    history's latest membership.
    const History& best = histories_[0];
    const Membership& latest = best.records.empty() ? committed_ : best.records.back().membership;
    system_output(now_ms, pack_.margin ? latest : committed_, out);
    return out;
}

// Step 6: one `system` per system track of `reported` (the committed
// membership, retiring members included, or with `margin` the best history's
// latest membership, which holds no retiring member); with a window, one
// `provisional` per system track of the best history.
void AssignMethod::system_output(std::int64_t now_ms, const Membership& reported, Output& out) const {
    for (const auto& kv : reported.systems) {
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

Json AssignMethod::snapshot() const {
    Json s = Json::make_object();
    s["ref"] = snapshot::ref_json(ref_);
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
    if (pack_.restart_gate) {
        Json restarted = Json::make_array();
        for (const auto& key : restarted_) restarted.push(key);
        s["restarted"] = restarted;
    }
    if (pack_.bias) {
        Json bias = Json::make_object();
        for (const auto& kv : bias_) {   // std::map: keys in order
            const BiasState& st = kv.second;
            Json j = Json::make_object();
            j["east"] = st.o[0];
            j["weight_east"] = st.w[0];
            j["north"] = st.o[1];
            j["weight_north"] = st.w[1];
            j["var"] = st.var;
            j["pairs"] = static_cast<long long>(st.n);
            if (pack_.time_offset_sigma_ms) {
                j["time_offset_ms"] = st.tau * 1000;
                Json sums = Json::make_array();
                for (double x : st.S) sums.push(x);
                j["sums"] = sums;
            }
            bias[kv.first] = j;
        }
        s["bias"] = bias;
    }
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

} // namespace corr::correlate
