// Small helpers the correlate and assign sources share. Internal to the
// correlate function.
#pragma once

#include <string>

#include "model/frame.hpp"
#include "model/json.hpp"
#include "model/report.hpp"
#include "snapshot/snapshot.hpp"
#include "trace/trace.hpp"

namespace corr::correlate::detail {

using report::is_integer;
using report::number_at;
using trace::event;

inline Json filter_json_of(const Filter& f) { return snapshot::filter_json(f); }

// A `filter` stage record (correlate.md "Trace"): the `time` record (model
// null) and the two-model `likelihood` and `mode` records.
inline Json filter_record(const std::string& entity, const char* test, const char* model, double value) {
    Json rec = Json::make_object();
    rec["stage"] = "filter";
    rec["a"] = entity;
    rec["b"] = model ? Json(model) : Json();   // null for the `time` record
    rec["test"] = test;
    rec["value"] = value;
    rec["limit"] = Json();
    rec["pass"] = true;
    return rec;
}

} // namespace corr::correlate::detail
