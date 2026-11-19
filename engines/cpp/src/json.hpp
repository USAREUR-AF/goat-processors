// A small JSON value, reader and writer. Objects keep keys in ascending
// byte order (std::map), which is the spec's "key order".
#pragma once

#include <cstdint>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace corr {

struct Json {
    enum class Kind { Null, Bool, Number, String, Array, Object };

    Kind kind = Kind::Null;
    bool boolean = false;
    double number = 0.0;
    bool is_int = false;     // the number was written without fraction or exponent
    std::int64_t integer = 0; // exact value when is_int
    std::string string;
    std::vector<Json> array;
    std::map<std::string, Json> object;

    Json() = default;
    Json(std::nullptr_t) {}
    Json(bool b) : kind(Kind::Bool), boolean(b) {}
    Json(int i) : Json(static_cast<long long>(i)) {}
    Json(long i) : Json(static_cast<long long>(i)) {}
    Json(long long i) : kind(Kind::Number), number(static_cast<double>(i)), is_int(true), integer(i) {}
    Json(double d) : kind(Kind::Number), number(d) {}
    Json(const char* s) : kind(Kind::String), string(s) {}
    Json(std::string s) : kind(Kind::String), string(std::move(s)) {}

    static Json make_array() { Json j; j.kind = Kind::Array; return j; }
    static Json make_object() { Json j; j.kind = Kind::Object; return j; }

    bool is_null() const { return kind == Kind::Null; }
    bool is_number() const { return kind == Kind::Number; }
    bool is_string() const { return kind == Kind::String; }
    bool is_object() const { return kind == Kind::Object; }
    bool is_array() const { return kind == Kind::Array; }

    // Object access; makes this an object if it was null.
    Json& operator[](const std::string& key);
    bool has(const std::string& key) const;
    const Json* find(const std::string& key) const;

    void push(Json v);
};

struct JsonError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

Json parse_json(const std::string& text);
std::string to_json(const Json& v);

// Exact value equality: numbers by value, strings byte for byte.
bool json_equal(const Json& a, const Json& b);

} // namespace corr
