// Events and trace records: the JSON objects every function's ingest and
// tick return (correlate.md, filter.md, fuse.md, quality.md "Events" and
// "Trace"). Objects keep their keys in byte order (model/json.hpp), so a
// record is the same whatever order its keys are given in.
#pragma once

#include <cstdint>
#include <initializer_list>
#include <optional>
#include <string>
#include <utility>

#include "model/json.hpp"

namespace corr::trace {

// An object of the given keys and values.
inline Json object(std::initializer_list<std::pair<const char*, Json>> kv) {
    Json o = Json::make_object();
    for (const auto& p : kv) o[p.first] = p.second;
    return o;
}

// An event: {"ev": <ev>}, the caller adding its other keys.
inline Json event(const char* ev) {
    Json e = Json::make_object();
    e["ev"] = ev;
    return e;
}

// A string, or null when absent.
inline Json name_or_null(const std::optional<std::string>& name) { return name ? Json(*name) : Json(); }

// An integer, or null when absent.
inline Json int_or_null(const std::optional<std::int64_t>& v) {
    return v ? Json(static_cast<long long>(*v)) : Json();
}

// A number, or null when absent.
inline Json number_or_null(const std::optional<double>& v) { return v ? Json(*v) : Json(); }

} // namespace corr::trace
