// What the quality sources share inside the module: small builders and the
// readers of quality.md "Reports". Internal to quality/.
#pragma once

#include <cstdint>
#include <initializer_list>
#include <optional>
#include <string>
#include <vector>

#include "model/json.hpp"
#include "quality/engine.hpp"

namespace corr::quality::detail {


inline Json event(const char* ev) {
    Json e = Json::make_object();
    e["ev"] = ev;
    return e;
}

// "Reports": optional keys. A null or wrong-typed value is absent; a boolean
// is never a number (the JSON reader gives booleans their own kind).
inline std::optional<double> number_at(const Json& r, const char* key) {
    const Json* v = r.find(key);
    if (!v || !v->is_number()) return std::nullopt;
    return v->number;
}

inline std::optional<std::int64_t> integer_at(const Json& r, const char* key) {
    const Json* v = r.find(key);
    if (!v || !v->is_number() || !v->is_int) return std::nullopt;
    return v->integer;
}

// "Reports": a `ce` of 0 or below is absent.
inline std::optional<double> ce_at(const Json& r) {
    auto ce = number_at(r, "ce");
    if (ce && *ce <= 0) return std::nullopt;
    return ce;
}

template <typename T>
inline Json opt(const std::optional<T>& v) {
    return v ? Json(*v) : Json();
}

inline Json opt(const std::optional<std::int64_t>& v) {
    return v ? Json(static_cast<long long>(*v)) : Json();
}

inline Json sample_trace(const std::string& entity, const char* sample, Json value, Json inputs) {
    Json t = Json::make_object();
    t["stage"] = "sample";
    t["entity"] = entity;
    t["sample"] = sample;
    t["value"] = std::move(value);
    t["inputs"] = std::move(inputs);
    return t;
}

inline Json list(std::initializer_list<Json> items) {
    Json a = Json::make_array();
    for (const auto& x : items) a.push(x);
    return a;
}

// "Entity measures": a mean is s / n, s from 0.0 adding each sample in order.
inline double mean(const std::vector<double>& xs) {
    double s = 0.0;
    for (double x : xs) s += x;
    return s / static_cast<double>(xs.size());
}

// "Reports", "Time quality": the code of a time state for measures. Higher is worse.
inline std::int64_t time_state_code(const std::string& state) {
    if (state == "coherent") return 0;
    if (state == "drifting") return 1;
    return 2;   // free-running
}

inline bool condition_met(Op op, double v, double limit) {
    switch (op) {
        case Op::Lt: return v < limit;
        case Op::Le: return v <= limit;
        case Op::Gt: return v > limit;
        case Op::Ge: return v >= limit;
    }
    return false;
}

// "Rules": for op > or >= a rule clears when v < clear; for < or <=, when v > clear.
inline bool clears(Op op, double v, double clear) {
    return (op == Op::Gt || op == Op::Ge) ? v < clear : v > clear;
}

inline Json record_json(const Record& r) {
    Json j = Json::make_object();
    j["wt"] = static_cast<long long>(r.wt);
    j["time_ms"] = static_cast<long long>(r.time_ms);
    j["order"] = r.order;
    j["interval"] = opt(r.interval);
    j["latency"] = opt(r.latency);
    j["lateness"] = r.lateness;
    j["source_out_of_order"] = r.source_out_of_order;
    j["time_error"] = opt(r.time_error);
    j["time_state"] = opt(r.time_state);
    j["nis"] = opt(r.nis);
    j["speed_err"] = opt(r.speed_err);
    j["ce"] = r.ce;
    j["vel"] = r.vel;
    j["hae"] = r.hae;
    return j;
}


} // namespace corr::quality::detail
