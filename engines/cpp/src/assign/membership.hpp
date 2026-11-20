// correlate-assign.md "Memberships": the system tracks of one picture, and
// the pending ticks of a history.
#pragma once

#include <map>
#include <set>
#include <string>
#include <vector>

#include "model/json.hpp"

namespace corr::correlate {

// One picture of the system tracks.
struct Membership {
    std::map<int, std::set<std::string>> systems;   // creation order, members in key order
    int next_system = 1;

    int system_of(const std::string& key) const;     // 0 when in none
};

// One pending tick of a history.
struct Record {
    double cost = 0;
    Json choices = Json::make_array();   // [entity, chosen] pairs
    Json events = Json::make_array();
    Membership membership;
};

struct History {
    std::vector<Record> records;         // oldest first
    double total() const;
};

// `s<n>`, the name of system track n.
std::string system_label(int s);

// "Assignment of one source", step 4: `key` leaves its system track (event
// `leave` with `reason`); a system track left empty ends (event `end`).
void leave_system(Membership& m, const std::string& key, const char* reason, Json& events);

// `{"s<n>": [members...]}` of a membership.
Json membership_systems_json(const Membership& m);

} // namespace corr::correlate
