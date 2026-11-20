// quality.md "Entity measures" and "Source measures", and the one place a
// measure is registered: the table measures() in measures.cpp. A measure is
// its name, a pure function of an entity's window samples (absent for a
// source-only measure) and how a source aggregates it over its entities.
// Adding one is one row; the pack accepts its name from that row.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "model/json.hpp"
#include "quality/entity.hpp"

namespace corr::quality {

// One sample as written: an integer, or a binary64. `number` is its value
// as a binary64 either way (as Json holds it).
struct Sample {
    double number = 0;
    bool is_int = false;
    long long integer = 0;

    static Sample of_int(long long v) { return {static_cast<double>(v), true, v}; }
    static Sample of_double(double v) { return {v, false, 0}; }
    Json json() const { return is_int ? Json(integer) : Json(number); }
};

// "Samples": the samples of one entity's window, in window order, and its counts.
struct WindowSamples {
    std::vector<Sample> intervals, latencies, lateness, nis, speed_err, time_errors, time_states;
    std::int64_t out_of_order = 0, duplicate = 0, source_out_of_order = 0;
    std::int64_t no_ce = 0, no_vel = 0, no_hae = 0, no_time = 0;
    std::int64_t reports = 0;   // records in the window
    std::int64_t age = 0;       // now_ms - last
    size_t k = 0;               // min_samples: a statistic is null below k samples
};

WindowSamples window_samples(const Entity& e, std::int64_t now_ms, std::int64_t min_samples);

// "Source measures": how a source combines its entities' present values.
enum class Aggregate {
    Sum,     // the sum of the integers
    Mean,    // the mean
    Max,     // the largest, as written
    Min,     // the smallest, as written
    Count,   // the number of entities (source only)
};

struct MeasureKind {
    const char* name;
    Json (*entity)(const WindowSamples& s);   // null: a source-only measure
    Aggregate source;
};

// Every measure, in the table order of quality.md.
const std::vector<MeasureKind>& measures();

// An object, one key per entity measure, of entity `e` at now_ms.
Json entity_measures(const Entity& e, std::int64_t now_ms, std::int64_t min_samples);

// An object, one key per source measure, over the measures of the source's
// entities in key order.
Json source_measures(const std::vector<const Json*>& entity_measures);

} // namespace corr::quality
