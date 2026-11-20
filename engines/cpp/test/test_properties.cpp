// Property tests.
//
// - Determinism: the same input gives the same output, for every scenario
//   vector of every function and for a seeded random scenario.
// - Order independence, where the specifications say order does not matter:
//   the order of the keys of a report (a JSON object); the order of a filter
//   pack's other directives relative to its rules (filter.md "Pack"); and,
//   for correlate's method assign and for fuse, the order of reports of
//   different entities between two ticks, which both decide only at the tick,
//   in key order (correlate-assign.md "Window", fuse.md "On each tick"), once
//   the frame reference (the first accepted report) is the same.
// - Snapshot then restore: this engine does not restore a snapshot (no
//   function's specification defines restoring), so there is no such test.
#include <algorithm>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

#include "check.hpp"
#include "filter/engine.hpp"
#include "filter/pack.hpp"
#include "io/function.hpp"
#include "model/report.hpp"
#include "random.hpp"
#include "support.hpp"

using corr::Json;
namespace fs = std::filesystem;

namespace {

struct Vector {
    std::string function, pack;
    Json doc;
};

// Every scenario vector of every function.
std::vector<Vector> scenario_vectors() {
    std::vector<Vector> out;
    std::vector<fs::path> files;
    for (const auto& p : fs::directory_iterator(support::repo("packs")))
        if (fs::is_directory(p.path() / "vectors"))
            for (const auto& f : fs::directory_iterator(p.path() / "vectors"))
                if (f.path().extension() == ".json") files.push_back(f.path());
    std::sort(files.begin(), files.end());
    for (const auto& f : files) {
        std::string pack = f.parent_path().parent_path().filename().string();
        out.push_back({pack.substr(0, pack.find('-')), pack, support::read_json(f.string())});
    }
    return out;
}

support::Run run(const std::string& function, const std::string& pack, const std::vector<Json>& steps) {
    auto f = corr::io::load(function, support::repo("packs/" + pack));
    support::Run r;
    for (const Json& step : steps) {
        const Json* ingest = step.find("ingest");
        r.outputs.push_back(ingest ? f->ingest(*ingest) : f->tick(step.find("tick")->integer));
    }
    r.snapshot = f->snapshot();
    return r;
}

// A seeded scenario: a few sources and entities moving near one point, with
// ticks, optional keys, an occasional late or repeated report.
std::vector<Json> random_steps(std::uint64_t seed, int n) {
    support::Random rnd(seed);
    std::vector<Json> steps;
    std::int64_t now = 0;
    const char* sources[] = {"radar", "adsb", "eo"};
    for (int i = 0; i < n; ++i) {
        if (rnd.chance(0.15)) {
            now += 1000;
            steps.push_back(support::tick_step(now));
            continue;
        }
        std::string src = sources[rnd.below(3)];
        std::string uid = "T" + std::to_string(rnd.below(4));
        std::int64_t t = now + static_cast<std::int64_t>(rnd.below(1000)) - (rnd.chance(0.05) ? 3000 : 0);
        Json r = support::report(src, uid, t, 50 + rnd.unit() * 0.01, 8 + rnd.unit() * 0.01);
        if (rnd.chance(0.7)) r["ce"] = 5 + rnd.unit() * 40;
        if (rnd.chance(0.6)) {
            r["course"] = rnd.unit() * 360;
            r["speed_ms"] = rnd.unit() * 200;
        }
        if (rnd.chance(0.5)) r["hae"] = 1000 + rnd.unit() * 100;
        if (rnd.chance(0.5)) r["type"] = "a-f-A-M";
        if (rnd.chance(0.3)) r["received_ms"] = static_cast<long long>(t + 50);
        if (rnd.chance(0.3)) r["time_error_ms"] = rnd.unit() * 100;
        if (rnd.chance(0.3)) r["fuse.group"] = "G" + std::to_string(rnd.below(2));
        steps.push_back(support::ingest_step(r));
    }
    return steps;
}

// The JSON text of v with every object's keys written in reverse byte order.
std::string reversed_text(const Json& v) {
    if (v.is_object()) {
        std::string s = "{";
        bool first = true;
        for (auto it = v.object.rbegin(); it != v.object.rend(); ++it) {
            if (!first) s += ",";
            first = false;
            s += corr::to_json(Json(it->first)) + ":" + reversed_text(it->second);
        }
        return s + "}";
    }
    if (v.is_array()) {
        std::string s = "[";
        for (size_t i = 0; i < v.array.size(); ++i) s += (i ? "," : "") + reversed_text(v.array[i]);
        return s + "]";
    }
    std::string t = corr::to_json(v);
    // A number read with a fraction or exponent stays one that is not an integer.
    if (v.is_number() && !v.is_int && t.find_first_of(".eEn") == std::string::npos) t += ".0";
    return t;
}

// The steps with the reports between two ticks reordered: the reports of one
// entity keep their order, the entities are shuffled; the first accepted
// report stays first.
std::vector<Json> shuffle_between_ticks(const std::vector<Json>& steps, support::Random& rnd) {
    std::vector<Json> out;
    size_t i = 0;
    // Up to the first report with the required keys (the frame reference), unchanged.
    while (i < steps.size()) {
        const Json* r = steps[i].find("ingest");
        out.push_back(steps[i++]);
        if (r && !corr::report::missing_required(*r)) break;
    }
    while (i < steps.size()) {
        if (!steps[i].has("ingest")) {
            out.push_back(steps[i++]);
            continue;
        }
        std::vector<std::string> order;
        std::map<std::string, std::vector<Json>> by_entity;
        for (; i < steps.size() && steps[i].has("ingest"); ++i) {
            const Json& r = *steps[i].find("ingest");
            const Json* s = r.find("track.source_id");
            const Json* u = r.find("uid");
            std::string key = (s ? corr::to_json(*s) : "") + "/" + (u ? corr::to_json(*u) : "");
            if (!by_entity.count(key)) order.push_back(key);
            by_entity[key].push_back(steps[i]);
        }
        for (size_t k = order.size(); k > 1; --k) std::swap(order[k - 1], order[rnd.below(k)]);
        for (const auto& key : order)
            for (const Json& s : by_entity[key]) out.push_back(s);
    }
    return out;
}

// Only the tick outputs and the snapshot of a run.
std::string tick_text(const std::vector<Json>& steps, const support::Run& r) {
    std::string s;
    for (size_t i = 0; i < steps.size(); ++i)
        if (!steps[i].has("ingest")) s += corr::to_json(r.outputs[i].events) + corr::to_json(r.outputs[i].trace) + "\n";
    return s + corr::to_json(r.snapshot);
}

const std::vector<std::pair<std::string, std::string>> kPacks = {
    {"correlate", "correlate-gnn"},        {"correlate", "correlate-gnn-imm"},
    {"correlate", "correlate-gnn-time"},   {"correlate", "correlate-assign"},
    {"correlate", "correlate-assign-full"}, {"correlate", "correlate-assign-time"},
    {"filter", "filter-area"},             {"filter", "filter-thin"},
    {"fuse", "fuse-independent"},          {"fuse", "fuse-shared"},
    {"quality", "quality-feed"},           {"quality", "quality-time"}};

} // namespace

TEST(property, determinism_on_every_vector) {
    size_t n = 0;
    for (const Vector& v : scenario_vectors()) {
        auto steps = support::steps_of(v.doc);
        CHECK_EQ(run(v.function, v.pack, steps).text(), run(v.function, v.pack, steps).text());
        ++n;
    }
    CHECK(n > 100);
}

TEST(property, determinism_on_random_scenarios) {
    for (std::uint64_t seed = 1; seed <= 4; ++seed) {
        auto steps = random_steps(seed, 150);
        for (const auto& [fn, pack] : kPacks) CHECK_EQ(run(fn, pack, steps).text(), run(fn, pack, steps).text());
    }
}

TEST(property, report_key_order_does_not_matter) {
    for (const Vector& v : scenario_vectors()) {
        auto steps = support::steps_of(v.doc);
        std::vector<Json> reparsed;
        for (const Json& s : steps) reparsed.push_back(corr::parse_json(reversed_text(s)));
        CHECK_EQ(run(v.function, v.pack, steps).text(), run(v.function, v.pack, reparsed).text());
    }
}

TEST(property, filter_directive_order_does_not_matter) {
    for (const char* pack : {"filter-area", "filter-dateline", "filter-thin"}) {
        std::string text = corr::io::read_file(support::repo(std::string("packs/") + pack + "/pack.def"));
        // The other directives moved after every rule.
        std::string head, rules, line;
        bool in_rules = false;
        for (size_t i = 0; i <= text.size(); ++i) {
            if (i < text.size() && text[i] != '\n') {
                line += text[i];
                continue;
            }
            std::string word = line.substr(0, line.find_first_of(" \t"));
            if (word == "rule") in_rules = true;
            bool rule_line = word == "rule" || word == "when";
            ((rule_line || (in_rules && word.empty())) ? rules : head) += line + "\n";
            line.clear();
        }
        std::string moved = rules + head;
        auto a = support::read_json(support::repo(std::string("packs/") + pack + "/vectors") + "/" +
                                    fs::directory_iterator(support::repo(std::string("packs/") + pack + "/vectors"))
                                        ->path()
                                        .filename()
                                        .string());
        auto steps = support::steps_of(a);
        corr::filter::Engine e1(corr::filter::parse_pack(text)), e2(corr::filter::parse_pack(moved));
        CHECK_EQ(support::run_steps(e1, steps).text(), support::run_steps(e2, steps).text());
    }
}

TEST(property, report_order_between_ticks_assign_and_fuse) {
    support::Random rnd(7);
    size_t checked = 0;
    for (const Vector& v : scenario_vectors()) {
        bool assign = v.pack.rfind("correlate-assign", 0) == 0;
        if (!assign && v.function != "fuse") continue;
        auto steps = support::steps_of(v.doc);
        for (int k = 0; k < 3; ++k) {
            auto shuffled = shuffle_between_ticks(steps, rnd);
            CHECK_EQ(tick_text(steps, run(v.function, v.pack, steps)),
                     tick_text(shuffled, run(v.function, v.pack, shuffled)));
            ++checked;
        }
    }
    for (std::uint64_t seed = 11; seed <= 13; ++seed) {
        auto steps = random_steps(seed, 150);
        for (const char* pack : {"correlate-assign", "correlate-assign-full", "correlate-assign-time"}) {
            auto shuffled = shuffle_between_ticks(steps, rnd);
            CHECK_EQ(tick_text(steps, run("correlate", pack, steps)),
                     tick_text(shuffled, run("correlate", pack, shuffled)));
        }
        for (const char* pack : {"fuse-independent", "fuse-shared", "fuse-latest"}) {
            auto shuffled = shuffle_between_ticks(steps, rnd);
            CHECK_EQ(tick_text(steps, run("fuse", pack, steps)), tick_text(shuffled, run("fuse", pack, shuffled)));
        }
    }
    CHECK(checked > 30);
}
