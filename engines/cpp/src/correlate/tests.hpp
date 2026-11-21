// correlate.md "Tests": the test kinds, and the one place they are
// registered. A test kind is its name, its parameters and a pure function of
// the pair; adding a kind is one entry in builtin_tests() (or one
// TestRegistry::add, as the engine's own tests do with a no-op kind).
#pragma once

#include <string>
#include <vector>

#include "correlate/entity.hpp"
#include "model/json.hpp"

namespace corr::correlate {

struct TestSpec;

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
    Json extra = Json();   // an object whose keys are added to the record (`state`: `dof`), or null
};

using TestFn = TestResult (*)(const TestSpec& t, const TestInput& in);

// One kind of test line (`gate`, `confirm` or `hold` <name> <param>=<value>...).
struct TestKind {
    std::string name;
    std::vector<std::string> params;   // exactly these, each once
    bool text_param = false;           // its one parameter is a non-empty text (`same key=`), else numbers
    TestFn run = nullptr;
    // The ranges of its parameters (correlate.md "Pack"): an error message, or
    // null when the line is valid. Null for a kind with no range rule.
    const char* (*check)(const TestSpec& t) = nullptr;
};

class TestRegistry {
public:
    // Adds a kind; a kind of the same name is replaced.
    void add(TestKind kind);
    const TestKind* find(const std::string& name) const;   // null when unknown

private:
    std::vector<TestKind> kinds_;
};

// The seven kinds of correlate.md "Tests": distance, mahalanobis, course,
// speed, altitude, same, state.
const TestRegistry& builtin_tests();

} // namespace corr::correlate
