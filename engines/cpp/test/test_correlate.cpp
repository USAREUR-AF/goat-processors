// Unit tests of src/correlate: the motion math, the test kinds, the pack,
// the method table and the engine.
#include <cmath>
#include <limits>
#include <string>

#include "check.hpp"
#include "correlate/engine.hpp"
#include "correlate/method.hpp"
#include "correlate/motion.hpp"
#include "correlate/pack.hpp"
#include "correlate/tests.hpp"
#include "support.hpp"

using corr::Json;
namespace cc = corr::correlate;

namespace {

const std::string kConfirm =
    "pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
    "confirm_count 1\nhold_failures 1\nstale_ms 10000\n";
const std::string kAssign =
    "pack p\nversion 1\nmethod assign\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
    "new_cost 9.21\nkeep_bonus 2\nstale_ms 10000\n";

cc::Entity entity(const std::string& key, double e, double n, Json last = Json::make_object()) {
    cc::Entity x;
    x.key = key;
    x.filter.east = {e, 0, 100, 0, 1};
    x.filter.north = {n, 0, 100, 0, 1};
    x.r = {100, 100};
    x.last = std::move(last);
    return x;
}

cc::TestResult run(const std::string& line, const cc::Entity& a, const cc::Entity& b) {
    cc::Pack p = cc::parse_pack(kConfirm + "gate " + line + "\n");
    const cc::TestSpec& t = p.gate[0];
    return t.run(t, {a, b, b.filter, p.filter.default_ce_m});
}

} // namespace

TEST(correlate, motion_one_model) {
    cc::Motion m{{1, 50, 5, 100}, std::nullopt};
    cc::Track t = cc::first_track(m, {0, 0}, std::nullopt, {100, 100});
    CHECK_EQ(t.filter.east.pp, 100.0);
    CHECK_EQ(t.filter.east.vv, 10000.0);
    cc::TrackUpdate u = cc::update_track(t, m, {10, 0}, std::nullopt, {100, 100}, 1);
    CHECK(u.track.filter.east.p > 0 && u.track.filter.east.p < 10);
    CHECK_EQ(cc::predict(t, m, 0).east.pp, 100.0);
}

TEST(correlate, motion_two_models) {
    cc::Motion m{{1, 50, 5, 100}, cc::ManeuverParams{100, 0.1, 0.2}};
    cc::Track t = cc::first_track(m, {0, 0}, corr::Point{10, 0}, {100, 100});
    CHECK(std::abs(t.mu[0] - 0.2 / 0.3) < 1e-15 && std::abs(t.mu[1] - 0.1 / 0.3) < 1e-15);
    cc::TrackUpdate u = cc::update_track(t, m, {10, 30}, corr::Point{10, 5}, {100, 100}, 1);
    CHECK(std::abs(u.track.mu[0] + u.track.mu[1] - 1) < 1e-12);
    CHECK(u.lambda[0] != 0 && u.lambda[1] != 0);
    corr::Filter b = cc::blend(1, 0, t.models[0], t.models[1]);
    CHECK_EQ(b.east.p, t.models[0].east.p);
    CHECK(cc::predict(u.track, m, 2).east.pp > u.track.filter.east.pp);
}

TEST(correlate, measurement_variance_and_d2) {
    cc::MeasurementVariance mv = cc::measurement_variance(10, 0, {50, 50});
    CHECK_EQ(mv.r.east, 100.0);
    CHECK_EQ(mv.timing.north, 0.0);
    mv = cc::measurement_variance(10, 200, {50, 0});
    CHECK_EQ(mv.timing.east, 100.0);   // (50 * 0.2)²
    CHECK_EQ(mv.r.east, 200.0);
    CHECK_EQ(mv.r.north, 100.0);
    corr::Filter f;
    f.east = {3, 0, 1, 0, 1};
    f.north = {4, 0, 1, 0, 1};
    CHECK_EQ(cc::d2({0, 0}, {1, 1}, f), 9.0 / 2 + 16.0 / 2);
    CHECK_EQ(cc::for_comparison(f, {2, 3}).north.pp, 4.0);
}

TEST(correlate, test_kinds) {
    Json la = Json::make_object(), lb = Json::make_object();
    la["course"] = 10;
    la["speed_ms"] = 100;
    la["hae"] = 1000;
    la["type"] = "a-f-A";
    lb["course"] = 350;
    lb["speed_ms"] = 50;
    lb["hae"] = 1200;
    lb["type"] = "a-f-A";
    cc::Entity a = entity("s/a", 0, 0, la), b = entity("t/b", 30, 40, lb);
    CHECK_EQ(run("distance max_m=60", a, b).value.number, 50.0);
    CHECK(!run("distance max_m=50", a, b).pass);
    CHECK(run("mahalanobis gate=100", a, b).pass);
    CHECK_EQ(run("course max_deg=20 min_speed_ms=5", a, b).value.number, 20.0);
    CHECK(run("course max_deg=20 min_speed_ms=60", a, b).skipped);
    CHECK_EQ(run("speed max_pct=60 min_speed_ms=5", a, b).value.number, 50.0);
    CHECK_EQ(run("altitude max_m=100", a, b).value.number, 200.0);
    CHECK(run("same key=@env", a, b).pass);
    CHECK(run("same key=nothing", a, b).pass);
    CHECK(!run("same key=course", a, b).pass);
    // state: q per axis with the velocity terms (both 0 here), 5 dof with heights.
    cc::TestResult st = run("state probability=0.99 hae_sigma_m=100", a, b);
    CHECK_EQ(st.value.number, 30.0 * 30 / 200.0 + 40.0 * 40 / 200.0 + 200.0 * 200 / (2 * 100.0 * 100));   // spp = 100 + 0 + 100
    CHECK_EQ(st.limit.number, 15.0863);
    CHECK_EQ(st.extra.find("dof")->integer, 5LL);
    CHECK(st.pass);
    cc::Entity bare = entity("t/c", 1, 1);
    CHECK(run("altitude max_m=1", a, bare).skipped);
    CHECK(run("speed max_pct=1 min_speed_ms=1", a, bare).skipped);
    cc::TestResult st4 = run("state probability=0.95 hae_sigma_m=100", a, bare);
    CHECK_EQ(st4.limit.number, 9.4877);
    CHECK_EQ(st4.extra.find("dof")->integer, 4LL);
}

TEST(correlate, state_axis_and_sprt_evidence) {
    corr::Axis a{10, 2, 4, 1, 3}, b{4, -1, 5, 2, 6};
    cc::StateAxis s = cc::state_axis(a, 1, b);
    CHECK_EQ(s.spp, 10.0);
    CHECK_EQ(s.spv, 3.0);
    CHECK_EQ(s.svv, 9.0);
    CHECK_EQ(s.det, 81.0);
    CHECK_EQ(s.q, (9.0 * 36 - 2 * 3.0 * 6 * 3 + 10.0 * 9) / 81);
    corr::Filter fa{a, a}, fb{b, b};
    cc::SprtParams sp{0.01, 0.01, 100, 10, 50};
    cc::SprtEvidence e = cc::sprt_evidence(fa, {1, 1}, fb, std::nullopt, 3.0, sp);
    CHECK_EQ(e.d2, s.q + s.q);
    cc::SprtEvidence h = cc::sprt_evidence(fa, {1, 1}, fb, 100.0, 0.0, sp);
    CHECK_EQ(h.d2, s.q + s.q + 100.0 * 100 / 5000);
    CHECK(h.increment != e.increment);
}

TEST(correlate, test_registry) {
    const cc::TestRegistry& r = cc::builtin_tests();
    for (const char* name : {"distance", "mahalanobis", "course", "speed", "altitude", "same", "state"})
        CHECK(r.find(name) && r.find(name)->run);
    CHECK(r.find("window") == nullptr);   // retired in correlate.md 1.0
    CHECK(r.find("state")->check != nullptr);
    CHECK(r.find("spin") == nullptr);
    cc::TestRegistry copy = r;
    copy.add({"distance", {"limit"}, false, nullptr});   // replaces
    CHECK_EQ(copy.find("distance")->params[0], std::string("limit"));
    CHECK_EQ(r.find("distance")->params[0], std::string("max_m"));
}

TEST(correlate, method_table) {
    CHECK_EQ(cc::methods().size(), size_t{2});
    CHECK_EQ(std::string(cc::methods()[0].name), std::string("confirm"));
    CHECK(cc::find_method("assign") && !cc::find_method("vote"));
}

TEST(correlate, pack_errors) {
    CHECK_EQ(cc::parse_pack(kConfirm).method, std::string("confirm"));
    CHECK_EQ(cc::parse_pack(kAssign).method, std::string("assign"));
    for (const char* extra :
         {"method vote\n", "gate\n", "gate spin\n", "gate distance\n", "gate distance max_m=x\n",
          "gate distance max_m=1 max_m=2\n", "gate distance size=1\n", "gate distance max_m\n", "gate same key=\n",
          "pack q\n", "colour red\n", "maneuver accel_var=0.5 p_enter=0.1 p_leave=0.1\n",
          "maneuver accel_var=5 p_enter=0.6 p_leave=0.5\n", "restart gate=0\n", "new_cost 1\n", "priority a\n",
          "priority a 1\npriority a 2\n", "same_source maybe\n", "output first\n", "confirm_count 1.5\n",
          "confirm_count +\n", "stale_ms 1 2\n", "time_default a error_ms=x\n",
          "gate window multiplier=1 window_m=900 err_min_m=100 err_max_m=5000\n",
          "gate state probability=0.9 hae_sigma_m=100\n", "gate state probability=0.99 hae_sigma_m=0\n",
          "stale_rate factor=5 floor_ms=1 ceiling_ms=2 samples=3\n", "sprt false=0.01 missed=0.01 pos_m=1 vel_ms=1 hae_sigma_m=1\n"})
        CHECK_THROWS(corr::PackError, cc::parse_pack(kConfirm + extra));
    // sprt replaces confirm_count, hold_failures and hold; stale_rate replaces stale_ms.
    const std::string base = "pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n";
    const std::string sprt = "sprt false=0.01 missed=0.02 pos_m=1 vel_ms=1 hae_sigma_m=1\n";
    const std::string rate = "stale_rate factor=5 floor_ms=1 ceiling_ms=2 samples=3\n";
    cc::Pack sp = cc::parse_pack(base + sprt + rate + "output latest\n");
    CHECK(sp.sprt && sp.sprt->missed == 0.02 && sp.stale_rate && sp.stale_rate->samples == 3);
    CHECK(sp.output == cc::OutputMode::latest);
    CHECK(cc::parse_pack(kConfirm).output == cc::OutputMode::fused);
    CHECK(cc::parse_pack(kConfirm + "output priority\n").output == cc::OutputMode::priority);
    CHECK(cc::parse_pack(kConfirm + "output fused\n").output == cc::OutputMode::fused);
    for (const std::string& text :
         {base + sprt + rate + "confirm_count 1\n", base + sprt + rate + "hold_failures 1\n",
          base + sprt + rate + "hold distance max_m=1\n", base + "confirm_count 1\nhold_failures 1\n",
          base + "confirm_count 1\n" + rate, base + sprt,
          base + "sprt false=0.5 missed=0.01 pos_m=1 vel_ms=1 hae_sigma_m=1\n" + rate,
          base + "sprt false=0.01 missed=0.01 pos_m=0 vel_ms=1 hae_sigma_m=1\n" + rate,
          base + sprt + "stale_rate factor=0 floor_ms=1 ceiling_ms=2 samples=3\n",
          base + sprt + "stale_rate factor=1 floor_ms=3 ceiling_ms=2 samples=3\n",
          base + sprt + "stale_rate factor=1 floor_ms=1 ceiling_ms=2 samples=0\n",
          base + sprt + "stale_rate factor=1 floor_ms=-1 ceiling_ms=2 samples=1\n"})
        CHECK_THROWS(corr::PackError, cc::parse_pack(text));
    for (const char* extra : {"window 0\n", "hypotheses 2\n", "window 2\nmargin 1\n", "margin 0\n",
                              "time_offset sigma_ms=10\n", "bias sigma_m=1 floor_m=2 gate=1\n",
                              "bias sigma_m=0 floor_m=0 gate=1\n", "time_offset sigma_ms=0\n", "keep_bonus -1\n",
                              "new_cost 0\n", "hold_failures 1\n", "window x\n",
                              "sprt false=0.01 missed=0.01 pos_m=1 vel_ms=1 hae_sigma_m=1\n",
                              "stale_rate factor=5 floor_ms=1 ceiling_ms=2 samples=3\n"})
        CHECK_THROWS(corr::PackError, cc::parse_pack(kAssign + extra));
    CHECK_THROWS(corr::PackError, cc::parse_pack("pack p\n"));
    cc::Pack ok = cc::parse_pack(kAssign + "window 2\nhypotheses 2\nmargin 1.5e0\nbias sigma_m=300 floor_m=10 gate=13.8\n"
                                           "time_offset sigma_ms=500\nrestart gate=20\n"
                                           "maneuver accel_var=5 p_enter=0.1 p_leave=0.2\n");
    CHECK(ok.margin && *ok.margin == 1.5 && ok.bias && ok.time_offset_sigma_ms && ok.restart_gate && ok.maneuver);
}

TEST(correlate, engine_confirm_groups_and_drops) {
    cc::Engine e(cc::parse_pack(kConfirm + "gate distance max_m=1000\n"));
    CHECK_EQ(e.ingest(support::report("s", "a", 0, 0, 0)).events.array[0].find("ev")->string, std::string("new"));
    corr::Output o = e.ingest(support::report("t", "b", 0, 0, 0.001));
    CHECK_EQ(o.events.array.size(), size_t{2});
    CHECK_EQ(o.events.array[1].find("ev")->string, std::string("correlate"));
    corr::Output r = e.ingest(support::report("t", "b", -5, 0, 0.001));
    CHECK_EQ(r.events.array[0].find("reason")->string, std::string("out-of-order"));
    corr::Output fused = e.tick(1000);
    CHECK_EQ(fused.events.array[0].find("ev")->string, std::string("fused"));
    corr::Output stale = e.tick(20000);
    CHECK_EQ(stale.events.array.size(), size_t{4});   // leave, dissolve, drop, drop
    CHECK(e.snapshot().find("entities")->object.empty());
}

TEST(correlate, engine_assign_starts_systems_at_tick) {
    cc::Engine e(cc::parse_pack(kAssign));
    e.ingest(support::report("s", "a", 0, 0, 0));
    e.ingest(support::report("t", "b", 0, 0, 0.0001));
    Json snap = e.snapshot();
    CHECK_EQ(snap.find("reported")->array.size(), size_t{2});
    corr::Output o = e.tick(0);
    bool system = false;
    for (const Json& ev : o.events.array) system = system || ev.find("ev")->string == "system";
    CHECK(system);
    CHECK(e.snapshot().find("reported")->array.empty());
}

TEST(correlate, engine_restart_and_time_record) {
    cc::Engine e(cc::parse_pack(kAssign + "restart gate=9\ntime_default s error_ms=100\n"));
    Json a = support::report("s", "a", 0, 0, 0);
    a["course"] = 90;
    a["speed_ms"] = 100;
    corr::Output first = e.ingest(a);
    CHECK_EQ(first.trace.array[0].find("test")->string, std::string("time"));
    Json far = support::report("s", "a", 1000, 1, 1);
    corr::Output o = e.ingest(far);
    bool restart = false;
    for (const Json& rec : o.trace.array)
        restart = restart || (rec.find("test")->string == "restart" && !rec.find("pass")->boolean);
    CHECK(restart);
    CHECK_EQ(e.snapshot().find("restarted")->array.size(), size_t{1});
}

TEST(correlate, engine_fused_output_modes) {
    // Two members, one 10 m north of the other with the same variance: the
    // fused output is midway; priority and latest give one member.
    const std::string g = "gate distance max_m=1000\n";
    for (const char* mode : {"", "output priority\npriority t 1\n", "output latest\n"}) {
        cc::Engine e(cc::parse_pack(kConfirm + g + mode));
        Json a = support::report("s", "a", 0, 0, 0);
        a["hae"] = 100;
        e.ingest(a);
        e.ingest(support::report("t", "b", 0, 0.0001, 0));
        corr::Output o = e.tick(0);
        const Json& ev = o.events.array[0];
        if (std::string(mode).empty()) {
            CHECK(ev.find("primary")->is_null());
            CHECK(std::abs(ev.find("lat")->number - 0.00005) < 1e-12);
            CHECK_EQ(ev.find("hae")->number, 100.0);
        } else {
            CHECK_EQ(ev.find("primary")->string, std::string(std::string(mode).find("latest") != std::string::npos
                                                                 ? "s/a" : "t/b"));
        }
    }
}

TEST(correlate, engine_sprt_confirms_and_releases) {
    const std::string pack =
        "pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
        "gate distance max_m=1000\ngate same key=k\n"
        "sprt false=0.01 missed=0.01 pos_m=10000 vel_ms=300 hae_sigma_m=100\n"
        "stale_rate factor=2 floor_ms=1000 ceiling_ms=10000 samples=2\n";
    cc::Engine e(cc::parse_pack(pack));
    Json a = support::report("s", "a", 0, 0, 0), b = support::report("t", "b", 0, 0, 0.0001);
    a["k"] = 1;
    b["k"] = 1;
    e.ingest(a);
    corr::Output o = e.ingest(b);
    CHECK_EQ(o.events.array.back().find("ev")->string, std::string("correlate"));
    CHECK_EQ(e.snapshot().find("llr")->object.size(), size_t{1});
    // A report whose `same` key differs forces the link pair to lo: released.
    Json a2 = support::report("s", "a", 1000, 0, 0);
    a2["k"] = 2;
    o = e.ingest(a2);
    CHECK_EQ(o.events.array[0].find("reason")->string, std::string("release"));
    CHECK(o.trace.array.back().find("increment")->is_null());
    CHECK(e.snapshot().find("llr")->object.empty());
    CHECK_EQ(e.snapshot().find("intervals")->find("s")->array[0].integer, 1000LL);
    // A pair with an L whose gate fails is updated (forced when `same` fails).
    Json a3 = support::report("s", "a", 2000, 0, 0);
    a3["k"] = 1;
    e.ingest(a3);   // ungrouped: the pair starts again and correlates
    Json b3 = support::report("t", "b", 2000, 0.5, 0);   // far: the distance gate fails
    b3["k"] = 1;
    o = e.ingest(b3);
    bool sprt = false;
    for (const Json& rec : o.trace.array) sprt = sprt || rec.find("stage")->string == "sprt";
    CHECK(sprt);
    // Stale after factor times the lower median, within floor and ceiling.
    o = e.tick(2000 + 2001);
    bool dropped = false;
    for (const Json& ev : o.events.array) dropped = dropped || ev.find("ev")->string == "drop";
    CHECK(dropped);
}

TEST(correlate, engine_sprt_associate_paths) {
    const std::string pack =
        "pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
        "gate distance max_m=1000\ngate same key=k\n"
        "sprt false=0.01 missed=0.01 pos_m=10000 vel_ms=300 hae_sigma_m=100\nstale_ms 100000\n";
    cc::Engine e(cc::parse_pack(pack));
    Json a = support::report("s", "a", 0, 0, 0), b = support::report("t", "b", 0, 0, 0.0001);
    a["k"] = 1;
    b["k"] = 2;   // the `same` gate fails, the pair has no L: nothing
    e.ingest(a);
    corr::Output o = e.ingest(b);
    CHECK(e.snapshot().find("llr")->object.empty());
    CHECK_EQ(o.events.array.size(), size_t{1});
    // A third entity correlates with a; then b, ungrouped, is no candidate
    // of a group holding source s? (b is source t: group {a, c} holds s and u.)
    Json c = support::report("u", "c", 0, 0, 0.00005);
    c["k"] = 1;
    o = e.ingest(c);
    CHECK_EQ(o.events.array.back().find("ev")->string, std::string("correlate"));
    // Out of the gate with an L, `same` passing: the pair adds its evidence.
    Json c2 = support::report("u", "c", 1000, 0.05, 0);
    c2["k"] = 1;
    o = e.ingest(c2);   // c is in the group: only the link pair (with a) is updated
    CHECK(!o.trace.array.empty());
}
