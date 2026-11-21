// correlate.md "Pack" and correlate-assign.md "Pack".
#include "correlate/pack.hpp"
#include "correlate/method.hpp"
#include "model/report.hpp"

#include <cstdlib>
#include <set>
#include <sstream>

namespace corr::correlate {

namespace {

[[noreturn]] void fail(int line, const std::string& what) { pack_fail(line, what); }

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

TestSpec parse_test(int line, const std::vector<std::string>& words, const TestRegistry& tests) {
    if (words.size() < 2) fail(line, "missing test name");
    const TestKind* kind = tests.find(words[1]);
    if (!kind) fail(line, "unknown test: " + words[1]);
    TestSpec t;
    t.name = words[1];
    t.run = kind->run;
    for (const auto& kv : parse_params(line, words, 2, kind->params)) {
        if (kind->text_param) {
            if (kv.second.empty()) fail(line, "empty key");
            t.key = kv.second;
        } else {
            t.num[kv.first] = parse_number(line, kv.second);
        }
    }
    if (kind->check)
        if (const char* what = kind->check(t)) fail(line, what);
    return t;
}

void want_args(int line, const std::vector<std::string>& words, size_t n) {
    if (words.size() != n + 1) fail(line, words[0] + " takes " + std::to_string(n) + " argument(s)");
}

} // namespace

Pack parse_pack(const std::string& text) { return parse_pack_with(text, builtin_tests()); }

Pack parse_pack_with(const std::string& text, const TestRegistry& tests) {
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
        bool repeats = d == "gate" || d == "confirm" || d == "hold" || d == "priority" || d == "time_default";
        if (!seen.insert(d).second && !repeats) fail(line, "repeated directive: " + d);

        if (d == "pack") {
            want_args(line, words, 1);
            p.name = words[1];
        } else if (d == "version") {
            want_args(line, words, 1);
            p.version = words[1];
        } else if (d == "method") {
            want_args(line, words, 1);
            if (!find_method(words[1])) {
                std::string names;
                for (const MethodKind& m : methods()) names += std::string(names.empty() ? "" : " or ") + m.name;
                fail(line, "method is " + names);
            }
            p.method = words[1];
        } else if (d == "new_cost") {
            want_args(line, words, 1);
            p.new_cost = parse_number(line, words[1]);
            if (!(p.new_cost > 0)) fail(line, "new_cost must be above 0");
        } else if (d == "keep_bonus") {
            want_args(line, words, 1);
            p.keep_bonus = parse_number(line, words[1]);
            if (!(p.keep_bonus >= 0)) fail(line, "keep_bonus must be 0 or above");
        } else if (d == "window" || d == "hypotheses") {
            // correlate-assign.md "Pack": integers, 1 or above, one value.
            want_args(line, words, 1);
            std::int64_t v = parse_integer(line, words[1]);
            if (v < 1) fail(line, d + " must be 1 or above");
            (d == "window" ? p.window : p.hypotheses) = v;
        } else if (d == "maneuver") {
            // correlate.md "Pack": exactly accel_var, p_enter, p_leave.
            auto kv = parse_params(line, words, 1, {"accel_var", "p_enter", "p_leave"});
            ManeuverParams m;
            m.accel_var = parse_number(line, kv["accel_var"]);
            m.p_enter = parse_number(line, kv["p_enter"]);
            m.p_leave = parse_number(line, kv["p_leave"]);
            if (!(m.p_enter > 0) || !(m.p_leave > 0) || !(m.p_enter + m.p_leave < 1))
                fail(line, "p_enter and p_leave must be above 0 with a sum below 1");
            p.maneuver = m;
        } else if (d == "restart") {
            // correlate.md "Pack": exactly gate, above 0.
            auto kv = parse_params(line, words, 1, {"gate"});
            double g = parse_number(line, kv["gate"]);
            if (!(g > 0)) fail(line, "restart gate must be above 0");
            p.restart_gate = g;
        } else if (d == "time_default") {
            parse_time_default(line, words, [line](const std::string& v) { return parse_number(line, v); },
                               p.time_default);
        } else if (d == "time_offset") {
            // correlate-assign.md "Pack": exactly sigma_ms, above 0; needs bias
            // (checked once the whole file is read).
            auto kv = parse_params(line, words, 1, {"sigma_ms"});
            double t = parse_number(line, kv["sigma_ms"]);
            if (!(t > 0)) fail(line, "time_offset sigma_ms must be above 0");
            p.time_offset_sigma_ms = t;
        } else if (d == "bias") {
            // correlate-assign.md "Pack": exactly sigma_m, floor_m, gate; sigma_m
            // and gate above 0, floor_m above 0 and at most sigma_m.
            auto kv = parse_params(line, words, 1, {"sigma_m", "floor_m", "gate"});
            BiasParams b;
            b.sigma_m = parse_number(line, kv["sigma_m"]);
            b.floor_m = parse_number(line, kv["floor_m"]);
            b.gate = parse_number(line, kv["gate"]);
            if (!(b.sigma_m > 0) || !(b.gate > 0)) fail(line, "bias sigma_m and gate must be above 0");
            if (!(b.floor_m > 0) || !(b.floor_m <= b.sigma_m))
                fail(line, "bias floor_m must be above 0 and at most sigma_m");
            p.bias = b;
        } else if (d == "margin") {
            // correlate-assign.md "Pack": one number above 0.
            want_args(line, words, 1);
            double m = parse_number(line, words[1]);
            if (!(m > 0)) fail(line, "margin must be above 0");
            p.margin = m;
        } else if (d == "filter") {
            auto kv = parse_params(line, words, 1, {"accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms"});
            p.filter.accel_var = parse_number(line, kv["accel_var"]);
            p.filter.default_ce_m = parse_number(line, kv["default_ce_m"]);
            p.filter.vel_sigma_ms = parse_number(line, kv["vel_sigma_ms"]);
            p.filter.unknown_vel_ms = parse_number(line, kv["unknown_vel_ms"]);
            // correlate.md "Pack": ranges of the filter parameters.
            if (!(p.filter.default_ce_m > 0) || !(p.filter.vel_sigma_ms > 0) ||
                !(p.filter.unknown_vel_ms > 0))
                fail(line, "default_ce_m, vel_sigma_ms and unknown_vel_ms must be above 0");
            if (!(p.filter.accel_var >= 0)) fail(line, "accel_var must be 0 or above");
        } else if (d == "gate") {
            p.gate.push_back(parse_test(line, words, tests));
        } else if (d == "confirm") {
            p.confirm.push_back(parse_test(line, words, tests));
        } else if (d == "hold") {
            p.hold.push_back(parse_test(line, words, tests));
        } else if (d == "confirm_count") {
            want_args(line, words, 1);
            p.confirm_count = parse_integer(line, words[1]);
        } else if (d == "hold_failures") {
            want_args(line, words, 1);
            p.hold_failures = parse_integer(line, words[1]);
        } else if (d == "stale_ms") {
            want_args(line, words, 1);
            p.stale_ms = parse_integer(line, words[1]);
        } else if (d == "stale_rate") {
            // correlate.md "Pack": exactly factor (above 0), floor_ms and
            // ceiling_ms (integers, 0 <= floor_ms <= ceiling_ms), samples (an
            // integer, 1 or above).
            auto kv = parse_params(line, words, 1, {"factor", "floor_ms", "ceiling_ms", "samples"});
            StaleRate sr;
            sr.factor = parse_number(line, kv["factor"]);
            sr.floor_ms = parse_integer(line, kv["floor_ms"]);
            sr.ceiling_ms = parse_integer(line, kv["ceiling_ms"]);
            sr.samples = parse_integer(line, kv["samples"]);
            if (!(sr.factor > 0)) fail(line, "stale_rate factor must be above 0");
            if (sr.floor_ms < 0 || sr.floor_ms > sr.ceiling_ms)
                fail(line, "stale_rate needs 0 <= floor_ms <= ceiling_ms");
            if (sr.samples < 1) fail(line, "stale_rate samples must be 1 or above");
            p.stale_rate = sr;
        } else if (d == "sprt") {
            // correlate.md "Pack": false and missed above 0 and below 0.5;
            // pos_m, vel_ms, hae_sigma_m above 0.
            auto kv = parse_params(line, words, 1, {"false", "missed", "pos_m", "vel_ms", "hae_sigma_m"});
            SprtParams sp;
            sp.false_p = parse_number(line, kv["false"]);
            sp.missed = parse_number(line, kv["missed"]);
            sp.pos_m = parse_number(line, kv["pos_m"]);
            sp.vel_ms = parse_number(line, kv["vel_ms"]);
            sp.hae_sigma_m = parse_number(line, kv["hae_sigma_m"]);
            if (!(sp.false_p > 0 && sp.false_p < 0.5) || !(sp.missed > 0 && sp.missed < 0.5))
                fail(line, "sprt false and missed must be above 0 and below 0.5");
            if (!(sp.pos_m > 0) || !(sp.vel_ms > 0) || !(sp.hae_sigma_m > 0))
                fail(line, "sprt pos_m, vel_ms and hae_sigma_m must be above 0");
            p.sprt = sp;
        } else if (d == "same_source") {
            want_args(line, words, 1);
            if (words[1] == "allow") p.same_source_allow = true;
            else if (words[1] != "forbid") fail(line, "same_source is forbid or allow");
        } else if (d == "output") {
            want_args(line, words, 1);
            if (words[1] == "fused") p.output = OutputMode::fused;
            else if (words[1] == "priority") p.output = OutputMode::priority;
            else if (words[1] == "latest") p.output = OutputMode::latest;
            else fail(line, "output is fused, priority or latest");
        } else if (d == "priority") {
            want_args(line, words, 2);
            if (!p.priority.emplace(words[1], parse_integer(line, words[2])).second)
                fail(line, "repeated priority source: " + words[1]);
        } else {
            fail(line, "unknown directive: " + d);
        }
    }
    // Each method has its own directives (correlate.md "Pack", correlate-assign.md "Pack").
    const MethodKind& method = *find_method(p.method);
    for (const char* req : method.required)
        if (!seen.count(req)) throw PackError(std::string("pack.def: missing directive ") + req);
    for (const char* d : method.refused)
        if (seen.count(d))
            throw PackError(std::string("pack.def: directive ") + d + " is not allowed with method " + method.name);
    if (method.check) method.check(seen);
    // Both methods: one of stale_ms and stale_rate, never both.
    if (seen.count("stale_ms") == seen.count("stale_rate"))
        throw PackError("pack.def: one of stale_ms and stale_rate is required, never both");
    // correlate.md "Pack": checked once the whole file is read.
    if (p.maneuver && !(p.maneuver->accel_var > p.filter.accel_var))
        throw PackError("pack.def: maneuver accel_var must be above filter accel_var");
    // correlate-assign.md "Pack".
    if (p.hypotheses > 1 && p.window <= 1)
        throw PackError("pack.def: hypotheses above 1 needs window above 1");
    if (p.margin && p.hypotheses <= 1) throw PackError("pack.def: margin needs hypotheses above 1");
    if (p.time_offset_sigma_ms && !p.bias) throw PackError("pack.def: time_offset needs bias");
    return p;
}

Pack load_pack(const std::string& dir) { return parse_pack(read_pack_def(dir)); }

} // namespace corr::correlate
