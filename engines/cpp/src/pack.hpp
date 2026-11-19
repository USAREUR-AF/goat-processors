// Pack: the parsed pack.def (spec "Pack").
#pragma once

#include <cstdint>
#include <map>
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

struct Pack {
    std::string name;
    std::string version;
    FilterParams filter;
    std::vector<TestSpec> gate, confirm, hold;
    std::int64_t confirm_count = 0;
    std::int64_t hold_failures = 0;
    std::int64_t stale_ms = 0;
    bool same_source_allow = false;            // same_source, default forbid
    bool output_latest = false;                // output, default priority
    std::map<std::string, std::int64_t> priority;
};

// Parses the text of a pack.def; throws PackError on any load error.
Pack parse_pack(const std::string& text);

// Reads <dir>/pack.def; throws PackError.
Pack load_pack(const std::string& dir);

} // namespace corr
