// The filter's pack (spec/filter.md "Pack"): an ordered list of keep/drop
// rules, each a list of conditions, a default and forget_ms.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "model/pack_text.hpp"  // PackError

namespace corr::filter {

// One `when` line (spec "Conditions" and "Pack", parameter sets). Only the
// fields of its condition are set.
struct Condition {
    enum class KeyForm { Eq, In, Range };

    std::string test;                  // condition name as written: circle, polygon, near, ...
    bool negated = false;              // written with `not`

    double lat = 0, lon = 0;           // circle
    double radius_m = 0;               // circle, near
    std::vector<std::pair<double, double>> vertices;  // polygon: (lat, lon) in pack order
    std::string reference;             // near: an entity key
    std::int64_t max_age_ms = 0;       // near
    std::vector<std::string> in;       // env, affiliation, source, uid, key form in
    std::string name;                  // key, has
    KeyForm key_form = KeyForm::Eq;    // key
    std::string eq;                    // key form eq: the pack text
    std::optional<double> min, max;    // key form range, speed, altitude
    std::int64_t min_ms = 0;           // interval
};

struct Rule {
    std::string name;
    bool keep = false;                 // the action: keep, or drop
    std::vector<Condition> when;       // in pack order
};

struct Pack {
    std::string name;
    std::string version;
    bool default_keep = false;
    std::int64_t forget_ms = 0;
    std::vector<Rule> rules;           // in pack order
};

// Parses the text of a pack.def; throws PackError on any load error.
Pack parse_pack(const std::string& text);

// Reads <dir>/pack.def; throws PackError.
Pack load_pack(const std::string& dir);

// Spec "Pack", Values: a number is `-?[0-9]+(\.[0-9]+)?`.
bool is_pack_number(const std::string& s);

} // namespace corr::filter
