// spec/filter.md "Pack".
#include "filter_pack.hpp"

#include <cstdlib>
#include <fstream>
#include <map>
#include <set>
#include <sstream>

namespace corr::filter {

namespace {

[[noreturn]] void fail(int line, const std::string& what) {
    throw PackError("pack.def line " + std::to_string(line) + ": " + what);
}

// ---- Values ----------------------------------------------------------------

// number: `-?[0-9]+(\.[0-9]+)?`, read as the nearest binary64.
double number(int line, const std::string& s) {
    if (!is_pack_number(s)) fail(line, "not a number: " + s);
    return std::strtod(s.c_str(), nullptr);
}

// integer: `[0-9]+`, at most 9223372036854775807.
std::int64_t integer(int line, const std::string& s) {
    if (s.empty()) fail(line, "not an integer: " + s);
    for (char c : s)
        if (c < '0' || c > '9') fail(line, "not an integer: " + s);
    size_t first = s.find_first_not_of('0');
    std::string digits = first == std::string::npos ? "0" : s.substr(first);
    const std::string max = "9223372036854775807";
    if (digits.size() > max.size() || (digits.size() == max.size() && digits > max))
        fail(line, "integer above 9223372036854775807: " + s);
    return std::strtoll(digits.c_str(), nullptr, 10);
}

double lat_value(int line, const std::string& s) {
    double v = number(line, s);
    if (v < -90 || v > 90) fail(line, "lat outside -90..90: " + s);
    return v;
}

double lon_value(int line, const std::string& s) {
    double v = number(line, s);
    if (v < -180 || v > 180) fail(line, "lon outside -180..180: " + s);
    return v;
}

// Splits on `sep`, keeping empty pieces.
std::vector<std::string> split(const std::string& s, char sep) {
    std::vector<std::string> parts(1);
    for (char c : s) {
        if (c == sep) parts.emplace_back();
        else parts.back() += c;
    }
    return parts;
}

// in: one or more non-empty items separated by `,`.
std::vector<std::string> list_value(int line, const std::string& s) {
    std::vector<std::string> items = split(s, ',');
    for (const auto& item : items)
        if (item.empty()) fail(line, "empty list item: " + s);
    return items;
}

// vertices: `<lat>,<lon>;<lat>,<lon>;...` with at least three pairs.
std::vector<std::pair<double, double>> vertices_value(int line, const std::string& s) {
    std::vector<std::pair<double, double>> out;
    for (const auto& pair : split(s, ';')) {
        std::vector<std::string> ll = split(pair, ',');
        if (ll.size() != 2) fail(line, "vertex is not <lat>,<lon>: " + pair);
        out.emplace_back(lat_value(line, ll[0]), lon_value(line, ll[1]));
    }
    if (out.size() < 3) fail(line, "polygon needs at least three vertices");
    return out;
}

// reference, name, eq: a non-empty token.
std::string token_value(int line, const std::string& param, const std::string& s) {
    if (s.empty()) fail(line, param + " is empty");
    return s;
}

// ---- Conditions ------------------------------------------------------------

// Parameter sets: each entry is one accepted set of parameter names.
const std::map<std::string, std::vector<std::set<std::string>>>& parameter_sets() {
    static const std::map<std::string, std::vector<std::set<std::string>>> table = {
        {"circle", {{"lat", "lon", "radius_m"}}},
        {"polygon", {{"vertices"}}},
        {"near", {{"reference", "radius_m", "max_age_ms"}}},
        {"env", {{"in"}}},
        {"affiliation", {{"in"}}},
        {"source", {{"in"}}},
        {"uid", {{"in"}}},
        {"key", {{"name", "eq"}, {"name", "in"}, {"name", "min"}, {"name", "max"}, {"name", "min", "max"}}},
        {"has", {{"name"}}},
        {"speed", {{"min"}, {"max"}, {"min", "max"}}},
        {"altitude", {{"min"}, {"max"}, {"min", "max"}}},
        {"interval", {{"min_ms"}}},
        {"order", {{}}},
    };
    return table;
}

// `min` and/or `max`; both inclusive, min <= max when both are given.
void range_values(int line, std::map<std::string, std::string>& p, Condition& c) {
    if (p.count("min")) c.min = number(line, p["min"]);
    if (p.count("max")) c.max = number(line, p["max"]);
    if (c.min && c.max && !(*c.min <= *c.max)) fail(line, "min above max");
}

// `when [not] <condition> <param>=<value> ...`
Condition parse_when(int line, const std::vector<std::string>& words) {
    size_t k = 1;
    Condition c;
    if (k < words.size() && words[k] == "not") {
        c.negated = true;
        ++k;
    }
    if (k >= words.size()) fail(line, "when without a condition");
    c.test = words[k++];
    auto sets = parameter_sets().find(c.test);
    if (sets == parameter_sets().end()) fail(line, "unknown condition: " + c.test);

    // name=value: the name is the text before the first `=`, the value the rest.
    std::map<std::string, std::string> p;
    std::set<std::string> given;
    for (; k < words.size(); ++k) {
        size_t eq = words[k].find('=');
        if (eq == std::string::npos) fail(line, "parameter without '=': " + words[k]);
        std::string name = words[k].substr(0, eq);
        if (!p.emplace(name, words[k].substr(eq + 1)).second) fail(line, "parameter given twice: " + name);
        given.insert(name);
    }
    bool matches_a_set = false;
    for (const auto& set : sets->second) matches_a_set = matches_a_set || set == given;
    if (!matches_a_set) fail(line, "parameters do not match the set of " + c.test);

    const std::string& t = c.test;
    if (t == "circle") {
        c.lat = lat_value(line, p["lat"]);
        c.lon = lon_value(line, p["lon"]);
        c.radius_m = number(line, p["radius_m"]);
        if (c.radius_m < 0) fail(line, "radius_m below 0");
    } else if (t == "polygon") {
        c.vertices = vertices_value(line, p["vertices"]);
    } else if (t == "near") {
        c.reference = token_value(line, "reference", p["reference"]);
        c.radius_m = number(line, p["radius_m"]);
        if (c.radius_m < 0) fail(line, "radius_m below 0");
        c.max_age_ms = integer(line, p["max_age_ms"]);
    } else if (t == "env" || t == "affiliation" || t == "source" || t == "uid") {
        c.in = list_value(line, p["in"]);
    } else if (t == "key") {
        c.name = token_value(line, "name", p["name"]);
        if (p.count("eq")) {
            c.key_form = Condition::KeyForm::Eq;
            c.eq = token_value(line, "eq", p["eq"]);
        } else if (p.count("in")) {
            c.key_form = Condition::KeyForm::In;
            c.in = list_value(line, p["in"]);
        } else {
            c.key_form = Condition::KeyForm::Range;
            range_values(line, p, c);
        }
    } else if (t == "has") {
        c.name = token_value(line, "name", p["name"]);
    } else if (t == "speed" || t == "altitude") {
        range_values(line, p, c);
    } else if (t == "interval") {
        c.min_ms = integer(line, p["min_ms"]);
        if (c.min_ms <= 0) fail(line, "min_ms must be above 0");
    }
    // order: no parameters.
    return c;
}

bool action(int line, const std::string& s) {
    if (s == "keep") return true;
    if (s == "drop") return false;
    fail(line, "action is keep or drop: " + s);
}

} // namespace

bool is_pack_number(const std::string& s) {
    size_t i = 0;
    if (i < s.size() && s[i] == '-') ++i;
    size_t int_digits = 0;
    while (i < s.size() && s[i] >= '0' && s[i] <= '9') { ++i; ++int_digits; }
    if (int_digits == 0) return false;
    if (i < s.size() && s[i] == '.') {
        ++i;
        size_t frac_digits = 0;
        while (i < s.size() && s[i] >= '0' && s[i] <= '9') { ++i; ++frac_digits; }
        if (frac_digits == 0) return false;
    }
    return i == s.size();
}

Pack parse_pack(const std::string& text) {
    Pack p;
    std::set<std::string> seen;   // pack, version, default, forget_ms
    std::set<std::string> rule_names;
    std::istringstream in(text);
    std::string raw;
    int line = 0;
    while (std::getline(in, raw)) {
        ++line;
        // `#` starts a comment; words are separated by spaces or tabs.
        size_t hash = raw.find('#');
        if (hash != std::string::npos) raw.erase(hash);
        std::vector<std::string> words;
        std::string cur;
        for (char c : raw + " ") {
            if (c == ' ' || c == '\t' || c == '\r') {
                if (!cur.empty()) words.push_back(cur);
                cur.clear();
            } else {
                cur += c;
            }
        }
        if (words.empty()) continue;

        const std::string& d = words[0];
        auto once = [&](size_t args) {
            if (!seen.insert(d).second) fail(line, "repeated directive: " + d);
            if (words.size() != args + 1) fail(line, d + " takes " + std::to_string(args) + " argument(s)");
        };
        if (d == "pack") {
            once(1);
            p.name = words[1];
        } else if (d == "version") {
            once(1);
            p.version = words[1];
        } else if (d == "default") {
            once(1);
            p.default_keep = action(line, words[1]);
        } else if (d == "forget_ms") {
            once(1);
            p.forget_ms = integer(line, words[1]);
            if (p.forget_ms <= 0) fail(line, "forget_ms must be above 0");
        } else if (d == "rule") {
            if (words.size() != 3) fail(line, "rule takes a name and an action");
            Rule r;
            r.name = words[1];
            if (r.name == "default") fail(line, "a rule may not be named default");
            if (!rule_names.insert(r.name).second) fail(line, "two rules named " + r.name);
            r.keep = action(line, words[2]);
            p.rules.push_back(r);
        } else if (d == "when") {
            if (p.rules.empty()) fail(line, "when before the first rule");
            p.rules.back().when.push_back(parse_when(line, words));
        } else {
            fail(line, "unknown directive: " + d);
        }
    }
    for (const char* req : {"pack", "version", "default", "forget_ms"})
        if (!seen.count(req)) throw PackError(std::string("pack.def: missing directive ") + req);
    for (const auto& r : p.rules)
        if (r.when.empty()) throw PackError("pack.def: rule " + r.name + " has no when line");
    return p;
}

Pack load_pack(const std::string& dir) {
    std::ifstream f(dir + "/pack.def", std::ios::binary);
    if (!f) throw PackError("cannot read " + dir + "/pack.def");
    std::ostringstream ss;
    ss << f.rdbuf();
    return parse_pack(ss.str());
}

} // namespace corr::filter
