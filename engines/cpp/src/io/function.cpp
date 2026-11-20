#include "io/function.hpp"

#include <stdexcept>
#include <utility>

#include "correlate/engine.hpp"
#include "filter/engine.hpp"
#include "fuse/engine.hpp"
#include "model/pack_text.hpp"
#include "quality/engine.hpp"

namespace corr::io {

namespace {

template <typename Engine>
class Wrapped final : public Function {
public:
    template <typename Pack>
    explicit Wrapped(Pack pack) : engine_(std::move(pack)) {}
    Output ingest(const Json& report) override { return engine_.ingest(report); }
    Output tick(std::int64_t now_ms) override { return engine_.tick(now_ms); }
    Json snapshot() const override { return engine_.snapshot(); }

private:
    Engine engine_;
};

// One row per function: its name and how its pack is read from text.
struct Entry {
    const char* name;
    std::unique_ptr<Function> (*from_text)(const std::string& text);
};

template <typename Engine, typename Pack, Pack (*Parse)(const std::string&)>
std::unique_ptr<Function> make(const std::string& text) {
    return std::make_unique<Wrapped<Engine>>(Parse(text));
}

const Entry kFunctions[] = {
    {"correlate", make<correlate::Engine, correlate::Pack, correlate::parse_pack>},
    {"filter", make<filter::Engine, filter::Pack, filter::parse_pack>},
    {"fuse", make<fuse::Engine, fuse::Pack, fuse::parse_pack>},
    {"quality", make<quality::Engine, quality::Pack, quality::parse_pack>},
};

const Entry& entry(const std::string& name) {
    for (const Entry& e : kFunctions)
        if (name == e.name) return e;
    throw std::invalid_argument("unknown function: " + name);
}

} // namespace

const std::vector<std::string>& function_names() {
    static const std::vector<std::string> names = [] {
        std::vector<std::string> n;
        for (const Entry& e : kFunctions) n.push_back(e.name);
        return n;
    }();
    return names;
}

std::unique_ptr<Function> load(const std::string& name, const std::string& pack_dir) {
    const Entry& e = entry(name);
    return e.from_text(read_pack_def(pack_dir));
}

std::unique_ptr<Function> parse(const std::string& name, const std::string& pack_def) {
    return entry(name).from_text(pack_def);
}

} // namespace corr::io
