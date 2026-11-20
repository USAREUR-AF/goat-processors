// The correlate pack: the parsed pack.def (correlate.md "Pack",
// correlate-assign.md "Pack").
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "model/estimate.hpp"    // FilterParams
#include "correlate/tests.hpp"
#include "model/pack_text.hpp"   // PackError, TimeDefault

namespace corr::correlate {

// One line of `gate`, `confirm` or `hold` (spec "Tests").
struct TestSpec {
    std::string name;                     // the kind's name: distance, window, mahalanobis, ...
    std::map<std::string, double> num;    // numeric parameters
    std::string key;                      // the text parameter (`same`)
    TestFn run = nullptr;                 // the kind's function (correlate/tests.hpp)
};

// correlate.md "Two-model filter": the `maneuver` line.
struct ManeuverParams {
    double accel_var = 0;   // q2
    double p_enter = 0;     // a, per second
    double p_leave = 0;     // b, per second
};

// correlate-assign.md "Sensor bias": the `bias` line.
struct BiasParams {
    double sigma_m = 0;     // s
    double floor_m = 0;     // f
    double gate = 0;        // g
};

struct Pack {
    std::string name;
    std::string version;
    std::string method = "confirm";            // the `method` line; a name of correlate/method.hpp methods()
    FilterParams filter;
    std::optional<ManeuverParams> maneuver;  // optional, either method
    std::optional<double> restart_gate;      // correlate.md "Restart": optional, either method
    std::map<std::string, TimeDefault> time_default;   // correlate.md "Time quality", by source id
    std::vector<TestSpec> gate, confirm, hold;
    std::int64_t confirm_count = 0;
    std::int64_t hold_failures = 0;
    std::int64_t stale_ms = 0;
    bool same_source_allow = false;            // same_source, default forbid
    bool output_latest = false;                // output, default priority
    std::map<std::string, std::int64_t> priority;
    double new_cost = 0;                       // method assign only
    double keep_bonus = 0;                     // method assign only
    std::int64_t window = 1;                   // method assign only (correlate-assign.md "Window")
    std::int64_t hypotheses = 1;               // method assign only
    std::optional<BiasParams> bias;            // method assign only (correlate-assign.md "Sensor bias")
    std::optional<double> margin;              // method assign only (correlate-assign.md "Window")
    std::optional<double> time_offset_sigma_ms;   // method assign only, needs bias (Sensor bias, "Time offset")
};

// Parses the text of a pack.def; throws PackError on any load error.
Pack parse_pack(const std::string& text);

// The same with the test kinds of `tests` in place of builtin_tests().
Pack parse_pack_with(const std::string& text, const TestRegistry& tests);

// Reads <dir>/pack.def; throws PackError.
Pack load_pack(const std::string& dir);

} // namespace corr::correlate
