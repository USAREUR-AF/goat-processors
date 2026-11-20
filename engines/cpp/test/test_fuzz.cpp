// Fuzzing of the input parsers: the JSON reader (reports, steps files,
// vectors) and the four pack.def grammars. A seeded generator written here
// (random.hpp) mutates real inputs (every vector file, every pack.def, every
// load vector's pack_def) and builds random ones; the number of cases is
// fixed, so a run is the same everywhere and its time is bounded (about a
// second in a Release build).
//
// Each case must either parse or fail with the parser's own error
// (JsonError, PackError), never another exception or a crash; parsing is a
// function of the text (the same text twice gives the same result); and a
// parsed JSON value written out and read again is the same value.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include "check.hpp"
#include "correlate/pack.hpp"
#include "filter/pack.hpp"
#include "fuse/pack.hpp"
#include "model/json.hpp"
#include "quality/pack.hpp"
#include "random.hpp"
#include "support.hpp"

using corr::Json;
namespace fs = std::filesystem;

namespace {

std::vector<std::string> files_under(const std::string& dir, const std::string& name_or_ext) {
    std::vector<std::string> out;
    for (const auto& e : fs::recursive_directory_iterator(dir))
        if (e.is_regular_file() &&
            (e.path().extension() == name_or_ext || e.path().filename() == name_or_ext))
            out.push_back(e.path().string());
    std::sort(out.begin(), out.end());
    return out;
}

const char* kJsonBytes = "{}[],:\"\\0123456789-+.eEtrufalsn \t\n\r/u";

// One mutation of `s`: a byte replaced, inserted or deleted, a span
// repeated or cut, or two halves swapped.
std::string mutate(std::string s, support::Random& rnd, const std::string& alphabet) {
    int edits = 1 + static_cast<int>(rnd.below(4));
    for (int k = 0; k < edits; ++k) {
        size_t at = s.empty() ? 0 : rnd.below(s.size());
        char c = rnd.chance(0.8) ? alphabet[rnd.below(alphabet.size())] : static_cast<char>(rnd.below(256));
        switch (rnd.below(6)) {
            case 0: if (!s.empty()) s[at] = c; break;
            case 1: s.insert(s.begin() + static_cast<long>(at), c); break;
            case 2: if (!s.empty()) s.erase(at, 1); break;
            case 3: s.insert(at, s.substr(at, rnd.below(16))); break;
            case 4: s.erase(at, rnd.below(32)); break;
            default: s = s.substr(at) + s.substr(0, at); break;
        }
    }
    return s;
}

// A random JSON value of bounded depth.
Json random_json(support::Random& rnd, int depth) {
    switch (depth <= 0 ? rnd.below(4) : rnd.below(6)) {
        case 0: return Json();
        case 1: return Json(rnd.chance(0.5));
        case 2:
            if (rnd.chance(0.5)) return Json(static_cast<long long>(rnd.next()));
            return Json((rnd.unit() - 0.5) * std::pow(10.0, static_cast<double>(rnd.below(40)) - 20));
        case 3: {
            std::string s;
            for (std::uint64_t i = 0, n = rnd.below(8); i < n; ++i) s += static_cast<char>(1 + rnd.below(255));
            return Json(s);
        }
        case 4: {
            Json a = Json::make_array();
            for (std::uint64_t i = 0, n = rnd.below(5); i < n; ++i) a.push(random_json(rnd, depth - 1));
            return a;
        }
        default: {
            Json o = Json::make_object();
            for (std::uint64_t i = 0, n = rnd.below(5); i < n; ++i)
                o["k" + std::to_string(rnd.below(10))] = random_json(rnd, depth - 1);
            return o;
        }
    }
}

// True when v holds a number that is not finite (a literal such as 1e999
// reads as infinity; the writer then gives text that is not JSON, see
// DISAGREEMENTS.md), which has no round trip.
bool has_nonfinite(const Json& v) {
    if (v.is_number()) return !std::isfinite(v.number);
    for (const Json& x : v.array)
        if (has_nonfinite(x)) return true;
    for (const auto& kv : v.object)
        if (has_nonfinite(kv.second)) return true;
    return false;
}

// Parses text; true when it parsed. Any exception but JsonError fails the test.
bool json_case(const std::string& text) {
    Json v;
    try {
        v = corr::parse_json(text);
    } catch (const corr::JsonError&) {
        CHECK_THROWS(corr::JsonError, corr::parse_json(text));   // the same text fails again
        return false;
    }
    CHECK(corr::json_equal(v, corr::parse_json(text)));
    if (!has_nonfinite(v)) CHECK(corr::json_equal(v, corr::parse_json(corr::to_json(v))));   // written and read again
    return true;
}

// Parses a pack.def with `parse`; the same text twice gives the same result.
template <typename Parse>
bool pack_case(Parse parse, const std::string& text) {
    std::string first, second;
    bool ok1 = true, ok2 = true;
    try {
        parse(text);
    } catch (const corr::PackError& e) {
        ok1 = false;
        first = e.what();
    }
    try {
        parse(text);
    } catch (const corr::PackError& e) {
        ok2 = false;
        second = e.what();
    }
    CHECK(ok1 == ok2);
    CHECK_EQ(first, second);
    return ok1;
}

} // namespace

TEST(fuzz, json_reader_mutations) {
    support::Random rnd(20261120);
    std::vector<std::string> seeds;
    for (const auto& f : files_under(support::repo("packs"), ".json")) {
        std::string text = corr::io::read_file(f);
        for (size_t at = 0; at < text.size() && seeds.size() < 400; at += 1500)
            seeds.push_back(text.substr(at, 1500));   // pieces, most of them not valid JSON
        seeds.push_back(text);
    }
    size_t parsed = 0;
    const int n = 6000;
    for (int i = 0; i < n; ++i) parsed += json_case(mutate(seeds[rnd.below(seeds.size())], rnd, kJsonBytes));
    CHECK(parsed > 0 && parsed < static_cast<size_t>(n));
}

TEST(fuzz, json_reader_random_values) {
    support::Random rnd(7);
    for (int i = 0; i < 3000; ++i) {
        Json v = random_json(rnd, 4);
        std::string text = corr::to_json(v);
        CHECK(json_case(text));
        CHECK(corr::json_equal(corr::parse_json(text), v));
    }
    CHECK(!json_case("1e999") || has_nonfinite(corr::parse_json("1e999")));
    for (int i = 0; i < 3000; ++i) {
        std::string s;
        for (std::uint64_t k = 0, len = rnd.below(24); k < len; ++k) s += kJsonBytes[rnd.below(std::strlen(kJsonBytes))];
        json_case(s);
    }
}

TEST(fuzz, pack_def_parsers) {
    support::Random rnd(1120);
    struct Grammar {
        std::string prefix;
        bool (*run)(const std::string&);
    };
    const Grammar grammars[] = {
        {"correlate", [](const std::string& t) { return pack_case(corr::correlate::parse_pack, t); }},
        {"filter", [](const std::string& t) { return pack_case(corr::filter::parse_pack, t); }},
        {"fuse", [](const std::string& t) { return pack_case(corr::fuse::parse_pack, t); }},
        {"quality", [](const std::string& t) { return pack_case(corr::quality::parse_pack, t); }},
    };
    const std::string alphabet = "abcdefghijklmnopqrstuvwxyz_=.,;-+0123456789 \t\n\r#e";
    for (const Grammar& g : grammars) {
        std::vector<std::string> seeds;
        for (const auto& f : files_under(support::repo("packs"), "pack.def"))
            if (fs::path(f).parent_path().filename().string().rfind(g.prefix + "-", 0) == 0)
                seeds.push_back(corr::io::read_file(f));
        for (const auto& f : files_under(support::repo("spec/" + g.prefix + "-load-vectors"), ".json"))
            seeds.push_back(support::read_json(f).find("pack_def")->string);
        CHECK(!seeds.empty());
        size_t loaded = 0;
        for (const auto& s : seeds) loaded += g.run(s);
        CHECK(loaded > 0);
        // Mutations of real packs, and lines of one pack spliced into another.
        for (int i = 0; i < 2500; ++i) {
            std::string s = seeds[rnd.below(seeds.size())];
            if (rnd.chance(0.3)) {
                const std::string& other = seeds[rnd.below(seeds.size())];
                size_t at = rnd.below(other.size() + 1);
                size_t nl = other.find('\n', at);
                s += "\n" + other.substr(at, nl == std::string::npos ? std::string::npos : nl - at) + "\n";
            }
            g.run(mutate(s, rnd, alphabet));
        }
    }
}
