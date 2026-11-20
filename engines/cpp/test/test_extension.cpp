// The registration point, proved with a test kind registered only here: a
// no-op test (`gate noop`) that always passes and reads nothing. It is not in
// builtin_tests(), so it is invisible to every pack and vector of the
// program; the fixture pack test/fixtures/correlate-noop uses it.
#include <string>

#include "check.hpp"
#include "correlate/engine.hpp"
#include "correlate/pack.hpp"
#include "correlate/tests.hpp"
#include "support.hpp"
#include "vector_support.hpp"

using corr::Json;
namespace cc = corr::correlate;

namespace {

cc::TestResult noop(const cc::TestSpec&, const cc::TestInput&) { return {Json(), Json(), true, false}; }

// builtin_tests() with the one extra registration.
cc::TestRegistry with_noop() {
    cc::TestRegistry r = cc::builtin_tests();
    r.add({"noop", {}, false, noop});
    return r;
}

cc::Pack noop_pack() {
    return cc::parse_pack_with(corr::io::read_file(support::fixture("correlate-noop/pack.def")), with_noop());
}

// Every trace record without the noop test's.
Json without_noop(const Json& trace) {
    Json out = Json::make_array();
    for (const Json& rec : trace.array) {
        const Json* t = rec.find("test");
        if (!(t && t->is_string() && t->string == "noop")) out.push(rec);
    }
    return out;
}

} // namespace

TEST(extension, builtin_registry_refuses_noop) {
    CHECK(cc::builtin_tests().find("noop") == nullptr);
    CHECK_THROWS(corr::PackError, cc::parse_pack(corr::io::read_file(support::fixture("correlate-noop/pack.def"))));
    std::string msg;
    try {
        cc::parse_pack("gate noop\n");
    } catch (const corr::PackError& e) {
        msg = e.what();
    }
    CHECK_EQ(msg, std::string("pack.def line 1: unknown test: noop"));
}

TEST(extension, noop_takes_no_parameter) {
    CHECK_THROWS(corr::PackError,
                 cc::parse_pack_with("pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 "
                                     "unknown_vel_ms=100\ngate noop x=1\nconfirm_count 1\nhold_failures 1\n"
                                     "stale_ms 1000\n",
                                     with_noop()));
}

// The fixture's own vector: each step's events and trace, then the snapshot.
TEST(extension, noop_vector) {
    const Json v = support::read_json(support::fixture("correlate-noop/vectors/01-noop-passes.json"));
    cc::Engine engine(noop_pack());
    const auto& steps = v.find("steps")->array;
    for (size_t i = 0; i < steps.size(); ++i) {
        const Json& step = steps[i];
        corr::Output out = step.has("ingest") ? engine.ingest(*step.find("ingest"))
                                              : engine.tick(step.find("tick")->integer);
        std::string at = "steps[" + std::to_string(i) + "]";
        CHECK_EQ(vectors::mismatch(out.events, *step.find("expect"), at + ".expect"), std::string());
        CHECK_EQ(vectors::mismatch(out.trace, *step.find("trace"), at + ".trace"), std::string());
    }
    CHECK_EQ(vectors::mismatch(engine.snapshot(), *v.find("snapshot"), "snapshot"), std::string());
}

// The noop gate changes nothing but its own trace records: the same steps on
// packs/correlate-gnn give the same events, the same other records and the
// same snapshot.
TEST(extension, noop_is_invisible) {
    const Json v = support::read_json(support::fixture("correlate-noop/vectors/01-noop-passes.json"));
    const auto steps = support::steps_of(v);
    cc::Engine with(noop_pack());
    cc::Engine without(cc::load_pack(support::repo("packs/correlate-gnn")));
    support::Run a = support::run_steps(with, steps), b = support::run_steps(without, steps);
    size_t noop_records = 0;
    for (size_t i = 0; i < steps.size(); ++i) {
        CHECK(corr::json_equal(a.outputs[i].events, b.outputs[i].events));
        CHECK(corr::json_equal(without_noop(a.outputs[i].trace), b.outputs[i].trace));
        noop_records += a.outputs[i].trace.array.size() - b.outputs[i].trace.array.size();
    }
    CHECK(noop_records > 0);
    CHECK(corr::json_equal(a.snapshot, b.snapshot));
}
