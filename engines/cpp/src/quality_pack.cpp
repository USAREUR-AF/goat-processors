// spec/quality.md, section Pack: parsing pack.def into a quality::Pack.

#include <cstdlib>
#include <fstream>
#include <set>
#include <sstream>

#include "quality.hpp"

namespace corr::quality {

namespace {

[[noreturn]] void fail(int line, const std::string& what) {
    throw PackError("pack.def line " + std::to_string(line) + ": " + what);
}

// "Values": a number is written -?[0-9]+(\.[0-9]+)? and read as the nearest binary64.
bool is_number_text(const std::string& s) {
    size_t i = 0;
    if (i < s.size() && s[i] == '-') ++i;
    size_t digits = 0;
    while (i < s.size() && s[i] >= '0' && s[i] <= '9') { ++i; ++digits; }
    if (digits == 0) return false;
    if (i < s.size() && s[i] == '.') {
        ++i;
        size_t frac = 0;
        while (i < s.size() && s[i] >= '0' && s[i] <= '9') { ++i; ++frac; }
        if (frac == 0) return false;
    }
    return i == s.size();
}

// "Values": an integer is written [0-9]+.
bool is_integer_text(const std::string& s) {
    if (s.empty()) return false;
    for (char c : s)
        if (c < '0' || c > '9') return false;
    return true;
}

double number(int line, const std::string& name, const std::string& s) {
    if (!is_number_text(s)) fail(line, name + " is not a number: " + s);
    return std::strtod(s.c_str(), nullptr);
}

std::int64_t integer(int line, const std::string& name, const std::string& s) {
    if (!is_integer_text(s)) fail(line, name + " is not an integer: " + s);
    return std::strtoll(s.c_str(), nullptr, 10);
}

// "A rule name is one or more of A-Z a-z 0-9 . _ -".
bool is_rule_name(const std::string& s) {
    if (s.empty()) return false;
    for (char c : s) {
        bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                  c == '.' || c == '_' || c == '-';
        if (!ok) return false;
    }
    return true;
}

// `name=value` words from `from` on: each has `=`, each name is known and
// given once, every required name is given.
std::map<std::string, std::string> params(int line, const std::vector<std::string>& words, size_t from,
                                          const std::vector<std::string>& required,
                                          const std::vector<std::string>& optional = {}) {
    std::map<std::string, std::string> out;
    for (size_t k = from; k < words.size(); ++k) {
        size_t eq = words[k].find('=');
        if (eq == std::string::npos) fail(line, "parameter without '=': " + words[k]);
        std::string name = words[k].substr(0, eq);
        bool known = false;
        for (const auto& w : required) known = known || w == name;
        for (const auto& w : optional) known = known || w == name;
        if (!known) fail(line, "unknown parameter: " + name);
        if (!out.emplace(name, words[k].substr(eq + 1)).second) fail(line, "repeated parameter: " + name);
    }
    for (const auto& w : required)
        if (!out.count(w)) fail(line, "missing parameter: " + w);
    return out;
}

bool in_list(const std::vector<std::string>& list, const std::string& s) {
    for (const auto& x : list)
        if (x == s) return true;
    return false;
}

Rule parse_rule(int line, const std::vector<std::string>& words, const std::set<std::string>& earlier) {
    // `rule <name> scope= measure= op= limit= for= clear= action= [factor=]`
    if (words.size() < 2 || words[1].find('=') != std::string::npos) fail(line, "rule without a name");
    Rule r;
    r.name = words[1];
    if (!is_rule_name(r.name)) fail(line, "bad rule name: " + r.name);
    if (earlier.count(r.name)) fail(line, "rule name used by an earlier rule: " + r.name);

    auto p = params(line, words, 2, {"scope", "measure", "op", "limit", "for", "clear", "action"}, {"factor"});

    const std::string& scope = p["scope"];
    if (scope == "entity") r.scope = Scope::Entity;
    else if (scope == "source") r.scope = Scope::Source;
    else fail(line, "bad scope: " + scope);

    r.measure = p["measure"];
    const auto& measures = r.scope == Scope::Entity ? entity_measure_names() : source_measure_names();
    if (!in_list(measures, r.measure)) fail(line, "measure not in the " + scope + " measures: " + r.measure);

    const std::string& op = p["op"];
    if (op == "<") r.op = Op::Lt;
    else if (op == "<=") r.op = Op::Le;
    else if (op == ">") r.op = Op::Gt;
    else if (op == ">=") r.op = Op::Ge;
    else fail(line, "bad op: " + op);

    const std::string& action = p["action"];
    if (action == "mark") r.action = Action::Mark;
    else if (action == "downgrade") r.action = Action::Downgrade;
    else if (action == "drop") r.action = Action::Drop;
    else if (action == "alert") r.action = Action::Alert;
    else fail(line, "bad action: " + action);

    r.limit = number(line, "limit", p["limit"]);
    r.clear = number(line, "clear", p["clear"]);
    r.for_count = integer(line, "for", p["for"]);
    if (r.for_count < 1) fail(line, "for below 1");

    bool upward = r.op == Op::Gt || r.op == Op::Ge;
    if (upward && r.clear > r.limit) fail(line, "clear above limit for op " + op);
    if (!upward && r.clear < r.limit) fail(line, "clear below limit for op " + op);

    bool has_factor = p.count("factor") > 0;
    if (r.action == Action::Downgrade && !has_factor) fail(line, "downgrade without factor");
    if (r.action != Action::Downgrade && has_factor) fail(line, "factor with action " + action);
    if (has_factor) {
        r.factor = number(line, "factor", p["factor"]);
        if (r.factor < 1) fail(line, "factor below 1");
    }
    return r;
}

} // namespace

const std::vector<std::string>& entity_measure_names() {
    static const std::vector<std::string> names = {
        "reports", "interval_last", "interval_mean", "interval_max", "age",
        "latency_mean", "latency_max", "nis_mean", "speed_err_mean",
        "out_of_order", "duplicate", "missing_ce", "missing_vel", "missing_hae"};
    return names;
}

const std::vector<std::string>& source_measure_names() {
    static const std::vector<std::string> names = [] {
        std::vector<std::string> n = entity_measure_names();
        n.push_back("entities");
        return n;
    }();
    return names;
}

const char* scope_name(Scope s) { return s == Scope::Entity ? "entity" : "source"; }

const char* action_name(Action a) {
    switch (a) {
        case Action::Mark: return "mark";
        case Action::Downgrade: return "downgrade";
        case Action::Drop: return "drop";
        case Action::Alert: return "alert";
    }
    return "";
}

Pack parse_pack(const std::string& text) {
    Pack pack;
    std::set<std::string> seen;           // pack, version, filter, window: once each
    std::set<std::string> rule_names;
    std::istringstream in(text);
    std::string raw;
    int line = 0;
    while (std::getline(in, raw)) {
        ++line;
        // `#` starts a comment; tokens are separated by spaces or tabs.
        std::string body = raw.substr(0, raw.find('#'));
        if (!body.empty() && body.back() == '\r') body.pop_back();
        std::vector<std::string> words;
        std::string cur;
        for (char c : body) {
            if (c == ' ' || c == '\t') {
                if (!cur.empty()) words.push_back(cur);
                cur.clear();
            } else {
                cur += c;
            }
        }
        if (!cur.empty()) words.push_back(cur);
        if (words.empty()) continue;      // blank line

        const std::string& d = words[0];
        if (d == "rule") {
            Rule r = parse_rule(line, words, rule_names);
            rule_names.insert(r.name);
            pack.rules.push_back(r);
            continue;
        }
        if (d != "pack" && d != "version" && d != "filter" && d != "window") fail(line, "unknown directive: " + d);
        if (!seen.insert(d).second) fail(line, "repeated directive: " + d);

        if (d == "pack" || d == "version") {
            if (words.size() != 2) fail(line, d + " takes exactly one value");
            (d == "pack" ? pack.name : pack.version) = words[1];
        } else if (d == "filter") {
            auto p = params(line, words, 1, {"accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms"});
            pack.filter.accel_var = number(line, "accel_var", p["accel_var"]);
            pack.filter.default_ce_m = number(line, "default_ce_m", p["default_ce_m"]);
            pack.filter.vel_sigma_ms = number(line, "vel_sigma_ms", p["vel_sigma_ms"]);
            pack.filter.unknown_vel_ms = number(line, "unknown_vel_ms", p["unknown_vel_ms"]);
            if (pack.filter.accel_var < 0) fail(line, "accel_var below 0");
            if (pack.filter.default_ce_m <= 0) fail(line, "default_ce_m 0 or below");
            if (pack.filter.vel_sigma_ms <= 0) fail(line, "vel_sigma_ms 0 or below");
            if (pack.filter.unknown_vel_ms <= 0) fail(line, "unknown_vel_ms 0 or below");
        } else {  // window
            auto p = params(line, words, 1, {"window_ms", "min_samples", "forget_ms"});
            pack.window_ms = integer(line, "window_ms", p["window_ms"]);
            pack.min_samples = integer(line, "min_samples", p["min_samples"]);
            pack.forget_ms = integer(line, "forget_ms", p["forget_ms"]);
            if (pack.window_ms < 1 || pack.min_samples < 1 || pack.forget_ms < 1)
                fail(line, "window value below 1");
        }
    }
    for (const char* d : {"pack", "version", "filter", "window"})
        if (!seen.count(d)) fail(line, std::string("missing directive: ") + d);
    return pack;
}

Pack load_pack(const std::string& dir) {
    std::ifstream f(dir + "/pack.def", std::ios::binary);
    if (!f) throw PackError("cannot read " + dir + "/pack.def");
    std::ostringstream ss;
    ss << f.rdbuf();
    return parse_pack(ss.str());
}

} // namespace corr::quality
