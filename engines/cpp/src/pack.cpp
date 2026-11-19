#include "pack.hpp"

#include <cstdlib>
#include <fstream>
#include <set>
#include <sstream>

namespace corr {

namespace {

// Spec "Tests": the parameters each test takes.
const std::map<std::string, std::vector<std::string>>& test_params() {
    static const std::map<std::string, std::vector<std::string>> table = {
        {"distance", {"max_m"}},
        {"window", {"multiplier", "window_m", "err_min_m", "err_max_m"}},
        {"mahalanobis", {"gate"}},
        {"course", {"max_deg", "min_speed_ms"}},
        {"speed", {"max_pct", "min_speed_ms"}},
        {"altitude", {"max_m"}},
        {"same", {"key"}},
    };
    return table;
}

[[noreturn]] void fail(int line, const std::string& what) {
    throw PackError("pack.def line " + std::to_string(line) + ": " + what);
}

// Spec "Pack": numbers are decimal.
bool is_decimal(const std::string& s) {
    size_t i = 0;
    if (i < s.size() && (s[i] == '+' || s[i] == '-')) ++i;
    size_t digits = 0;
    while (i < s.size() && s[i] >= '0' && s[i] <= '9') { ++i; ++digits; }
    if (i < s.size() && s[i] == '.') {
        ++i;
        while (i < s.size() && s[i] >= '0' && s[i] <= '9') { ++i; ++digits; }
    }
    if (digits == 0) return false;
    if (i < s.size() && (s[i] == 'e' || s[i] == 'E')) {
        ++i;
        if (i < s.size() && (s[i] == '+' || s[i] == '-')) ++i;
        size_t exp = 0;
        while (i < s.size() && s[i] >= '0' && s[i] <= '9') { ++i; ++exp; }
        if (exp == 0) return false;
    }
    return i == s.size();
}

double parse_number(int line, const std::string& s) {
    if (!is_decimal(s)) fail(line, "not a number: " + s);
    return std::strtod(s.c_str(), nullptr);
}

std::int64_t parse_integer(int line, const std::string& s) {
    size_t i = (!s.empty() && (s[0] == '+' || s[0] == '-')) ? 1 : 0;
    if (i == s.size()) fail(line, "not an integer: " + s);
    for (; i < s.size(); ++i)
        if (s[i] < '0' || s[i] > '9') fail(line, "not an integer: " + s);
    return std::strtoll(s.c_str(), nullptr, 10);
}

// `name=value` words, each name given once, exactly the names in `want`.
std::map<std::string, std::string> parse_params(int line, const std::vector<std::string>& words,
                                                size_t from, const std::vector<std::string>& want) {
    std::map<std::string, std::string> out;
    for (size_t k = from; k < words.size(); ++k) {
        size_t eq = words[k].find('=');
        if (eq == std::string::npos || eq == 0) fail(line, "parameter without '=': " + words[k]);
        std::string name = words[k].substr(0, eq);
        bool known = false;
        for (const auto& w : want) known = known || w == name;
        if (!known) fail(line, "unknown parameter: " + name);
        if (!out.emplace(name, words[k].substr(eq + 1)).second) fail(line, "repeated parameter: " + name);
    }
    for (const auto& w : want)
        if (!out.count(w)) fail(line, "missing parameter: " + w);
    return out;
}

TestSpec parse_test(int line, const std::vector<std::string>& words) {
    if (words.size() < 2) fail(line, "missing test name");
    auto it = test_params().find(words[1]);
    if (it == test_params().end()) fail(line, "unknown test: " + words[1]);
    TestSpec t;
    t.name = words[1];
    for (const auto& kv : parse_params(line, words, 2, it->second)) {
        if (t.name == "same") {
            if (kv.second.empty()) fail(line, "empty key");
            t.key = kv.second;
        } else {
            t.num[kv.first] = parse_number(line, kv.second);
        }
    }
    return t;
}

void want_args(int line, const std::vector<std::string>& words, size_t n) {
    if (words.size() != n + 1) fail(line, words[0] + " takes " + std::to_string(n) + " argument(s)");
}

} // namespace

Pack parse_pack(const std::string& text) {
    Pack p;
    std::set<std::string> seen;
    std::istringstream in(text);
    std::string raw;
    int line = 0;
    while (std::getline(in, raw)) {
        ++line;
        size_t hash = raw.find('#');
        if (hash != std::string::npos) raw.erase(hash);
        std::istringstream ws(raw);
        std::vector<std::string> words;
        for (std::string w; ws >> w;) words.push_back(w);
        if (words.empty()) continue;

        const std::string& d = words[0];
        bool repeats = d == "gate" || d == "confirm" || d == "hold" || d == "priority";
        if (!seen.insert(d).second && !repeats) fail(line, "repeated directive: " + d);

        if (d == "pack") {
            want_args(line, words, 1);
            p.name = words[1];
        } else if (d == "version") {
            want_args(line, words, 1);
            p.version = words[1];
        } else if (d == "method") {
            want_args(line, words, 1);
            if (words[1] == "assign") p.method_assign = true;
            else if (words[1] != "confirm") fail(line, "method is confirm or assign");
        } else if (d == "new_cost") {
            want_args(line, words, 1);
            p.new_cost = parse_number(line, words[1]);
        } else if (d == "keep_bonus") {
            want_args(line, words, 1);
            p.keep_bonus = parse_number(line, words[1]);
        } else if (d == "filter") {
            auto kv = parse_params(line, words, 1, {"accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms"});
            p.filter.accel_var = parse_number(line, kv["accel_var"]);
            p.filter.default_ce_m = parse_number(line, kv["default_ce_m"]);
            p.filter.vel_sigma_ms = parse_number(line, kv["vel_sigma_ms"]);
            p.filter.unknown_vel_ms = parse_number(line, kv["unknown_vel_ms"]);
        } else if (d == "gate") {
            p.gate.push_back(parse_test(line, words));
        } else if (d == "confirm") {
            p.confirm.push_back(parse_test(line, words));
        } else if (d == "hold") {
            p.hold.push_back(parse_test(line, words));
        } else if (d == "confirm_count") {
            want_args(line, words, 1);
            p.confirm_count = parse_integer(line, words[1]);
        } else if (d == "hold_failures") {
            want_args(line, words, 1);
            p.hold_failures = parse_integer(line, words[1]);
        } else if (d == "stale_ms") {
            want_args(line, words, 1);
            p.stale_ms = parse_integer(line, words[1]);
        } else if (d == "same_source") {
            want_args(line, words, 1);
            if (words[1] == "allow") p.same_source_allow = true;
            else if (words[1] != "forbid") fail(line, "same_source is forbid or allow");
        } else if (d == "output") {
            want_args(line, words, 1);
            if (words[1] == "latest") p.output_latest = true;
            else if (words[1] != "priority") fail(line, "output is priority or latest");
        } else if (d == "priority") {
            want_args(line, words, 2);
            if (!p.priority.emplace(words[1], parse_integer(line, words[2])).second)
                fail(line, "repeated priority source: " + words[1]);
        } else {
            fail(line, "unknown directive: " + d);
        }
    }
    // Each method has its own directives (correlate.md "Pack", correlate-assign.md "Pack").
    std::vector<const char*> required, refused;
    if (p.method_assign) {
        required = {"pack", "version", "filter", "new_cost", "keep_bonus", "stale_ms"};
        refused = {"confirm", "hold", "confirm_count", "hold_failures", "same_source", "output", "priority"};
    } else {
        required = {"pack", "version", "filter", "confirm_count", "hold_failures", "stale_ms"};
        refused = {"new_cost", "keep_bonus"};
    }
    for (const char* req : required)
        if (!seen.count(req)) throw PackError(std::string("pack.def: missing directive ") + req);
    for (const char* d : refused)
        if (seen.count(d))
            throw PackError(std::string("pack.def: directive ") + d + " is not allowed with method " +
                            (p.method_assign ? "assign" : "confirm"));
    return p;
}

Pack load_pack(const std::string& dir) {
    std::ifstream f(dir + "/pack.def", std::ios::binary);
    if (!f) throw PackError("cannot read " + dir + "/pack.def");
    std::ostringstream ss;
    ss << f.rdbuf();
    return parse_pack(ss.str());
}

} // namespace corr
