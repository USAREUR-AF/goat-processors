// What the engine's own tests share: paths, running a list of steps through
// an engine, and building reports.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "io/files.hpp"
#include "model/json.hpp"
#include "model/output.hpp"

namespace support {

using corr::Json;

inline std::string repo(const std::string& rel) { return std::string(CORR_REPO_ROOT) + "/" + rel; }
inline std::string fixture(const std::string& rel) { return std::string(CORR_TEST_DIR) + "/fixtures/" + rel; }

inline Json read_json(const std::string& path) { return corr::parse_json(corr::io::read_file(path)); }

// Everything an engine returns for a list of steps, then its snapshot.
struct Run {
    std::vector<corr::Output> outputs;
    Json snapshot;

    // The whole run as one JSON text: equal runs give equal texts.
    std::string text() const {
        std::string s;
        for (const auto& o : outputs) s += corr::to_json(o.events) + corr::to_json(o.trace) + "\n";
        return s + corr::to_json(snapshot);
    }
};

template <typename Engine>
Run run_steps(Engine& engine, const std::vector<Json>& steps) {
    Run run;
    for (const Json& step : steps) {
        const Json* ingest = step.find("ingest");
        run.outputs.push_back(ingest ? engine.ingest(*ingest) : engine.tick(step.find("tick")->integer));
    }
    run.snapshot = engine.snapshot();
    return run;
}

// The steps of a vector or steps file.
inline std::vector<Json> steps_of(const Json& doc) { return doc.find("steps")->array; }

// A report with the required keys.
inline Json report(const std::string& source, const std::string& uid, std::int64_t time_ms, double lat,
                   double lon) {
    Json r = Json::make_object();
    r["track.source_id"] = source;
    r["uid"] = uid;
    r["time_ms"] = static_cast<long long>(time_ms);
    r["lat"] = lat;
    r["lon"] = lon;
    return r;
}

inline Json tick_step(std::int64_t now_ms) {
    Json s = Json::make_object();
    s["tick"] = static_cast<long long>(now_ms);
    return s;
}

inline Json ingest_step(Json r) {
    Json s = Json::make_object();
    s["ingest"] = std::move(r);
    return s;
}

} // namespace support
