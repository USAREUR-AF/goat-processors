// quality.md "Rules" and "Forwarding".
#include "quality/engine.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

#include "quality/common.hpp"

namespace corr::quality {

using namespace detail;

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

} // namespace corr::quality
