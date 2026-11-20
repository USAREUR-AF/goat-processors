// A seeded generator for the property and fuzz tests: xorshift64*, so a
// run is the same on every machine and every run.
#pragma once

#include <cstdint>
#include <string>

namespace support {

class Random {
public:
    explicit Random(std::uint64_t seed) : s_(seed ? seed : 0x9e3779b97f4a7c15ULL) {}
    std::uint64_t next() {
        s_ ^= s_ >> 12;
        s_ ^= s_ << 25;
        s_ ^= s_ >> 27;
        return s_ * 0x2545f4914f6cdd1dULL;
    }
    // Uniform in [0, n).
    std::uint64_t below(std::uint64_t n) { return n ? next() % n : 0; }
    double unit() { return static_cast<double>(next() >> 11) / 9007199254740992.0; }
    bool chance(double p) { return unit() < p; }

private:
    std::uint64_t s_;
};

} // namespace support
