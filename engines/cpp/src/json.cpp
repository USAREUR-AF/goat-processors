#include "json.hpp"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace corr {

Json& Json::operator[](const std::string& key) {
    if (kind == Kind::Null) kind = Kind::Object;
    return object[key];
}

bool Json::has(const std::string& key) const {
    return kind == Kind::Object && object.count(key) != 0;
}

const Json* Json::find(const std::string& key) const {
    if (kind != Kind::Object) return nullptr;
    auto it = object.find(key);
    return it == object.end() ? nullptr : &it->second;
}

void Json::push(Json v) {
    if (kind == Kind::Null) kind = Kind::Array;
    array.push_back(std::move(v));
}

namespace {

struct Reader {
    const std::string& s;
    size_t i = 0;

    [[noreturn]] void fail(const char* what) {
        throw JsonError(std::string("json: ") + what + " at offset " + std::to_string(i));
    }
    void ws() {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) ++i;
    }
    bool eat(char c) {
        ws();
        if (i < s.size() && s[i] == c) { ++i; return true; }
        return false;
    }
    void expect(char c) {
        if (!eat(c)) fail("unexpected character");
    }
    void literal(const char* word) {
        size_t n = std::strlen(word);
        if (s.compare(i, n, word) != 0) fail("bad literal");
        i += n;
    }

    static void put_utf8(std::string& out, unsigned cp) {
        if (cp < 0x80) {
            out += static_cast<char>(cp);
        } else if (cp < 0x800) {
            out += static_cast<char>(0xC0 | (cp >> 6));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out += static_cast<char>(0xE0 | (cp >> 12));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        } else {
            out += static_cast<char>(0xF0 | (cp >> 18));
            out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
            out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
            out += static_cast<char>(0x80 | (cp & 0x3F));
        }
    }
    unsigned hex4() {
        if (i + 4 > s.size()) fail("short \\u escape");
        unsigned v = 0;
        for (int k = 0; k < 4; ++k) {
            char c = s[i++];
            v <<= 4;
            if (c >= '0' && c <= '9') v |= c - '0';
            else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
            else fail("bad \\u escape");
        }
        return v;
    }
    std::string str() {
        expect('"');
        std::string out;
        while (true) {
            if (i >= s.size()) fail("unterminated string");
            char c = s[i++];
            if (c == '"') return out;
            if (c != '\\') { out += c; continue; }
            if (i >= s.size()) fail("unterminated escape");
            char e = s[i++];
            switch (e) {
                case '"': out += '"'; break;
                case '\\': out += '\\'; break;
                case '/': out += '/'; break;
                case 'b': out += '\b'; break;
                case 'f': out += '\f'; break;
                case 'n': out += '\n'; break;
                case 'r': out += '\r'; break;
                case 't': out += '\t'; break;
                case 'u': {
                    unsigned cp = hex4();
                    if (cp >= 0xD800 && cp < 0xDC00 && s.compare(i, 2, "\\u") == 0) {
                        i += 2;
                        unsigned lo = hex4();
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    put_utf8(out, cp);
                    break;
                }
                default: fail("bad escape");
            }
        }
    }
    Json number() {
        size_t start = i;
        bool integral = true;
        if (s[i] == '-') ++i;
        while (i < s.size() && std::strchr("0123456789.eE+-", s[i])) {
            if (s[i] == '.' || s[i] == 'e' || s[i] == 'E') integral = false;
            ++i;
        }
        std::string text = s.substr(start, i - start);
        char* end = nullptr;
        if (integral) {
            errno = 0;
            long long v = std::strtoll(text.c_str(), &end, 10);
            if (*end != '\0') fail("bad number");
            if (errno != ERANGE) return Json(v);
            // Outside int64: kept as a number that is not an integer.
        }
        double d = std::strtod(text.c_str(), &end);
        if (*end != '\0') fail("bad number");
        return Json(d);
    }
    Json value() {
        ws();
        if (i >= s.size()) fail("unexpected end");
        char c = s[i];
        if (c == '{') {
            ++i;
            Json o = Json::make_object();
            if (eat('}')) return o;
            do {
                ws();
                std::string k = str();
                expect(':');
                o.object[k] = value();
            } while (eat(','));
            expect('}');
            return o;
        }
        if (c == '[') {
            ++i;
            Json a = Json::make_array();
            if (eat(']')) return a;
            do { a.array.push_back(value()); } while (eat(','));
            expect(']');
            return a;
        }
        if (c == '"') return Json(str());
        if (c == 't') { literal("true"); return Json(true); }
        if (c == 'f') { literal("false"); return Json(false); }
        if (c == 'n') { literal("null"); return Json(); }
        if (c == '-' || (c >= '0' && c <= '9')) return number();
        fail("unexpected character");
    }
};

void write(std::string& out, const Json& v) {
    switch (v.kind) {
        case Json::Kind::Null: out += "null"; break;
        case Json::Kind::Bool: out += v.boolean ? "true" : "false"; break;
        case Json::Kind::Number: {
            if (v.is_int) { out += std::to_string(v.integer); break; }
            char buf[32];
            std::snprintf(buf, sizeof buf, "%.17g", v.number);
            out += buf;
            break;
        }
        case Json::Kind::String: {
            out += '"';
            for (char c : v.string) {
                if (c == '"' || c == '\\') { out += '\\'; out += c; }
                else if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof buf, "\\u%04x", c);
                    out += buf;
                } else out += c;
            }
            out += '"';
            break;
        }
        case Json::Kind::Array: {
            out += '[';
            for (size_t k = 0; k < v.array.size(); ++k) {
                if (k) out += ',';
                write(out, v.array[k]);
            }
            out += ']';
            break;
        }
        case Json::Kind::Object: {
            out += '{';
            bool first = true;
            for (const auto& kv : v.object) {
                if (!first) out += ',';
                first = false;
                write(out, Json(kv.first));
                out += ':';
                write(out, kv.second);
            }
            out += '}';
            break;
        }
    }
}

} // namespace

Json parse_json(const std::string& text) {
    Reader r{text};
    Json v = r.value();
    r.ws();
    if (r.i != text.size()) r.fail("trailing characters");
    return v;
}

std::string to_json(const Json& v) {
    std::string out;
    write(out, v);
    return out;
}

bool json_equal(const Json& a, const Json& b) {
    if (a.kind != b.kind) return false;
    switch (a.kind) {
        case Json::Kind::Null: return true;
        case Json::Kind::Bool: return a.boolean == b.boolean;
        case Json::Kind::Number:
            if (a.is_int && b.is_int) return a.integer == b.integer;
            return a.number == b.number;
        case Json::Kind::String: return a.string == b.string;
        case Json::Kind::Array:
            if (a.array.size() != b.array.size()) return false;
            for (size_t k = 0; k < a.array.size(); ++k)
                if (!json_equal(a.array[k], b.array[k])) return false;
            return true;
        case Json::Kind::Object:
            if (a.object.size() != b.object.size()) return false;
            for (const auto& kv : a.object) {
                const Json* o = b.find(kv.first);
                if (!o || !json_equal(kv.second, *o)) return false;
            }
            return true;
    }
    return false;
}

} // namespace corr
