// Unit tests of src/io (the entry point, file reading), src/trace and
// src/snapshot.
#include <stdexcept>
#include <string>

#include "check.hpp"
#include "io/files.hpp"
#include "io/function.hpp"
#include "model/pack_text.hpp"
#include "snapshot/snapshot.hpp"
#include "support.hpp"
#include "trace/trace.hpp"

using corr::Json;

TEST(io, every_function_by_name) {
    CHECK_EQ(corr::io::function_names().size(), size_t{4});
    for (const auto& [fn, pack] : std::vector<std::pair<std::string, std::string>>{
             {"correlate", "correlate-gnn"}, {"filter", "filter-area"}, {"fuse", "fuse-best"},
             {"quality", "quality-feed"}}) {
        auto f = corr::io::load(fn, support::repo("packs/" + pack));
        corr::Output o = f->ingest(support::report("s", "u", 0, 1, 1));
        CHECK(!o.events.array.empty());
        f->tick(1000);
        CHECK(f->snapshot().is_object());
    }
    CHECK_THROWS(std::invalid_argument, corr::io::load("sort", support::repo("packs/correlate-gnn")));
    CHECK_THROWS(corr::PackError, corr::io::load("filter", support::repo("packs/correlate-gnn")));
    CHECK_THROWS(corr::PackError, corr::io::parse("fuse", "pack p\n"));
}

TEST(io, read_file) {
    CHECK(corr::io::read_file(support::repo("packs/correlate-gnn/pack.def")).find("pack") != std::string::npos);
    CHECK_THROWS(std::runtime_error, corr::io::read_file("/nonexistent/file"));
}

TEST(io, trace_and_snapshot_builders) {
    CHECK_EQ(corr::to_json(corr::trace::object({{"b", 1}, {"a", "x"}})), std::string(R"({"a":"x","b":1})"));
    CHECK_EQ(corr::to_json(corr::trace::event("new")), std::string(R"({"ev":"new"})"));
    CHECK(corr::trace::name_or_null(std::nullopt).is_null());
    CHECK(corr::trace::int_or_null(std::nullopt).is_null());
    CHECK_EQ(corr::trace::int_or_null(std::int64_t{3}).integer, std::int64_t{3});
    CHECK(corr::trace::number_or_null(std::nullopt).is_null());
    CHECK_EQ(corr::trace::number_or_null(1.5).number, 1.5);
    corr::Filter f;
    f.east = {1, 2, 3, 4, 5};
    CHECK_EQ(corr::to_json(corr::snapshot::axis_json(f.east)), std::string("[1,2,3,4,5]"));
    CHECK(corr::snapshot::filter_json(f).has("north"));
    CHECK(corr::snapshot::ref_json(std::nullopt).is_null());
    CHECK_EQ(corr::to_json(corr::snapshot::ref_json(std::make_pair(1.5, 2.0))), std::string("[1.5,2]"));
}
