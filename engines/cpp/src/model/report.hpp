// The Reports section of spec/correlate.md, shared by the correlator and the
// filter (spec/filter.md "Reports" cites it): required keys, the optional-key
// rules, integers, and the `-`-separated elements of `type`.
#pragma once

#include <cstdint>
#include <map>
#include <optional>
#include <string>

#include "model/json.hpp"

namespace corr {

// correlate.md "Reports", "Time quality" and "Pack": one `time_default` line,
// the defaults of one source; each key is absent when the line does not give it.
struct TimeDefault {
    std::optional<double> error_ms;
    std::optional<std::string> state;
};

} // namespace corr

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

// correlate.md "Reports", "Time quality": a `time_error_ms` that is a finite
// number, 0 or above; any other value (wrong type, negative, not finite) is
// absent. Never a reject.
std::optional<double> time_error_at(const Json& r);

// correlate.md "Reports", "Time quality": a `time_state` that is one of
// `coherent`, `drifting`, `free-running`, compared byte for byte; any other
// value is absent. Never a reject.
std::optional<std::string> time_state_at(const Json& r);

// correlate.md "Reports", "Time quality", steps 1 and 2, per key: the
// report's own valid value, and the pack's `time_default` for the report's
// `track.source_id`. Step 3 is the caller's: correlate takes error 0 and
// state `coherent`; quality.md records the value as unstated.
struct TimeQuality {
    std::optional<double> report_error_ms, default_error_ms;
    std::optional<std::string> report_state, default_state;

    // Step 1, else step 2; absent when neither gives the key.
    std::optional<double> error_ms() const { return report_error_ms ? report_error_ms : default_error_ms; }
    std::optional<std::string> state() const { return report_state ? report_state : default_state; }
};
TimeQuality time_quality(const Json& r, const std::string& source,
                         const std::map<std::string, TimeDefault>& defaults);

// The three time states correlate.md names.
bool is_time_state(const std::string& s);

} // namespace corr::report
