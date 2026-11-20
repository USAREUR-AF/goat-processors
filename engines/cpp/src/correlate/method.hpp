// The correlate methods (correlate.md method `confirm`, correlate-assign.md
// method `assign`) and the one place they are registered: kMethods in
// methods.cpp. A method is what correlate does with an accepted report, on
// each tick and in its snapshot; the pack's `method` line selects it. Adding
// one is a class deriving from Method and one row of the table.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "correlate/core.hpp"

namespace corr::correlate {

class Method {
public:
    virtual ~Method() = default;

    // A report of entity `key`, after the required keys and before the
    // out-of-order check: the reason to reject it, or null to go on.
    virtual const char* refuse(const std::string& /*key*/) const { return nullptr; }
    // The entity's filter started again ("Restart").
    virtual void restarted(const std::string& /*key*/) {}
    // An accepted report of `a`, after its filter update.
    virtual void accepted(Entity& a, Output& out) = 0;
    virtual Output tick(std::int64_t now_ms) = 0;
    virtual Json snapshot() const = 0;
};

// One row of the table: the `method` value, the directives the method needs
// and those it refuses (correlate.md "Pack", correlate-assign.md "Pack"), and
// how it is made on the shared core.
struct MethodKind {
    const char* name;
    std::vector<const char*> required;
    std::vector<const char*> refused;
    std::unique_ptr<Method> (*make)(Core& core);
};

// Every method, in table order; the first is the default.
const std::vector<MethodKind>& methods();
// The method named `name`, or null.
const MethodKind* find_method(const std::string& name);

// A base for methods: the core's members and operations under their own names.
class CoreMethod : public Method {
protected:
    explicit CoreMethod(Core& core)
        : core_(core), pack_(core.pack_), ref_(core.ref_), entities_(core.entities_) {}

    Point to_plane(double lat, double lon) const { return core_.to_plane(lat, lon); }
    std::pair<double, double> to_degrees(double e, double n) const { return core_.to_degrees(e, n); }
    Filter predict(const Entity& e, std::int64_t t) const { return core_.predict(e, t); }
    Filter predict_for_comparison(const Entity& b, std::int64_t t) const {
        return core_.predict_for_comparison(b, t);
    }
    bool run_stage(const char* stage, const std::vector<TestSpec>& tests, const Entity& a, const Entity& b,
                   const Filter& bp, Output& out, const Json* extra = nullptr) const {
        return core_.run_stage(stage, tests, a, b, bp, out, extra);
    }
    bool is_stale(const Entity& e, std::int64_t now_ms) const { return core_.is_stale(e, now_ms); }
    void filter_json(const Entity& e, Json& into) const { core_.filter_json(e, into); }

    Core& core_;
    const Pack& pack_;
    const std::optional<std::pair<double, double>>& ref_;
    std::map<std::string, Entity>& entities_;
};

} // namespace corr::correlate
