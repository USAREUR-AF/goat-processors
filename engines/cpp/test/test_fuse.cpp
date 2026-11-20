// Unit tests of src/fuse: pack, kinematics, attributes, engine.
#include <cmath>
#include <string>

#include "check.hpp"
#include "fuse/attributes.hpp"
#include "fuse/engine.hpp"
#include "fuse/kinematics.hpp"
#include "fuse/pack.hpp"
#include "support.hpp"

using corr::Json;
namespace cfu = corr::fuse;

namespace {

const std::string kHead =
    "pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nstale_ms 5000\n";

cfu::Entity member(const std::string& key, const std::string& source, std::int64_t t, double p, double pp,
                   Json report = Json::make_object()) {
    cfu::Entity e;
    e.key = key;
    e.source = source;
    e.last_time_ms = t;
    e.filter.east = {p, 1, pp, 0, 4};
    e.filter.north = {p, 1, pp, 0, 4};
    e.report = std::move(report);
    return e;
}

} // namespace

TEST(fuse, pack_parses_and_refuses) {
    cfu::Pack p = cfu::parse_pack(kHead + "kinematics best\nattribute callsign rule=majority\nsource radar\n"
                                          "source adsb\n");
    CHECK(p.kinematics == cfu::Method::Best && p.attributes.size() == 1 && p.sources.size() == 2);
    for (const char* name : {"inverse_variance", "covariance_intersection", "best", "priority", "latest"})
        CHECK_EQ(std::string(cfu::method_name(cfu::parse_pack(kHead + "kinematics " + name + "\n").kinematics)),
                 std::string(name));
    for (const char* rule : {"priority", "latest", "majority", "max", "min"})
        CHECK_EQ(std::string(cfu::rule_name(
                     cfu::parse_pack(kHead + "kinematics best\nattribute k rule=" + rule + "\n").attributes[0].rule)),
                 std::string(rule));
    for (const char* bad : {"kinematics fastest\n", "kinematics best\nkinematics best\n",
                            "kinematics best\nattribute k rule=avg\n", "kinematics best\nattribute k=1 rule=max\n",
                            "kinematics best\nattribute k max\n", "kinematics best\nattribute k rule=max\nattribute k rule=min\n",
                            "kinematics best\nsource a\nsource a\n", "kinematics best\nnoise 1\n",
                            "kinematics best\nstale_ms 1\n", "kinematics best\nsource\n"})
        CHECK_THROWS(corr::PackError, cfu::parse_pack(kHead + bad));
    CHECK_THROWS(corr::PackError, cfu::parse_pack("pack p\nversion 1\nkinematics best\nstale_ms 1\n"));
    CHECK_THROWS(corr::PackError,
                 cfu::parse_pack("pack p\nversion 1\nfilter accel_var=1 default_ce_m=0 vel_sigma_ms=5 "
                                 "unknown_vel_ms=100\nkinematics best\nstale_ms 1\n"));
    CHECK_THROWS(corr::PackError,
                 cfu::parse_pack("pack p\nversion 1\nfilter accel_var=1 default_ce_m=1e2.5 vel_sigma_ms=5 "
                                 "unknown_vel_ms=100\nkinematics best\nstale_ms 1\n"));
    CHECK_THROWS(corr::PackError, cfu::parse_pack(kHead + "kinematics best\nstale_ms 99999999999999999999\n"));
}

TEST(fuse, kinematics_methods) {
    cfu::Entity a = member("r/a", "radar", 100, 0, 4), b = member("x/b", "adsb", 200, 10, 1);
    cfu::Group g{std::string("G"), {&a, &b}};
    std::vector<cfu::Predicted> ms = {{&a, a.filter}, {&b, b.filter}};
    std::vector<std::string> sources = {"adsb", "radar"};
    corr::Output out;
    cfu::Kinematics iv = cfu::combine(cfu::Method::InverseVariance, g, ms, sources, out);
    CHECK_EQ(iv.f.east.p, 8.0);
    CHECK(iv.from == nullptr);
    CHECK(cfu::combine(cfu::Method::Best, g, ms, sources, out).from == &b);
    CHECK(cfu::combine(cfu::Method::Priority, g, ms, sources, out).from == &b);
    CHECK(cfu::combine(cfu::Method::Latest, g, ms, sources, out).from == &b);
    cfu::Kinematics ci = cfu::combine(cfu::Method::CovarianceIntersection, g, ms, sources, out);
    CHECK_EQ(out.trace.array.size(), size_t{1});
    CHECK(ci.f.east.pp <= 4);
    std::vector<cfu::Predicted> one = {{&a, a.filter}};
    CHECK_EQ(cfu::combine(cfu::Method::InverseVariance, g, one, sources, out).f.east.p, 0.0);
    CHECK_EQ(cfu::rank(sources, "radar").value(), std::int64_t{1});
    CHECK_EQ(cfu::rank_order(sources, "other"), std::int64_t{2});
}

TEST(fuse, attribute_rules) {
    Json ra = Json::make_object(), rb = Json::make_object(), rc = Json::make_object();
    ra["k"] = 1;
    rb["k"] = 1.0;
    rc["k"] = 3;
    ra["s"] = "x";
    rc["s"] = true;
    cfu::Entity a = member("a", "s1", 300, 0, 1, ra), b = member("b", "s2", 200, 0, 1, rb),
                c = member("c", "s3", 100, 0, 1, rc);
    cfu::Group g{std::nullopt, {&a, &b, &c}};
    std::vector<std::string> sources = {"s3", "s2"};
    auto decide = [&](cfu::Rule rule, const char* key) {
        Json attrs = Json::make_object();
        corr::Output out;
        cfu::decide_attribute(g, {key, rule}, sources, attrs, out);
        const Json* v = attrs.find(key);
        return v ? v->find("from")->string : std::string("-");
    };
    CHECK_EQ(decide(cfu::Rule::Majority, "k"), std::string("a"));   // 1 and 1.0 are equal
    CHECK_EQ(decide(cfu::Rule::Max, "k"), std::string("c"));
    CHECK_EQ(decide(cfu::Rule::Min, "k"), std::string("a"));
    CHECK_EQ(decide(cfu::Rule::Latest, "k"), std::string("a"));
    CHECK_EQ(decide(cfu::Rule::Priority, "k"), std::string("c"));
    CHECK_EQ(decide(cfu::Rule::Max, "s"), std::string("-"));        // no number
    CHECK_EQ(decide(cfu::Rule::Majority, "s"), std::string("a"));   // a tie goes to the first holder
    CHECK_EQ(decide(cfu::Rule::Latest, "none"), std::string("-"));
}

TEST(fuse, engine_groups_moves_and_drops) {
    cfu::Engine e(cfu::parse_pack(kHead + "kinematics inverse_variance\nattribute hae rule=max\n"));
    Json a = support::report("s", "a", 0, 0, 0);
    a["fuse.group"] = "G";
    a["hae"] = 10;
    Json b = support::report("t", "b", 0, 0.0001, 0);
    b["fuse.group"] = "G";
    b["ce"] = -1;   // absent: normalized away
    e.ingest(a);
    corr::Output nb = e.ingest(b);
    CHECK_EQ(nb.events.array[0].find("group")->string, std::string("G"));
    corr::Output t = e.tick(1000);
    CHECK_EQ(t.events.array.size(), size_t{1});
    CHECK_EQ(t.events.array[0].find("members")->array.size(), size_t{2});
    CHECK_EQ(t.events.array[0].find("hae")->number, 10.0);
    Json old = b;
    old["time_ms"] = -1;
    CHECK_EQ(e.ingest(old).events.array[0].find("ev")->string, std::string("stale-report"));
    Json moved = b;
    moved["time_ms"] = 500;
    moved["fuse.group"] = "";
    CHECK_EQ(e.ingest(moved).events.array[0].find("ev")->string, std::string("move"));
    CHECK(!e.snapshot().find("entities")->find("t/b")->find("report")->has("ce"));
    CHECK_EQ(e.ingest(Json::make_object()).events.array[0].find("ev")->string, std::string("reject"));
    corr::Output dropped = e.tick(100000);
    CHECK_EQ(dropped.events.array.size(), size_t{2});
}
