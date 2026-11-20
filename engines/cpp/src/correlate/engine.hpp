// The correlate function (correlate.md "What the correlator does", version
// 0.8, and correlate-assign.md version 0.6): load_pack (in correlate/pack.hpp),
// then ingest, tick and snapshot. The shared steps of ingest are here; the
// pack's method (correlate/method.hpp) does the rest.
#pragma once

#include <cstdint>
#include <memory>

#include "correlate/core.hpp"
#include "correlate/method.hpp"
#include "correlate/pack.hpp"
#include "model/json.hpp"
#include "model/output.hpp"

namespace corr::correlate {

class Engine {
public:
    explicit Engine(Pack pack);

    Output ingest(const Json& report);
    Output tick(std::int64_t now_ms);
    Json snapshot() const;

private:
    std::unique_ptr<Core> core_;       // on the heap, so the method's reference survives a move
    std::unique_ptr<Method> method_;
};

} // namespace corr::correlate
