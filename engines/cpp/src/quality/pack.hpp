// The quality pack (quality.md "Pack", "Rules").
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "model/estimate.hpp"    // FilterParams
#include "model/pack_text.hpp"   // PackError, TimeDefault

namespace corr::quality {

// ---- Pack (spec "Pack", "Rules") ------------------------------------------

enum class Scope { Entity, Source };
enum class Op { Lt, Le, Gt, Ge };
enum class Action { Mark, Downgrade, Drop, Alert };

struct Rule {
    std::string name;
    Scope scope = Scope::Entity;
    std::string measure;
    Op op = Op::Gt;
    double limit = 0;
    std::int64_t for_count = 1;
    double clear = 0;
    Action action = Action::Alert;
    double factor = 1;          // downgrade only
};

struct Pack {
    std::string name;
    std::string version;
    FilterParams filter;        // accel_var, default_ce_m, vel_sigma_ms, unknown_vel_ms
    std::int64_t window_ms = 0;
    std::int64_t min_samples = 0;
    std::int64_t forget_ms = 0;
    std::map<std::string, TimeDefault> time_default;   // by source id (spec "Reports", "Time quality")
    std::vector<Rule> rules;    // pack order
};

// Parses the text of a pack.def; throws corr::PackError on any load error.
Pack parse_pack(const std::string& text);

// Reads <dir>/pack.def; throws corr::PackError.
Pack load_pack(const std::string& dir);

// The measures tables, in table order (spec "Entity measures", "Source measures").
const std::vector<std::string>& entity_measure_names();
const std::vector<std::string>& source_measure_names();

const char* scope_name(Scope s);
const char* action_name(Action a);

} // namespace corr::quality
