// A small test harness for the engine's own tests (standard library only).
// TEST(module, name) registers a case; CHECK and CHECK_EQ fail it. The
// runner (test/unit_main.cpp) runs every case whose module is named on the
// command line, or every case.
#pragma once

#include <cmath>
#include <functional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace check {

struct Case {
    std::string module, name;
    std::function<void()> fn;
};

inline std::vector<Case>& cases() {
    static std::vector<Case> all;
    return all;
}

struct Register {
    Register(const char* module, const char* name, std::function<void()> fn) {
        cases().push_back({module, name, std::move(fn)});
    }
};

struct Failure : std::runtime_error {
    using std::runtime_error::runtime_error;
};

template <typename A, typename B>
void equal(const A& a, const B& b, const char* ea, const char* eb, const char* file, int line) {
    if (a == b) return;
    std::ostringstream m;
    m << file << ":" << line << ": CHECK_EQ(" << ea << ", " << eb << ")";
    if constexpr (std::is_arithmetic_v<A> || std::is_same_v<A, std::string>) m << " got " << a;
    if constexpr (std::is_arithmetic_v<B> || std::is_same_v<B, std::string>) m << " want " << b;
    throw Failure(m.str());
}

} // namespace check

#define CHECK_CAT2(a, b) a##b
#define CHECK_CAT(a, b) CHECK_CAT2(a, b)
#define TEST(module, name)                                                                          \
    static void CHECK_CAT(test_, CHECK_CAT(module, CHECK_CAT(_, name)))();                          \
    static check::Register CHECK_CAT(reg_, CHECK_CAT(module, CHECK_CAT(_, name)))(                  \
        #module, #name, CHECK_CAT(test_, CHECK_CAT(module, CHECK_CAT(_, name))));                   \
    static void CHECK_CAT(test_, CHECK_CAT(module, CHECK_CAT(_, name)))()
#define CHECK(cond)                                                                                 \
    do {                                                                                            \
        if (!(cond))                                                                                \
            throw check::Failure(std::string(__FILE__) + ":" + std::to_string(__LINE__) + ": CHECK(" \
                                 #cond ")");                                                        \
    } while (0)
#define CHECK_EQ(a, b) check::equal((a), (b), #a, #b, __FILE__, __LINE__)
// The call must throw an exception of type T.
#define CHECK_THROWS(T, expr)                                                                       \
    do {                                                                                            \
        bool thrown_ = false;                                                                       \
        try {                                                                                       \
            (void)(expr);                                                                           \
        } catch (const T&) {                                                                        \
            thrown_ = true;                                                                         \
        }                                                                                           \
        if (!thrown_)                                                                               \
            throw check::Failure(std::string(__FILE__) + ":" + std::to_string(__LINE__) +           \
                                 ": no exception from " #expr);                                     \
    } while (0)
