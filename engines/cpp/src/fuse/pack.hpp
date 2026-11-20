// Fuse pack: the parsed pack.def (fuse.md "Pack").
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "model/estimate.hpp"    // FilterParams
#include "model/pack_text.hpp"   // PackError

namespace corr::fuse {

// fuse.md "Kinematics": the five methods.
enum class Method { InverseVariance, CovarianceIntersection, Best, Priority, Latest };

// fuse.md "Attributes": the five rules.
enum class Rule { Priority, Latest, Majority, Max, Min };

const char* method_name(Method m);
const char* rule_name(Rule r);

// One `attribute <key> rule=<rule>` line.
struct Attribute {
    std::string key;
    Rule rule;
};

struct Pack {
    std::string name;
    std::string version;
    FilterParams filter;
    Method kinematics = Method::InverseVariance;
    std::vector<Attribute> attributes;     // pack order
    std::vector<std::string> sources;      // line order is rank order
    std::int64_t stale_ms = 0;
};

// Parses the text of a pack.def; throws PackError on any load error.
Pack parse_pack(const std::string& text);

// Reads <dir>/pack.def; throws PackError.
Pack load_pack(const std::string& dir);

} // namespace corr::fuse
