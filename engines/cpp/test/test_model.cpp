// Unit tests of src/model: the JSON value, reports, frame, track estimate,
// pack.def text helpers.
#include <cmath>
#include <limits>
#include <map>
#include <string>

#include "check.hpp"
#include "model/estimate.hpp"
#include "model/frame.hpp"
#include "model/json.hpp"
#include "model/pack_text.hpp"
#include "model/report.hpp"
#include "support.hpp"

using corr::Json;

// ---- json -------------------------------------------------------------------

TEST(model, json_round_trip_keeps_kinds) {
    Json v = corr::parse_json(R"({"b":[1,2.5,-3e2,true,false,null],"a":"x\"y\\z","c":{}})");
    CHECK(v.is_object());
    CHECK_EQ(corr::to_json(v), std::string(R"({"a":"x\"y\\z","b":[1,2.5,-300,true,false,null],"c":{}})"));
    const Json* b = v.find("b");
    CHECK(b->array[0].is_int);
    CHECK(!b->array[1].is_int);
    CHECK(!b->array[2].is_int);
}

TEST(model, json_numbers) {
    CHECK_EQ(corr::parse_json("9223372036854775807").integer, std::int64_t{9223372036854775807LL});
    Json big = corr::parse_json("9223372036854775808");   // outside int64: a number, not an integer
    CHECK(big.is_number() && !big.is_int);
    CHECK_EQ(corr::to_json(Json(0.1)), std::string("0.10000000000000001"));
    CHECK_EQ(corr::to_json(Json(-7)), std::string("-7"));
}

TEST(model, json_strings_and_escapes) {
    Json s = corr::parse_json(R"("\u00e9\ud83d\ude00\n\t\/\b\f\r")");
    CHECK_EQ(s.string, std::string("\xc3\xa9\xf0\x9f\x98\x80\n\t/\b\f\r"));
    CHECK_EQ(corr::to_json(Json(std::string("\x01"))), std::string("\"\\u0001\""));
    CHECK_EQ(corr::parse_json("\"\\u0041\"").string, std::string("A"));
    CHECK_EQ(corr::parse_json("\"\\u07ff\"").string, std::string("\xdf\xbf"));
}

TEST(model, json_errors) {
    for (const char* bad : {"", "{", "[1,", "{\"a\" 1}", "tru", "nul", "\"abc", "\"\\x\"", "\"\\u12\"", "1 2",
                            "-", "1.2.3", "@", "{\"a\":1,}", "\"\\uzzzz\""})
        CHECK_THROWS(corr::JsonError, corr::parse_json(bad));
}

TEST(model, json_equal_and_access) {
    CHECK(corr::json_equal(corr::parse_json("1"), corr::parse_json("1.0")));
    CHECK(!corr::json_equal(corr::parse_json("1"), corr::parse_json("\"1\"")));
    CHECK(corr::json_equal(corr::parse_json("{\"a\":[1,{}]}"), corr::parse_json("{\"a\":[1,{}]}")));
    CHECK(!corr::json_equal(corr::parse_json("{\"a\":1}"), corr::parse_json("{\"b\":1}")));
    CHECK(!corr::json_equal(corr::parse_json("[1]"), corr::parse_json("[1,2]")));
    CHECK(!corr::json_equal(corr::parse_json("[1]"), corr::parse_json("[2]")));
    CHECK(corr::json_equal(Json(), Json()));
    CHECK(!corr::json_equal(Json(true), Json(false)));
    CHECK(!corr::json_equal(Json("a"), Json("b")));
    Json o;
    o["k"] = 1;
    CHECK(o.is_object() && o.has("k") && !o.has("j") && o.find("j") == nullptr);
    Json a;
    a.push(1);
    CHECK(a.is_array() && a.find("k") == nullptr && !a.has("k"));
}

// ---- report -----------------------------------------------------------------

TEST(model, report_required_keys_in_table_order) {
    Json r = support::report("s", "u", 5, 1, 2);
    CHECK(!corr::report::missing_required(r));
    Json no_uid = r;
    no_uid.object.erase("uid");
    CHECK_EQ(*corr::report::missing_required(no_uid), std::string("uid"));
    Json float_time = r;
    float_time["time_ms"] = 5.5;
    CHECK_EQ(*corr::report::missing_required(float_time), std::string("time_ms"));
    Json empty = Json::make_object();
    CHECK_EQ(*corr::report::missing_required(empty), std::string("track.source_id"));
    Json str_lat = r;
    str_lat["lat"] = "1";
    CHECK_EQ(*corr::report::missing_required(str_lat), std::string("lat"));
}

TEST(model, report_optional_keys) {
    Json r = support::report("s", "u", 5, 1, 2);
    r["ce"] = 0;
    r["hae"] = "high";
    r["type"] = "a-f-A--x";
    r["stale_ms"] = 1.5;
    r["speed_ms"] = 3;
    r["other"] = Json();
    CHECK(!corr::report::ce_at(r));
    CHECK(!corr::report::present(r, "ce"));
    CHECK(!corr::report::present(r, "hae"));
    CHECK(!corr::report::present(r, "stale_ms"));
    CHECK(!corr::report::present(r, "other"));
    CHECK(corr::report::present(r, "speed_ms"));
    CHECK(!corr::report::stale_ms_at(r));
    CHECK_EQ(*corr::report::type_element(r, 0), std::string("a"));
    CHECK_EQ(*corr::report::type_element(r, 3), std::string(""));
    CHECK(!corr::report::type_element(r, 5));
    r["ce"] = 12.5;
    CHECK_EQ(*corr::report::ce_at(r), 12.5);
    r["stale_ms"] = 9;
    CHECK_EQ(*corr::report::stale_ms_at(r), std::int64_t{9});
}

TEST(model, report_time_quality_steps) {
    std::map<std::string, corr::TimeDefault> defaults;
    defaults["s"] = {40.0, std::string("drifting")};
    Json r = support::report("s", "u", 5, 1, 2);
    auto tq = corr::report::time_quality(r, "s", defaults);
    CHECK_EQ(*tq.error_ms(), 40.0);
    CHECK_EQ(*tq.state(), std::string("drifting"));
    r["time_error_ms"] = 5;
    r["time_state"] = "coherent";
    tq = corr::report::time_quality(r, "s", defaults);
    CHECK_EQ(*tq.error_ms(), 5.0);
    CHECK_EQ(*tq.state(), std::string("coherent"));
    r["time_error_ms"] = -1;
    r["time_state"] = "Coherent";
    CHECK(!corr::report::time_error_at(r));
    CHECK(!corr::report::time_state_at(r));
    tq = corr::report::time_quality(r, "other", defaults);
    CHECK(!tq.error_ms() && !tq.state());
}

// ---- frame ------------------------------------------------------------------

TEST(model, frame_wrap_and_round_trip) {
    CHECK_EQ(corr::wrap180(180.0), 180.0);
    CHECK_EQ(corr::wrap180(-180.0), 180.0);
    CHECK_EQ(corr::wrap180(540.0), 180.0);
    CHECK_EQ(corr::wrap180(-190.0), 170.0);
    corr::Point p = corr::to_plane(10, 20, 10.01, 20.02);
    CHECK(p.east > 0 && p.north > 0);
    auto back = corr::to_degrees(10, 20, p.east, p.north);
    CHECK(std::abs(back.first - 10.01) < 1e-9 && std::abs(back.second - 20.02) < 1e-9);
    corr::Point across = corr::to_plane(0, 179.9, 0, -179.9);   // the antimeridian
    CHECK(across.east > 0 && across.east < 30000);
    CHECK_EQ(corr::course_of(0, 1), 0.0);
    CHECK_EQ(corr::course_of(1, 0), 90.0);
    CHECK_EQ(corr::course_of(-1, 0), 270.0);
}

// ---- estimate ---------------------------------------------------------------

TEST(model, estimate_predict_is_pure_and_exact) {
    const corr::Axis a{10, 2, 4, 1, 3};
    corr::Axis p = corr::axis_predict(a, 2, 0.5);
    CHECK_EQ(a.p, 10.0);   // the argument is unchanged
    CHECK_EQ(p.p, 14.0);
    CHECK_EQ(p.v, 2.0);
    CHECK_EQ(p.pp, 4 + 2 * 2 * 1 + 4 * 3 + 0.5 * 16 / 4);
    CHECK_EQ(p.pv, 1 + 2 * 3 + 0.5 * 8 / 2);
    CHECK_EQ(p.vv, 3 + 0.5 * 4);
    corr::Axis back = corr::axis_predict(corr::axis_predict(a, 0, 0), 0, 7);
    CHECK_EQ(back.pp, a.pp);
}

TEST(model, estimate_updates) {
    const corr::Axis a{0, 0, 4, 0, 1};
    corr::AxisUpdate u = corr::axis_position_update(a, 2, 4);
    CHECK_EQ(u.axis.p, 1.0);       // k1 = 0.5
    CHECK_EQ(u.axis.pp, 2.0);
    CHECK_EQ(u.term, 4.0 / 8 + std::log(8.0));
    corr::AxisUpdate w = corr::axis_velocity_update(a, 3, 1);
    CHECK_EQ(w.axis.v, 1.5);
    CHECK_EQ(w.axis.vv, 0.5);
    corr::FilterParams fp{1, 50, 5, 100};
    corr::Filter f = corr::filter_first(fp, {1, 2}, std::nullopt, 10);
    CHECK_EQ(f.east.pp, 100.0);
    CHECK_EQ(f.east.vv, 10000.0);
    corr::Filter g = corr::filter_first(fp, {1, 2}, corr::Point{3, 4}, 10);
    CHECK_EQ(g.north.v, 4.0);
    CHECK_EQ(g.north.vv, 25.0);
    corr::Filter up = corr::filter_update(g, fp, {2, 3}, corr::Point{3, 4}, 10, 1);
    corr::Filter by_parts = corr::filter_correct(corr::filter_predict(g, 1, 1), fp, {2, 3}, corr::Point{3, 4}, 10);
    CHECK(corr::to_json(Json(up.east.p)) == corr::to_json(Json(by_parts.east.p)));
    CHECK_EQ(corr::filter_predict(g, 1000, 3000, 1).east.p, corr::filter_predict(g, 2, 1).east.p);
}

TEST(model, measured_velocity_needs_both_keys) {
    Json r = support::report("s", "u", 0, 0, 0);
    CHECK(!corr::measured_velocity(r));
    r["course"] = 90;
    CHECK(!corr::measured_velocity(r));
    r["speed_ms"] = 10;
    auto v = corr::measured_velocity(r);
    CHECK(std::abs(v->east - 10) < 1e-12 && std::abs(v->north) < 1e-9);
}

// ---- pack_text --------------------------------------------------------------

TEST(model, pack_text_time_default) {
    std::map<std::string, corr::TimeDefault> into;
    auto num = [](const std::string& s) { return std::stod(s); };
    corr::parse_time_default(1, {"time_default", "a", "error_ms=5", "state=drifting"}, num, into);
    CHECK_EQ(*into["a"].error_ms, 5.0);
    for (std::vector<std::string> bad : std::vector<std::vector<std::string>>{
             {"time_default"},
             {"time_default", "x=1"},
             {"time_default", "a"},
             {"time_default", "b", "error_ms=1", "error_ms=2"},
             {"time_default", "b", "state=coherent", "state=coherent"},
             {"time_default", "b", "error_ms=-1"},
             {"time_default", "b", "state=late"},
             {"time_default", "b", "colour=red"},
             {"time_default", "b", "=1"},
             {"time_default", "a", "error_ms=1"}})
        CHECK_THROWS(corr::PackError, corr::parse_time_default(2, bad, num, into));
    CHECK_THROWS(corr::PackError, corr::read_pack_def("/nonexistent/dir"));
    std::string msg;
    try {
        corr::pack_fail(7, "x");
    } catch (const corr::PackError& e) {
        msg = e.what();
    }
    CHECK_EQ(msg, std::string("pack.def line 7: x"));
}
