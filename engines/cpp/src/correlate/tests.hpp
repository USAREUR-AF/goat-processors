// correlate.md "Tests": the result of one test line on a pair, as a pure
// function of the pair.
#pragma once

#include "correlate/entity.hpp"
#include "correlate/pack.hpp"
#include "model/json.hpp"

namespace corr::correlate {

// What a test reads: A (the entity of the report), B, B's prediction for
// comparison to A's time, and the pack's default_ce_m.
struct TestInput {
    const Entity& a;
    const Entity& b;
    const Filter& bp;
    double default_ce_m;
};

struct TestResult {
    Json value, limit;
    bool pass;
    bool skipped;
};

TestResult run_test(const TestSpec& t, const TestInput& in);

} // namespace corr::correlate
