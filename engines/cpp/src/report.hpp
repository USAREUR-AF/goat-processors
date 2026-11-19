// The Reports section of spec/correlate.md, shared by the correlator and the
// filter (spec/filter.md "Reports" cites it): required keys, the optional-key
// rules, integers, and the `-`-separated elements of `type`.
#pragma once

#include <cstdint>
#include <optional>
#include <string>

#include "json.hpp"

namespace corr::report {

// An integer is a JSON number written without a fraction or an exponent.
bool is_integer(const Json* v);

// The first required key that is missing (absent, null or of the wrong type),
// checked in the order of the table: track.source_id, uid, time_ms, lat, lon.
std::optional<std::string> missing_required(const Json& r);

// The optional-key rules: the value of `key` when the report holds it with a
// value other than null and, for `hae`, `ce`, `course`, `speed_ms`, `type` and
// `stale_ms`, of the right type (and a `ce` above 0). Null otherwise.
const Json* present(const Json& r, const std::string& key);

// A present optional number, or absent.
std::optional<double> number_at(const Json& r, const std::string& key);

// A `ce` of 0 or below is absent.
std::optional<double> ce_at(const Json& r);

// A present `stale_ms`, or absent.
std::optional<std::int64_t> stale_ms_at(const Json& r);

// The `index`-th (0-based) `-`-separated element of a present `type`, or
// absent when `type` is absent or has fewer elements. An empty element is "".
std::optional<std::string> type_element(const Json& r, size_t index);

} // namespace corr::report
