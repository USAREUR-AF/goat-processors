// Runs every scenario vector (packs/correlate-*/vectors/*.json) and every load vector
// (spec/correlate-load-vectors/*.json) with the comparison of spec/vector-format.md.
// Usage: run_vectors [repo_root]

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "engine.hpp"
#include "json.hpp"
#include "pack.hpp"

namespace fs = std::filesystem;
using corr::Json;

namespace {

std::string read_file(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

std::vector<fs::path> json_files(const fs::path& dir) {
    std::vector<fs::path> out;
    if (!fs::is_directory(dir)) return out;
    for (const auto& e : fs::directory_iterator(dir))
        if (e.path().extension() == ".json") out.push_back(e.path());
    std::sort(out.begin(), out.end());
    return out;
}

// vector-format.md "What the engine checks": structural equality, numbers
// within 1e-6 * max(1, |want|), null distinct from absent. Returns the path of
// the first mismatch, or an empty string.
std::string mismatch(const Json& got, const Json& want, const std::string& path) {
    auto show = [](const Json& v) { return corr::to_json(v); };
    auto differ = [&](const std::string& why) {
        return path + ": " + why + " (got " + show(got) + ", want " + show(want) + ")";
    };
    if (got.kind != want.kind) return differ("type differs");
    switch (want.kind) {
        case Json::Kind::Null: return "";
        case Json::Kind::Bool: return got.boolean == want.boolean ? "" : differ("value differs");
        case Json::Kind::String: return got.string == want.string ? "" : differ("value differs");
        case Json::Kind::Number: {
            double tol = 1e-6 * std::max(1.0, std::abs(want.number));
            return std::abs(got.number - want.number) <= tol ? "" : differ("number differs");
        }
        case Json::Kind::Array: {
            size_t n = std::min(got.array.size(), want.array.size());
            for (size_t i = 0; i < n; ++i) {
                std::string m = mismatch(got.array[i], want.array[i], path + "[" + std::to_string(i) + "]");
                if (!m.empty()) return m;
            }
            if (got.array.size() != want.array.size())
                return differ("length " + std::to_string(got.array.size()) + " != " +
                              std::to_string(want.array.size()));
            return "";
        }
        case Json::Kind::Object: {
            for (const auto& kv : want.object)
                if (!got.has(kv.first)) return path + "." + kv.first + ": absent (want " + show(kv.second) + ")";
            for (const auto& kv : got.object)
                if (!want.has(kv.first)) return path + "." + kv.first + ": unexpected key (got " + show(kv.second) + ")";
            for (const auto& kv : want.object) {
                std::string m = mismatch(*got.find(kv.first), kv.second, path + "." + kv.first);
                if (!m.empty()) return m;
            }
            return "";
        }
    }
    return "";
}

// One scenario vector: each step's events and trace, then the snapshot.
std::string run_scenario(const fs::path& root, const Json& v) {
    corr::Engine engine(corr::load_pack((root / "packs" / v.find("pack")->string).string()));
    const auto& steps = v.find("steps")->array;
    for (size_t i = 0; i < steps.size(); ++i) {
        const Json& step = steps[i];
        corr::Output out = step.has("ingest") ? engine.ingest(*step.find("ingest"))
                                              : engine.tick(step.find("tick")->integer);
        std::string at = "steps[" + std::to_string(i) + "]";
        std::string m = mismatch(out.events, *step.find("expect"), at + ".expect");
        if (m.empty()) m = mismatch(out.trace, *step.find("trace"), at + ".trace");
        if (!m.empty()) return m;
    }
    return mismatch(engine.snapshot(), *v.find("snapshot"), "snapshot");
}

// One load vector: parsing must fail exactly when expect_error is true.
std::string run_load(const Json& v) {
    bool want_error = v.find("expect_error")->boolean;
    std::string error;
    try {
        corr::parse_pack(v.find("pack_def")->string);
    } catch (const corr::PackError& e) {
        error = e.what();
    }
    if (want_error && error.empty()) return "expect_error: pack loaded, want a load error";
    if (!want_error && !error.empty()) return "expect_error: load failed (" + error + "), want success";
    return "";
}

} // namespace

int main(int argc, char** argv) {
    fs::path root = argc > 1 ? fs::path(argv[1]) : fs::path(CORR_REPO_ROOT);
    int total = 0, failed = 0;
    auto report = [&](const std::string& label, const std::string& m) {
        ++total;
        if (m.empty()) {
            std::cout << "PASS " << label << "\n";
        } else {
            ++failed;
            std::cout << "FAIL " << label << "\n     " << m << "\n";
        }
    };

    std::vector<fs::path> packs;
    for (const auto& e : fs::directory_iterator(root / "packs"))
        if (e.is_directory() && e.path().filename().string().rfind("correlate-", 0) == 0)
            packs.push_back(e.path());
    std::sort(packs.begin(), packs.end());
    for (const auto& pack : packs) {
        for (const auto& f : json_files(pack / "vectors")) {
            std::string label = "scenario " + pack.filename().string() + "/" + f.filename().string();
            std::string m;
            try {
                m = run_scenario(root, corr::parse_json(read_file(f)));
            } catch (const std::exception& e) {
                m = std::string("exception: ") + e.what();
            }
            report(label, m);
        }
    }
    for (const auto& f : json_files(root / "spec" / "correlate-load-vectors")) {
        std::string m;
        try {
            m = run_load(corr::parse_json(read_file(f)));
        } catch (const std::exception& e) {
            m = std::string("exception: ") + e.what();
        }
        report("load " + f.filename().string(), m);
    }

    std::cout << (total - failed) << "/" << total << " vectors pass\n";
    return failed == 0 && total > 0 ? 0 : 1;
}
