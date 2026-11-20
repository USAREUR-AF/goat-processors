// What every function's ingest and tick return (spec/README.md "What every
// function shares"): the events, then the trace records, of one call.
#pragma once

#include "model/json.hpp"

namespace corr {

struct Output {
    Json events = Json::make_array();
    Json trace = Json::make_array();
};

} // namespace corr
