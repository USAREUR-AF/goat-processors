// The command-line runner of tools/perf/README.md "Runner contract":
//
//   run --function <correlate|filter|fuse|quality> --pack <dir> --steps <file>
//       [--events <file>] [--trace]
//
// Reads the steps file, loads the pack, calls ingest/tick for each step in
// order and snapshot() after the last, then writes the events file and one
// line of counters on standard output.

#include <chrono>
#include <cstdlib>
#include <memory>
#include <stdexcept>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include "io/files.hpp"
#include "io/function.hpp"
#include "model/json.hpp"

namespace {

using corr::Json;
using Clock = std::chrono::steady_clock;

std::int64_t ns_since(Clock::time_point t0) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - t0).count();
}

struct Args {
    std::string function, pack, steps, events;
    bool trace = false;
};

struct Counters {
    std::int64_t steps = 0, ingest = 0, tick = 0, events = 0, trace_records = 0;
    std::int64_t parse_ns = 0, load_ns = 0, run_ns = 0;
};

struct StepOut {
    Json events, trace;
};

[[noreturn]] void die(const std::string& what) {
    std::cerr << "goat_runner: " << what << "\n";
    std::exit(2);
}

// Loads the pack, runs every step and the snapshot, and writes the events file.
void run(const Args& args, const Json& steps, Counters& c) {
    auto t0 = Clock::now();
    std::unique_ptr<corr::io::Function> engine;
    try {
        engine = corr::io::load(args.function, args.pack);
    } catch (const std::exception& e) {
        die(std::string("pack does not load: ") + e.what());
    }
    c.load_ns = ns_since(t0);

    const bool keep = !args.events.empty();
    std::vector<StepOut> outs;
    if (keep) outs.reserve(steps.array.size());
    t0 = Clock::now();
    for (const Json& step : steps.array) {
        const Json* ingest = step.find("ingest");
        auto out = ingest ? engine->ingest(*ingest) : engine->tick(step.find("tick")->integer);
        c.events += static_cast<std::int64_t>(out.events.array.size());
        c.trace_records += static_cast<std::int64_t>(out.trace.array.size());
        if (keep) outs.push_back({std::move(out.events), std::move(out.trace)});
    }
    Json snapshot = engine->snapshot();
    c.run_ns = ns_since(t0);

    if (!keep) return;
    std::ofstream f(args.events, std::ios::binary);
    if (!f) die("cannot write " + args.events);
    for (size_t i = 0; i < outs.size(); ++i) {
        Json line = Json::make_object();
        line["step"] = static_cast<long long>(i);
        line["events"] = std::move(outs[i].events);
        if (args.trace) line["trace"] = std::move(outs[i].trace);
        f << corr::to_json(line) << "\n";
    }
    Json last = Json::make_object();
    last["snapshot"] = std::move(snapshot);
    f << corr::to_json(last) << "\n";
}

} // namespace

int main(int argc, char** argv) {
    Args args;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto value = [&]() -> std::string {
            if (i + 1 >= argc) die("missing value for " + a);
            return argv[++i];
        };
        if (a == "--function") args.function = value();
        else if (a == "--pack") args.pack = value();
        else if (a == "--steps") args.steps = value();
        else if (a == "--events") args.events = value();
        else if (a == "--trace") args.trace = true;
        else die("unknown argument: " + a);
    }
    bool known = false;
    for (const std::string& name : corr::io::function_names()) known = known || name == args.function;
    if (!known) die("unknown function: " + args.function);
    if (args.pack.empty() || args.steps.empty()) die("--pack and --steps are required");

    Counters c;
    auto t0 = Clock::now();
    Json steps;
    try {
        std::string text;
        try {
            text = corr::io::read_file(args.steps);
        } catch (const std::runtime_error&) {
            die("cannot read " + args.steps);
        }
        Json doc = corr::parse_json(text);
        const Json* s = doc.find("steps");
        if (!s || !s->is_array()) die("steps file has no steps list");
        for (const Json& step : s->array) {
            const Json* ingest = step.find("ingest");
            const Json* tick = step.find("tick");
            if (!(ingest && ingest->is_object()) && !(tick && tick->is_number() && tick->is_int))
                die("a step holds neither ingest nor an integer tick");
            if (ingest) ++c.ingest;
            else ++c.tick;
        }
        steps = std::move(*doc.find("steps"));
    } catch (const corr::JsonError& e) {
        die(std::string("steps file does not parse: ") + e.what());
    }
    c.steps = c.ingest + c.tick;
    c.parse_ns = ns_since(t0);

    run(args, steps, c);

    Json counters = Json::make_object();
    counters["engine"] = "cpp";
    counters["function"] = args.function;
    counters["pack"] = std::filesystem::path(args.pack).lexically_normal().filename().string();
    if (counters["pack"].string.empty())
        counters["pack"] = std::filesystem::path(args.pack).lexically_normal().parent_path().filename().string();
    counters["steps"] = static_cast<long long>(c.steps);
    counters["ingest"] = static_cast<long long>(c.ingest);
    counters["tick"] = static_cast<long long>(c.tick);
    counters["events"] = static_cast<long long>(c.events);
    counters["trace_records"] = static_cast<long long>(c.trace_records);
    counters["parse_ns"] = static_cast<long long>(c.parse_ns);
    counters["load_ns"] = static_cast<long long>(c.load_ns);
    counters["run_ns"] = static_cast<long long>(c.run_ns);
    std::cout << corr::to_json(counters) << std::endl;
    return 0;
}
