// The one entry point every function has (spec/README.md "What every
// function shares"): load the pack, then ingest one report at a time, tick,
// each returning its events and trace records, and snapshot.
//
// Each function's own module has the same shape, with its own Pack type:
//   Pack <fn>::load_pack(dir);  Pack <fn>::parse_pack(text);
//   <fn>::Engine e(pack);  e.ingest(report);  e.tick(now_ms);  e.snapshot();
// Function wraps any of them behind one interface, chosen by name.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "model/json.hpp"
#include "model/output.hpp"

namespace corr::io {

class Function {
public:
    virtual ~Function() = default;
    virtual Output ingest(const Json& report) = 0;
    virtual Output tick(std::int64_t now_ms) = 0;
    virtual Json snapshot() const = 0;
};

// The functions, by name: correlate, filter, fuse, quality.
const std::vector<std::string>& function_names();

// Loads <pack_dir>/pack.def as function `name`'s pack and creates its engine.
// Throws PackError when the pack does not load, std::invalid_argument for an
// unknown function.
std::unique_ptr<Function> load(const std::string& name, const std::string& pack_dir);

// The same from the text of a pack.def (load vectors).
std::unique_ptr<Function> parse(const std::string& name, const std::string& pack_def);

} // namespace corr::io
