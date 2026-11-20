// fuse.md "Attributes".
#include "fuse/attributes.hpp"

#include "trace/trace.hpp"

namespace corr::fuse {

namespace {

using trace::name_or_null;

// fuse.md "Attributes": a usable value is a string, a number or a boolean
// for `priority`, `latest` and `majority`; a number for `max` and `min`.
bool usable(const Json& v, Rule rule) {
    if (rule == Rule::Max || rule == Rule::Min) return v.is_number();
    return v.is_string() || v.is_number() || v.kind == Json::Kind::Bool;
}

// fuse.md "Attributes", equality for `majority`: strings by bytes, numbers by
// value (`1` equals `1.0`), booleans by value; different kinds never equal.
bool majority_equal(const Json& a, const Json& b) {
    if (a.kind != b.kind) return false;
    if (a.is_number()) return a.number == b.number;
    return json_equal(a, b);
}

} // namespace

// Decides one `attribute` line for a group: adds `{value, from}` to
// `attributes` when there is a candidate, and gives its trace record.
void decide_attribute(const Group& g, const Attribute& attr, const std::vector<std::string>& sources,
                      Json& attributes, Output& out) {
    // Candidates: members in key order whose last report holds a usable value.
    struct Candidate {
        const Entity* entity;
        const Json* value;
    };
    std::vector<Candidate> candidates;
    for (const Entity* e : g.members) {
        const Json* v = e->report.find(attr.key);
        if (v && usable(*v, attr.rule)) candidates.push_back({e, v});
    }

    const Candidate* winner = nullptr;
    if (!candidates.empty()) {
        winner = &candidates[0];
        switch (attr.rule) {
            case Rule::Priority:   // smallest rank, ties to key order
                for (const Candidate& c : candidates)
                    if (rank_order(sources, c.entity->source) < rank_order(sources, winner->entity->source)) winner = &c;
                break;
            case Rule::Latest:     // greatest last_time_ms, ties to key order
                for (const Candidate& c : candidates)
                    if (c.entity->last_time_ms > winner->entity->last_time_ms) winner = &c;
                break;
            case Rule::Max:        // greatest value, ties to key order
                for (const Candidate& c : candidates)
                    if (c.value->number > winner->value->number) winner = &c;
                break;
            case Rule::Min:        // smallest value, ties to key order
                for (const Candidate& c : candidates)
                    if (c.value->number < winner->value->number) winner = &c;
                break;
            case Rule::Majority: {
                // Count each distinct value; distinct values are kept in the
                // order of their first holder, so a strict `>` gives a tie to
                // the value whose first holder comes first. The winner is that
                // first holder.
                struct Tally {
                    const Candidate* first;
                    int count;
                };
                std::vector<Tally> tallies;
                for (const Candidate& c : candidates) {
                    bool counted = false;
                    for (Tally& t : tallies)
                        if (majority_equal(*t.first->value, *c.value)) {
                            ++t.count;
                            counted = true;
                            break;
                        }
                    if (!counted) tallies.push_back({&c, 1});
                }
                const Tally* best = &tallies[0];
                for (const Tally& t : tallies)
                    if (t.count > best->count) best = &t;
                winner = best->first;
                break;
            }
        }
    }

    if (winner) {
        Json a = Json::make_object();
        a["value"] = *winner->value;
        a["from"] = winner->entity->key;
        attributes[attr.key] = a;
    }

    // Trace, record 3.
    Json rec = Json::make_object();
    rec["stage"] = "attribute";
    rec["group"] = name_or_null(g.name);
    rec["key"] = attr.key;
    rec["rule"] = rule_name(attr.rule);
    Json list = Json::make_array();
    for (const Candidate& c : candidates) {
        Json j = Json::make_object();
        j["member"] = c.entity->key;
        j["value"] = *c.value;
        j["time_ms"] = static_cast<long long>(c.entity->last_time_ms);
        auto r = rank(sources, c.entity->source);
        j["rank"] = r ? Json(static_cast<long long>(*r)) : Json();
        list.push(std::move(j));
    }
    rec["candidates"] = std::move(list);
    rec["winner"] = winner ? Json(winner->entity->key) : Json();
    rec["value"] = winner ? *winner->value : Json();
    out.trace.push(std::move(rec));
}

} // namespace corr::fuse
