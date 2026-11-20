// A small JSON value, reader and writer. Objects keep keys in ascending
// byte order, which is the spec's "key order": a JsonObject is one sorted
// array of (key, value), so building a record allocates once per object, not
// once per key.
#pragma once

#include <cstdint>
#include <algorithm>
#include <stdexcept>
#include <string>
#include <vector>

namespace corr {

struct Json;

// The members of a JSON object, in ascending byte order of their keys, with
// the operations of a std::map that the engine uses.
class JsonObject {
public:
    using value_type = std::pair<std::string, Json>;
    using iterator = std::vector<value_type>::iterator;
    using const_iterator = std::vector<value_type>::const_iterator;
    using const_reverse_iterator = std::vector<value_type>::const_reverse_iterator;

    // The value of `key`, inserted (null) in key order when absent.
    Json& operator[](const std::string& key);
    const_iterator find(const std::string& key) const;
    size_t count(const std::string& key) const;
    size_t erase(const std::string& key);
    size_t size() const;
    bool empty() const;

    iterator begin();
    iterator end();
    const_iterator begin() const;
    const_iterator end() const;
    const_reverse_iterator rbegin() const;
    const_reverse_iterator rend() const;

private:
    // The first member whose key is not below `key`.
    const_iterator lower(const std::string& key) const;

    std::vector<value_type> items_;
};

struct Json {
    enum class Kind { Null, Bool, Number, String, Array, Object };

    Kind kind = Kind::Null;
    bool boolean = false;
    double number = 0.0;
    bool is_int = false;     // the number was written without fraction or exponent
    std::int64_t integer = 0; // exact value when is_int
    std::string string;
    std::vector<Json> array;
    JsonObject object;

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

inline JsonObject::const_iterator JsonObject::lower(const std::string& key) const {
    return std::lower_bound(items_.begin(), items_.end(), key,
                            [](const value_type& kv, const std::string& k) { return kv.first < k; });
}
inline size_t JsonObject::count(const std::string& key) const { return find(key) != end() ? 1 : 0; }
inline size_t JsonObject::size() const { return items_.size(); }
inline bool JsonObject::empty() const { return items_.empty(); }
inline JsonObject::iterator JsonObject::begin() { return items_.begin(); }
inline JsonObject::iterator JsonObject::end() { return items_.end(); }
inline JsonObject::const_iterator JsonObject::begin() const { return items_.begin(); }
inline JsonObject::const_iterator JsonObject::end() const { return items_.end(); }
inline JsonObject::const_reverse_iterator JsonObject::rbegin() const { return items_.rbegin(); }
inline JsonObject::const_reverse_iterator JsonObject::rend() const { return items_.rend(); }

inline Json& JsonObject::operator[](const std::string& key) {
    auto it = lower(key);
    if (it != items_.end() && it->first == key) return items_[static_cast<size_t>(it - items_.begin())].second;
    return items_.insert(items_.begin() + (it - items_.begin()), value_type(key, Json()))->second;
}

inline JsonObject::const_iterator JsonObject::find(const std::string& key) const {
    auto it = lower(key);
    return it != items_.end() && it->first == key ? it : items_.end();
}

inline size_t JsonObject::erase(const std::string& key) {
    auto it = find(key);
    if (it == items_.end()) return 0;
    items_.erase(it);
    return 1;
}

struct JsonError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

Json parse_json(const std::string& text);
std::string to_json(const Json& v);

// Exact value equality: numbers by value, strings byte for byte.
bool json_equal(const Json& a, const Json& b);

} // namespace corr
