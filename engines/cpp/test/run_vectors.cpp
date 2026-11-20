// Runs every scenario vector of one function (packs/<fn>-*/vectors/*.json)
// and every load vector of it (spec/<fn>-load-vectors/*.json) with the
// comparison of spec/vector-format.md, printing PASS or FAIL per vector and,
// for a failure, the path of the first mismatch.
//
// Built once per function (VECTOR_FUNCTION): run_vectors (correlate),
// run_filter_vectors, run_fuse_vectors, run_quality_vectors.
// Usage: <runner> [repo_root]

#include <algorithm>
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

#include "io/function.hpp"
#include "model/json.hpp"
#include "model/pack_text.hpp"
#include "vector_support.hpp"

namespace fs = std::filesystem;
using corr::Json;
using vectors::json_files;
using vectors::mismatch;
using vectors::read_file;

namespace {

const std::string kFunction = VECTOR_FUNCTION;

// One scenario vector: each step's events and trace, then the snapshot.
std::string run_scenario(const fs::path& root, const Json& v) {
    auto engine = corr::io::load(kFunction, (root / "packs" / v.find("pack")->string).string());
    const auto& steps = v.find("steps")->array;
    for (size_t i = 0; i < steps.size(); ++i) {
        const Json& step = steps[i];
        corr::Output out = step.has("ingest") ? engine->ingest(*step.find("ingest"))
                                              : engine->tick(step.find("tick")->integer);
        std::string at = "steps[" + std::to_string(i) + "]";
        std::string m = mismatch(out.events, *step.find("expect"), at + ".expect");
        if (m.empty()) m = mismatch(out.trace, *step.find("trace"), at + ".trace");
        if (!m.empty()) return m;
    }
    return mismatch(engine->snapshot(), *v.find("snapshot"), "snapshot");
}

// One load vector: parsing must fail exactly when expect_error is true.
std::string run_load(const Json& v) {
    bool want_error = v.find("expect_error")->boolean;
    std::string error;
    try {
        corr::io::parse(kFunction, v.find("pack_def")->string);
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
    auto report = [&](const std::string& label, const fs::path& file, auto&& check) {
        ++total;
        std::string m;
        try {
            m = check(corr::parse_json(read_file(file)));
        } catch (const std::exception& e) {
            m = std::string("exception: ") + e.what();
        }
        if (m.empty()) {
            std::cout << "PASS " << label << "\n";
        } else {
            ++failed;
            std::cout << "FAIL " << label << "\n     " << m << "\n";
        }
    };

    std::vector<fs::path> packs;
    for (const auto& e : fs::directory_iterator(root / "packs"))
        if (e.is_directory() && e.path().filename().string().rfind(kFunction + "-", 0) == 0)
            packs.push_back(e.path());
    std::sort(packs.begin(), packs.end());
    for (const auto& pack : packs)
        for (const auto& f : json_files(pack / "vectors"))
            report("scenario " + pack.filename().string() + "/" + f.filename().string(), f,
                   [&](const Json& v) { return run_scenario(root, v); });
    for (const auto& f : json_files(root / "spec" / (kFunction + "-load-vectors")))
        report("load " + f.filename().string(), f, run_load);

    std::cout << (total - failed) << "/" << total << " " << kFunction << " vectors pass\n";
    return failed == 0 && total > 0 ? 0 : 1;
}
