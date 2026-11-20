// Unit tests of src/quality: pack, measures (the table), input clock, rules,
// forwarding, engine.
#include <cmath>
#include <limits>
#include <string>

#include "check.hpp"
#include "quality/engine.hpp"
#include "quality/input_clock.hpp"
#include "quality/measures.hpp"
#include "quality/pack.hpp"
#include "quality/rules.hpp"
#include "support.hpp"

using corr::Json;
namespace cq = corr::quality;

namespace {

const std::string kHead =
    "pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
    "window window_ms=10000 min_samples=2 forget_ms=60000\n";

cq::Record rec(std::int64_t t, const char* order) {
    cq::Record r;
    r.wt = t;
    r.time_ms = t;
    r.order = order;
    return r;
}

} // namespace

TEST(quality, measure_table) {
    const auto& all = cq::measures();
    CHECK_EQ(all.size(), size_t{24});
    CHECK_EQ(cq::entity_measure_names().size(), size_t{23});
    CHECK_EQ(cq::source_measure_names().back(), std::string("entities"));
    for (const auto& m : all) CHECK(m.entity != nullptr || m.source == cq::Aggregate::Count);
}

TEST(quality, entity_and_source_measures) {
    cq::Entity e;
    e.last = 3000;
    e.window = {rec(1000, "first"), rec(2000, "advance"), rec(3000, "advance"), rec(2500, "out-of-order")};
    e.window[1].interval = 1000;
    e.window[2].interval = 1000;
    e.window[1].latency = 5;
    e.window[2].latency = 7;
    e.window[0].ce = true;
    e.window[0].time_state = "drifting";
    e.window[1].time_state = "free-running";
    e.window[0].lateness = Json(2.5);
    e.window[1].lateness = Json(static_cast<long long>(-1));
    Json m = cq::entity_measures(e, 4000, 2);
    CHECK_EQ(m.find("reports")->integer, std::int64_t{4});
    CHECK_EQ(m.find("age")->integer, std::int64_t{1000});
    CHECK_EQ(m.find("interval_mean")->number, 1000.0);
    CHECK_EQ(m.find("latency_max")->integer, std::int64_t{7});
    CHECK_EQ(m.find("lateness_min")->integer, std::int64_t{-1});
    CHECK_EQ(m.find("out_of_order")->integer, std::int64_t{1});
    CHECK_EQ(m.find("missing_ce")->number, 0.75);
    CHECK_EQ(m.find("time_state_worst")->integer, std::int64_t{2});
    CHECK_EQ(m.find("time_state_last")->integer, std::int64_t{2});
    CHECK(m.find("nis_mean")->is_null());   // fewer than 2 samples
    Json m2 = cq::entity_measures(e, 5000, 2);
    Json s = cq::source_measures({&m, &m2});
    CHECK_EQ(s.find("entities")->integer, std::int64_t{2});
    CHECK_EQ(s.find("reports")->integer, std::int64_t{8});
    CHECK_EQ(s.find("age")->integer, std::int64_t{1000});
    CHECK(s.find("nis_mean")->is_null());
    CHECK_EQ(s.find("interval_mean")->number, 1000.0);
}

TEST(quality, input_clock_median) {
    std::map<std::string, cq::Entity> es;
    auto add = [&](const std::string& key, const std::string& src, std::int64_t last) {
        cq::Entity e;
        e.source = src;
        e.last = last;
        es[key] = e;
    };
    CHECK(!cq::input_clock(es, "a"));
    add("a/1", "a", 100);
    add("b/1", "b", 200);
    add("b/2", "b", 250);
    add("c/1", "c", 300);
    Json clock = *cq::input_clock(es, "a");   // median of 250 and 300
    CHECK(!clock.is_int && clock.number == 275.0);
    CHECK_EQ(cq::input_clock(es, "x")->integer, std::int64_t{250});
    CHECK_EQ(*cq::source_latest(es, "b"), std::int64_t{250});
    CHECK(!cq::source_latest(es, "z"));
}

TEST(quality, rule_steps) {
    cq::Pack p = cq::parse_pack(kHead + "rule late scope=entity measure=age op=> limit=10 for=2 clear=5 action=mark\n");
    const cq::Rule& rule = p.rules[0];
    Json m = Json::make_object();
    m["age"] = 20;
    cq::RuleStep s1 = cq::evaluate_rule(rule, {}, "e", m);
    CHECK(s1.state.count == 1 && !s1.state.active && !s1.event);
    cq::RuleStep s2 = cq::evaluate_rule(rule, s1.state, "e", m);
    CHECK(s2.state.active && s2.event && s2.event->find("ev")->string == "action-start");
    m["age"] = 7;
    cq::RuleStep s3 = cq::evaluate_rule(rule, s2.state, "e", m);
    CHECK(s3.state.active && !s3.event);   // not below clear
    m["age"] = Json();
    CHECK(cq::evaluate_rule(rule, s2.state, "e", m).state.active);   // absent never clears
    m["age"] = 1;
    cq::RuleStep s4 = cq::evaluate_rule(rule, s2.state, "e", m);
    CHECK(!s4.state.active && s4.event->find("reason")->string == "clear");
    CHECK_EQ(s4.trace.find("limit")->number, 5.0);
}

TEST(quality, forwarding) {
    cq::Pack p = cq::parse_pack(kHead +
                                "rule m scope=entity measure=age op=> limit=1 for=1 clear=0 action=mark\n"
                                "rule d scope=entity measure=age op=> limit=1 for=1 clear=0 action=downgrade factor=2\n"
                                "rule x scope=entity measure=age op=> limit=1 for=1 clear=0 action=drop\n");
    Json r = support::report("s", "u", 0, 0, 0);
    r["quality.marks"] = Json::make_array();
    r["quality.marks"].push("m");
    Json ev = cq::forward({&p.rules[0], &p.rules[1]}, r, "s/u", 50);
    CHECK(!ev.find("withheld")->boolean);
    CHECK_EQ(ev.find("report")->find("ce")->number, 100.0);
    CHECK_EQ(ev.find("report")->find("quality.marks")->array.size(), size_t{1});
    CHECK(cq::forward({&p.rules[2]}, r, "s/u", 50).find("withheld")->boolean);
    r["ce"] = std::numeric_limits<double>::max();
    CHECK_EQ(cq::forward({&p.rules[1]}, r, "s/u", 50).find("report")->find("ce")->number,
             std::numeric_limits<double>::max());
}

TEST(quality, pack_errors) {
    for (const char* bad :
         {"rule\n", "rule a=b\n", "rule bad! scope=entity measure=age op=> limit=1 for=1 clear=0 action=mark\n",
          "rule r scope=world measure=age op=> limit=1 for=1 clear=0 action=mark\n",
          "rule r scope=entity measure=entities op=> limit=1 for=1 clear=0 action=mark\n",
          "rule r scope=entity measure=age op=!= limit=1 for=1 clear=0 action=mark\n",
          "rule r scope=entity measure=age op=> limit=1 for=0 clear=0 action=mark\n",
          "rule r scope=entity measure=age op=> limit=1 for=1 clear=2 action=mark\n",
          "rule r scope=entity measure=age op=< limit=1 for=1 clear=0 action=mark\n",
          "rule r scope=entity measure=age op=> limit=1 for=1 clear=0 action=downgrade\n",
          "rule r scope=entity measure=age op=> limit=1 for=1 clear=0 action=mark factor=2\n",
          "rule r scope=entity measure=age op=> limit=1 for=1 clear=0 action=downgrade factor=0.5\n",
          "rule r scope=entity measure=age op=> limit=1 for=1 clear=0 action=shout\n",
          "rule r scope=entity measure=age op=> limit=1 for=x clear=0 action=mark\n",
          "rule r scope=entity measure=age op=> limit=1e999 for=1 clear=0 action=mark\n",
          "rule r scope=entity measure=age op=> limit=1 for=1 clear=0 action=mark\n"
          "rule r scope=entity measure=age op=> limit=1 for=1 clear=0 action=mark\n",
          "pack q\n", "unknown 1\n", "time_default s error_ms=1e3\n", "bell\x07\n"})
        CHECK_THROWS(corr::PackError, cq::parse_pack(kHead + bad));
    CHECK_THROWS(corr::PackError, cq::parse_pack("pack p\nversion 1\n"));
    CHECK_THROWS(corr::PackError,
                 cq::parse_pack("pack p\nversion 1\nfilter accel_var=-1 default_ce_m=50 vel_sigma_ms=5 "
                                "unknown_vel_ms=100\nwindow window_ms=1 min_samples=1 forget_ms=1\n"));
    CHECK_THROWS(corr::PackError,
                 cq::parse_pack("pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 "
                                "unknown_vel_ms=100\nwindow window_ms=0 min_samples=1 forget_ms=1\n"));
    cq::Pack ok = cq::parse_pack(kHead + "time_default s error_ms=5 state=coherent\r\n");
    CHECK(ok.time_default.count("s"));
    CHECK_EQ(std::string(cq::scope_name(cq::Scope::Source)), std::string("source"));
    CHECK_EQ(std::string(cq::action_name(cq::Action::Alert)), std::string("alert"));
}

TEST(quality, engine_samples_ticks_and_forgets) {
    cq::Engine e(cq::parse_pack(kHead + "rule old scope=source measure=age op=> limit=100 for=1 clear=50 action=alert\n"));
    Json a = support::report("s", "a", 1000, 0, 0);
    a["received_ms"] = 1100;
    a["speed_ms"] = 10;
    corr::Output o = e.ingest(a);
    CHECK_EQ(o.events.array[0].find("ev")->string, std::string("new"));
    CHECK_EQ(o.events.array[1].find("ev")->string, std::string("pass"));
    Json b = support::report("t", "b", 1500, 0, 0.001);
    e.ingest(b);
    Json a2 = a;
    a2["time_ms"] = 2000;
    a2["lat"] = 0.0001;
    corr::Output o2 = e.ingest(a2);
    bool nis = false, lateness = false;
    for (const Json& r : o2.trace.array) {
        nis = nis || r.find("sample")->string == "nis";
        lateness = lateness || r.find("sample")->string == "lateness";
    }
    CHECK(nis && lateness);
    corr::Output dup = e.ingest(a2);
    CHECK_EQ(dup.trace.array[0].find("value")->string, std::string("duplicate"));
    corr::Output t = e.tick(3000);
    CHECK_EQ(t.events.array.size(), size_t{6});   // 2 entity and 2 source quality events, 2 action-starts
    corr::Output back = e.tick(2000);
    CHECK_EQ(back.events.array[0].find("reason")->string, std::string("tick-out-of-order"));
    corr::Output gone = e.tick(100000);
    size_t forgets = 0;
    for (const Json& ev : gone.events.array) forgets += ev.find("ev")->string == "forget";
    CHECK_EQ(forgets, size_t{4});
    CHECK(e.snapshot().find("entities")->object.empty());
    CHECK_EQ(e.ingest(Json::make_object()).events.array[0].find("reason")->string,
             std::string("missing:track.source_id"));
}
