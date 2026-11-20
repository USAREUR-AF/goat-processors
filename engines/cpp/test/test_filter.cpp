// Unit tests of src/filter: geometry, conditions, pack, engine.
#include <cmath>
#include <string>

#include "check.hpp"
#include "filter/conditions.hpp"
#include "filter/engine.hpp"
#include "filter/geometry.hpp"
#include "filter/pack.hpp"
#include "support.hpp"

using corr::Json;
namespace cf = corr::filter;

namespace {

const char* kHead = "pack p\nversion 1\ndefault keep\nforget_ms 1000\n";

cf::Condition when(const std::string& line) {
    cf::Pack p = cf::parse_pack(std::string(kHead) + "rule r drop\nwhen " + line + "\n");
    return p.rules[0].when[0];
}

cf::Evaluation eval(const std::string& line, const Json& r, const cf::EntityState* own = nullptr,
                    const std::map<std::string, cf::EntityState>& entities = {}) {
    return cf::evaluate(when(line), r, own, entities);
}

} // namespace

TEST(filter, geometry_wrap_distance_polygon) {
    CHECK_EQ(cf::wrap(190), -170.0);
    CHECK_EQ(cf::wrap(-180), 180.0);
    CHECK(std::isnan(cf::wrap(NAN)));
    CHECK(std::abs(cf::wrap(1e9 + 10) - std::fmod(1e9 + 10, 360.0)) < 1e-6 || cf::wrap(1e9 + 10) <= 180);
    CHECK_EQ(cf::distance(0, 0, 0, 0), 0.0);
    double quarter = cf::distance(0, 0, 0, 90);
    CHECK(std::abs(quarter - 6371008.8 * 3.141592653589793 / 2) < 1e-6);
    std::vector<std::pair<double, double>> square = {{0, 0}, {0, 2}, {2, 2}, {2, 0}};
    CHECK_EQ(std::string(cf::polygon_test(square, 1, 1)), std::string("inside"));
    CHECK_EQ(std::string(cf::polygon_test(square, 3, 1)), std::string("outside"));
    CHECK_EQ(std::string(cf::polygon_test(square, 0, 1)), std::string("boundary"));
    CHECK_EQ(std::string(cf::polygon_test(square, 2, 2)), std::string("boundary"));
    std::vector<std::pair<double, double>> across = {{0, 179}, {0, -179}, {2, -179}, {2, 179}};
    CHECK_EQ(std::string(cf::polygon_test(across, 1, 180)), std::string("inside"));
}

TEST(filter, geometry_predict) {
    cf::Fix f;
    f.time_ms = 0;
    f.lat = 0;
    f.lon = 0;
    auto still = cf::predict(f, 5000);
    CHECK_EQ(still.first, 0.0);
    f.course = 90;
    f.speed_ms = 100;
    auto east = cf::predict(f, 10000);
    CHECK(std::abs(east.first) < 1e-9 && east.second > 0.008 && east.second < 0.01);
}

TEST(filter, conditions_rows) {
    Json r = support::report("radar", "T1", 1000, 1, 1);
    r["type"] = "a-h-A-M";
    r["speed_ms"] = 50;
    r["hae"] = 100;
    r["flag"] = true;
    r["n"] = 1;
    CHECK(eval("circle lat=1 lon=1 radius_m=10", r).result == cf::Result::True);
    CHECK(eval("polygon vertices=0,0;0,2;2,2;2,0", r).result == cf::Result::True);
    CHECK(eval("env in=A,S", r).result == cf::Result::True);
    CHECK(eval("affiliation in=f", r).result == cf::Result::False);
    CHECK(eval("source in=radar", r).result == cf::Result::True);
    CHECK(eval("uid in=T2", r).result == cf::Result::False);
    CHECK(eval("key name=n eq=1.00", r).result == cf::Result::True);
    CHECK(eval("key name=flag eq=true", r).result == cf::Result::True);
    CHECK(eval("key name=n in=2,1", r).result == cf::Result::True);
    CHECK(eval("key name=n min=2", r).result == cf::Result::False);
    CHECK(eval("key name=missing eq=1", r).result == cf::Result::Unknown);
    CHECK(eval("key name=flag min=0", r).result == cf::Result::Unknown);
    CHECK(eval("has name=hae", r).result == cf::Result::True);
    CHECK(eval("speed min=10 max=60", r).result == cf::Result::True);
    CHECK(eval("altitude max=50", r).result == cf::Result::False);
    Json bare = support::report("radar", "T1", 1000, 1, 1);
    CHECK(eval("env in=A", bare).result == cf::Result::Unknown);
    CHECK(eval("affiliation in=h", bare).result == cf::Result::Unknown);
    CHECK(eval("speed min=1", bare).result == cf::Result::Unknown);
    Json obj = bare;
    obj["k"] = Json::make_array();
    CHECK(eval("key name=k eq=1", obj).result == cf::Result::False);
}

TEST(filter, conditions_state) {
    Json r = support::report("radar", "T1", 1000, 1, 1);
    cf::EntityState own;
    CHECK(eval("interval min_ms=500", r, &own).result == cf::Result::False);   // no kept report
    CHECK(eval("order", r, &own).limit.is_null());
    own.kept_ms = 800;
    CHECK(eval("interval min_ms=500", r, &own).result == cf::Result::True);
    CHECK(eval("order", r, &own).result == cf::Result::False);
    std::map<std::string, cf::EntityState> entities;
    CHECK(eval("near reference=adsb/X radius_m=100 max_age_ms=100", r, nullptr, entities).result ==
          cf::Result::Unknown);
    cf::EntityState ref;
    ref.time_ms = 950;
    ref.lat = 1;
    ref.lon = 1;
    entities["adsb/X"] = ref;
    CHECK(eval("near reference=adsb/X radius_m=100 max_age_ms=100", r, nullptr, entities).result ==
          cf::Result::True);
    CHECK(eval("near reference=adsb/X radius_m=100 max_age_ms=10", r, nullptr, entities).result ==
          cf::Result::Unknown);
    entities["adsb/X"].stale_ms = 1000;
    CHECK(eval("near reference=adsb/X radius_m=100 max_age_ms=100", r, nullptr, entities).result ==
          cf::Result::Unknown);
}

TEST(filter, pack_values_and_errors) {
    CHECK(cf::is_pack_number("-1.5") && cf::is_pack_number("0") && !cf::is_pack_number("1.") &&
          !cf::is_pack_number("+1") && !cf::is_pack_number("1e3") && !cf::is_pack_number(""));
    cf::Pack p = cf::parse_pack(std::string("rule r keep\nwhen not circle lat=1 lon=2 radius_m=3\r\n") + kHead);
    CHECK(p.default_keep && p.forget_ms == 1000 && p.rules.size() == 1 && p.rules[0].when[0].negated);
    for (const char* bad :
         {"rule r keep\n", "when order\n", "rule default keep\n", "rule r keep\nwhen order\nrule r drop\nwhen order\n",
          "rule r maybe\n", "rule r\n", "pack q\n", "frobnicate 1\n", "rule r keep\nwhen\n",
          "rule r keep\nwhen not\n", "rule r keep\nwhen spin\n", "rule r keep\nwhen order x=1\n",
          "rule r keep\nwhen circle lat=1 lon=2\n", "rule r keep\nwhen circle lat=91 lon=2 radius_m=1\n",
          "rule r keep\nwhen circle lat=1 lon=181 radius_m=1\n", "rule r keep\nwhen circle lat=1 lon=1 radius_m=-1\n",
          "rule r keep\nwhen polygon vertices=0,0;1,1\n", "rule r keep\nwhen polygon vertices=0,0;1;2,2\n",
          "rule r keep\nwhen env in=a,,b\n", "rule r keep\nwhen key name= eq=1\n",
          "rule r keep\nwhen key name=a min=2 max=1\n", "rule r keep\nwhen interval min_ms=0\n",
          "rule r keep\nwhen near reference=x radius_m=1 max_age_ms=99999999999999999999\n",
          "rule r keep\nwhen near reference=x radius_m=1 max_age_ms=-1\n",
          "rule r keep\nwhen speed min=1 min=2\n", "rule r keep\nwhen speed nomatch\n"}) {
        CHECK_THROWS(corr::PackError, cf::parse_pack(std::string(kHead) + bad));
    }
    CHECK_THROWS(corr::PackError, cf::parse_pack("pack p\nversion 1\ndefault keep\n"));
    CHECK_THROWS(corr::PackError, cf::parse_pack("pack p\nversion 1\ndefault keep\nforget_ms 0\n"));
    CHECK_THROWS(corr::PackError, cf::parse_pack(std::string(kHead) + "default drop\n"));
    CHECK_THROWS(corr::PackError, cf::load_pack("/nonexistent"));
}

TEST(filter, engine_keeps_drops_and_forgets) {
    cf::Engine e(cf::parse_pack(std::string(kHead) + "rule fast drop\nwhen speed min=100\n"));
    Json slow = support::report("s", "a", 1000, 0, 0);
    slow["speed_ms"] = 10;
    Json fast = support::report("s", "b", 1000, 0, 0);
    fast["speed_ms"] = 200;
    corr::Output o1 = e.ingest(slow), o2 = e.ingest(fast);
    CHECK_EQ(o1.events.array[0].find("ev")->string, std::string("keep"));
    CHECK_EQ(o1.events.array[0].find("rule")->string, std::string("default"));
    CHECK_EQ(o2.events.array[0].find("ev")->string, std::string("drop"));
    CHECK_EQ(o2.events.array[0].find("rule")->string, std::string("fast"));
    Json older = slow;
    older["time_ms"] = 500;
    e.ingest(older);   // older: changes neither time nor position
    CHECK_EQ(e.snapshot().find("entities")->find("s/a")->find("time_ms")->integer, std::int64_t{1000});
    Json missing = Json::make_object();
    CHECK_EQ(e.ingest(missing).events.array[0].find("reason")->string, std::string("missing:track.source_id"));
    corr::Output t = e.tick(2001);
    CHECK_EQ(t.events.array.size(), size_t{2});
    CHECK(e.snapshot().find("entities")->object.empty());
}
