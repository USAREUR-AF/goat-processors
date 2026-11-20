// correlate-assign.md "Memberships".
#include "assign/membership.hpp"

#include "trace/trace.hpp"

namespace corr::correlate {

using trace::event;

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
    events.push(std::move(ev));
    if (members.empty()) {
        m.systems.erase(s);
        Json end = event("end");
        end["system"] = system_label(s);
        events.push(std::move(end));
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

} // namespace corr::correlate
