// Pack: the parsed pack.def (spec "Pack").
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace corr {

struct PackError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

// One line of `gate`, `confirm` or `hold` (spec "Tests").
struct TestSpec {
    std::string name;                     // distance, window, mahalanobis, course, speed, altitude, same
    std::map<std::string, double> num;    // numeric parameters
    std::string key;                      // `same` only
};

struct FilterParams {
    double accel_var = 0;
    double default_ce_m = 0;
    double vel_sigma_ms = 0;
    double unknown_vel_ms = 0;
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
    bool method_assign = false;                // method, default confirm (spec correlate-assign.md)
    FilterParams filter;
    std::optional<ManeuverParams> maneuver;  // optional, either method
    std::optional<double> restart_gate;      // correlate.md "Restart": optional, either method
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
};

// Parses the text of a pack.def; throws PackError on any load error.
Pack parse_pack(const std::string& text);

// Reads <dir>/pack.def; throws PackError.
Pack load_pack(const std::string& dir);

} // namespace corr
