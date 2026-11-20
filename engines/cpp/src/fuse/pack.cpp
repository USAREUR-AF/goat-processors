// fuse.md "Pack". Each rule of the section is marked where it is checked.
#include "fuse/pack.hpp"

#include <cerrno>
#include <cstdlib>
#include <map>
#include <set>
#include <sstream>

namespace corr::fuse {

namespace {

[[noreturn]] void fail(int line, const std::string& what) { pack_fail(line, what); }

bool is_digit(char c) { return c >= '0' && c <= '9'; }

// Advances i over one or more digits; false when there is none.
bool digits(const std::string& s, size_t& i) {
    size_t from = i;
    while (i < s.size() && is_digit(s[i])) ++i;
    return i > from;
}

// "A number is an optional `-`, one or more digits, optionally `.` and one or
// more digits, optionally `e` or `E`, an optional sign and one or more digits."
bool is_number(const std::string& s) {
    size_t i = 0;
    if (i < s.size() && s[i] == '-') ++i;
    if (!digits(s, i)) return false;
    if (i < s.size() && s[i] == '.') {
        ++i;
        if (!digits(s, i)) return false;
    }
    if (i < s.size() && (s[i] == 'e' || s[i] == 'E')) {
        ++i;
        if (i < s.size() && (s[i] == '+' || s[i] == '-')) ++i;
        if (!digits(s, i)) return false;
    }
    return i == s.size();
}

// "An integer is one or more digits."
bool is_integer(const std::string& s) {
    size_t i = 0;
    return digits(s, i) && i == s.size();
}

double parse_number(int line, const std::string& s) {
    if (!is_number(s)) fail(line, "not a number: " + s);
    return std::strtod(s.c_str(), nullptr);
}

std::int64_t parse_integer(int line, const std::string& s) {
    if (!is_integer(s)) fail(line, "not an integer: " + s);
    errno = 0;
    long long v = std::strtoll(s.c_str(), nullptr, 10);
    if (errno == ERANGE) fail(line, "integer out of range: " + s);
    return v;
}

// "A line is split on runs of spaces and tabs."
std::vector<std::string> split_words(const std::string& line) {
    std::vector<std::string> words;
    std::string cur;
    for (char c : line) {
        if (c == ' ' || c == '\t') {
            if (!cur.empty()) words.push_back(cur), cur.clear();
        } else {
            cur += c;
        }
    }
    if (!cur.empty()) words.push_back(cur);
    return words;
}

// "the wrong number of values"
void want_values(int line, const std::vector<std::string>& words, size_t n) {
    if (words.size() != n + 1) fail(line, words[0] + " takes " + std::to_string(n) + " value(s)");
}

// `filter`: "exactly the four parameters, each `name=value`, each a number".
// A parameter with no `=`, unknown, repeated or missing is an error.
FilterParams parse_filter(int line, const std::vector<std::string>& words) {
    static const char* const names[] = {"accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms"};
    std::map<std::string, double> got;
    for (size_t k = 1; k < words.size(); ++k) {
        size_t eq = words[k].find('=');
        if (eq == std::string::npos) fail(line, "parameter without '=': " + words[k]);
        std::string name = words[k].substr(0, eq);
        bool known = false;
        for (const char* n : names) known = known || name == n;
        if (!known) fail(line, "unknown parameter: " + name);
        if (got.count(name)) fail(line, "repeated parameter: " + name);
        got[name] = parse_number(line, words[k].substr(eq + 1));
    }
    for (const char* n : names)
        if (!got.count(n)) fail(line, std::string("missing parameter: ") + n);
    FilterParams f;
    f.accel_var = got["accel_var"];
    f.default_ce_m = got["default_ce_m"];
    f.vel_sigma_ms = got["vel_sigma_ms"];
    f.unknown_vel_ms = got["unknown_vel_ms"];
    // "`default_ce_m`, `vel_sigma_ms`, `unknown_vel_ms` above 0, `accel_var` 0 or above"
    if (!(f.default_ce_m > 0) || !(f.vel_sigma_ms > 0) || !(f.unknown_vel_ms > 0))
        fail(line, "default_ce_m, vel_sigma_ms and unknown_vel_ms must be above 0");
    if (!(f.accel_var >= 0)) fail(line, "accel_var must be 0 or above");
    return f;
}

Method parse_method(int line, const std::string& s) {
    if (s == "inverse_variance") return Method::InverseVariance;
    if (s == "covariance_intersection") return Method::CovarianceIntersection;
    if (s == "best") return Method::Best;
    if (s == "priority") return Method::Priority;
    if (s == "latest") return Method::Latest;
    fail(line, "unknown kinematics method: " + s);
}

Rule parse_rule(int line, const std::string& s) {
    if (s == "priority") return Rule::Priority;
    if (s == "latest") return Rule::Latest;
    if (s == "majority") return Rule::Majority;
    if (s == "max") return Rule::Max;
    if (s == "min") return Rule::Min;
    fail(line, "unknown attribute rule: " + s);
}

} // namespace

const char* method_name(Method m) {
    switch (m) {
        case Method::InverseVariance: return "inverse_variance";
        case Method::CovarianceIntersection: return "covariance_intersection";
        case Method::Best: return "best";
        case Method::Priority: return "priority";
        case Method::Latest: return "latest";
    }
    return "";
}

const char* rule_name(Rule r) {
    switch (r) {
        case Rule::Priority: return "priority";
        case Rule::Latest: return "latest";
        case Rule::Majority: return "majority";
        case Rule::Max: return "max";
        case Rule::Min: return "min";
    }
    return "";
}

Pack parse_pack(const std::string& text) {
    Pack p;
    std::set<std::string> once_seen;          // once-only directives already read
    std::set<std::string> attribute_keys, sources;
    std::istringstream in(text);
    std::string raw;
    int line = 0;
    while (std::getline(in, raw, '\n')) {     // "Lines are separated by LF"
        ++line;
        if (!raw.empty() && raw.back() == '\r') raw.pop_back();   // "a CR at the end of a line is removed"
        size_t hash = raw.find('#');                               // "`#` starts a comment"
        if (hash != std::string::npos) raw.erase(hash);
        std::vector<std::string> words = split_words(raw);
        if (words.empty()) continue;                               // "a line with nothing left is ignored"

        const std::string& d = words[0];
        bool once = d == "pack" || d == "version" || d == "filter" || d == "kinematics" || d == "stale_ms";
        if (once && !once_seen.insert(d).second) fail(line, "repeated directive: " + d);

        if (d == "pack") {
            want_values(line, words, 1);
            p.name = words[1];
        } else if (d == "version") {
            want_values(line, words, 1);
            p.version = words[1];
        } else if (d == "filter") {
            p.filter = parse_filter(line, words);
        } else if (d == "kinematics") {
            want_values(line, words, 1);
            p.kinematics = parse_method(line, words[1]);
        } else if (d == "stale_ms") {
            want_values(line, words, 1);
            p.stale_ms = parse_integer(line, words[1]);   // "one integer, 0 or above"
        } else if (d == "attribute") {
            // "a key, then exactly `rule=<rule>`"
            want_values(line, words, 2);
            const std::string& key = words[1];
            if (key.find('=') != std::string::npos) fail(line, "attribute key holds '=': " + key);
            if (words[2].rfind("rule=", 0) != 0) fail(line, "attribute takes rule=<rule>: " + words[2]);
            Rule rule = parse_rule(line, words[2].substr(5));
            if (!attribute_keys.insert(key).second) fail(line, "attribute key on two lines: " + key);
            p.attributes.push_back({key, rule});
        } else if (d == "source") {
            want_values(line, words, 1);
            if (!sources.insert(words[1]).second) fail(line, "source on two lines: " + words[1]);
            p.sources.push_back(words[1]);
        } else {
            fail(line, "unknown directive: " + d);
        }
    }
    for (const char* req : {"pack", "version", "filter", "kinematics", "stale_ms"})
        if (!once_seen.count(req)) throw PackError(std::string("pack.def: missing directive ") + req);
    return p;
}

Pack load_pack(const std::string& dir) { return parse_pack(read_pack_def(dir)); }

} // namespace corr::fuse
