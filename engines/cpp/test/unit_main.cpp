// Runs the engine's unit, property and fuzz tests (test/test_*.cpp).
// Usage: unit_tests [module ...]   (no module: every case)
#include <iostream>
#include <set>
#include <string>

#include "check.hpp"

int main(int argc, char** argv) {
    std::set<std::string> want(argv + 1, argv + argc);
    int run = 0, failed = 0;
    for (const check::Case& c : check::cases()) {
        if (!want.empty() && !want.count(c.module)) continue;
        ++run;
        try {
            c.fn();
            std::cout << "PASS " << c.module << "." << c.name << "\n";
        } catch (const std::exception& e) {
            ++failed;
            std::cout << "FAIL " << c.module << "." << c.name << "\n     " << e.what() << "\n";
        }
    }
    std::cout << (run - failed) << "/" << run << " tests pass\n";
    return failed == 0 && run > 0 ? 0 : 1;
}
