#!/bin/sh
# Line coverage of the zig engine. Zig 0.13 has no coverage instrumentation,
# so this measures it with gdb: a one-shot breakpoint on the first statement
# address of every source line in the DWARF line table (objdump), the test
# binaries and the runner run under gdb, and a line is covered when its
# breakpoint was hit in any of them. Lines are those of src/ less the test
# code: the test roots, *_test.zig, engine_test_util.zig and every `test`
# block (each file's `unit_tests` struct). Needs gdb and objdump (binutils).
#
# coverage/run.sh            measure, print per file and total
# coverage/run.sh --check    also exit 1 when the total is below coverage/floor
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
cd "$root"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

zig build coverage-bins -Doptimize=Debug
bins=zig-out/coverage

# The test lines to leave out, file by file: `test` blocks and each file's
# `unit_tests` struct.
for f in $(cd src && find . -name '*.zig' | sed 's|^\./||'); do
    awk -v f="$f" '/^test[ {]/ { t = 1 } /^pub const unit_tests = struct/ { u = 1 }
        t || u { print f, FNR } t && /^}/ { t = 0 } u && /^};/ { u = 0 }' "src/$f"
done > "$work/test-lines"

excluded() {
    grep -v -E '^(unit_test|property_test|fuzz_test|vectors_test|filter_vectors_test|fuse_vectors_test|quality_vectors_test|engine_test_util|correlate/noop_test)\.zig ' |
        awk 'FILENAME == ARGV[1] { skip[$1 " " $2] = 1; next } !(($1 " " $2) in skip) && system("test -f src/" $1) == 0' "$work/test-lines" -
}

n=0
measure() {
    bin=$1; shift
    n=$((n + 1))
    objdump --dwarf=decodedline "$bin" | awk -f "$here/lines.awk" > "$work/$n.lines"
    "$here/hits.sh" "$bin" "$work/$n.lines" "$work/$n.hits" "$@"
    cut -d' ' -f1,2 "$work/$n.lines" >> "$work/all"
    cat "$work/$n.hits" >> "$work/hit"
}

: > "$work/all"; : > "$work/hit"
for t in unit vectors filter_vectors fuse_vectors quality_vectors property fuzz; do
    measure "$bins/$t"
done
# The runner, once per function, on a vector of each.
for f in correlate-assign-time:correlate correlate-gnn-imm:correlate filter-area:filter fuse-independent:fuse quality-time:quality; do
    pack=${f%%:*}; fn=${f##*:}
    vec=$(ls ../../packs/$pack/vectors/*.json | head -1)
    measure "$bins/runner" --function "$fn" --pack "../../packs/$pack" --steps "$vec" --events "$work/events" --trace
done

sort -u "$work/all" | excluded > "$work/lines"
sort -u "$work/hit" | excluded > "$work/covered"

awk 'FILENAME == ARGV[1] { hit[$1 " " $2] = 1; next }
     { total[$1]++; all++; if (($1 " " $2) in hit) { cov[$1]++; c++ } }
     END {
         for (f in total) printf "%-28s %5d / %5d  %5.1f %%\n", f, cov[f], total[f], 100 * cov[f] / total[f] | "sort"
         close("sort")
         printf "TOTAL %d / %d lines, %.1f %%\n", c, all, 100 * c / all
     }' "$work/covered" "$work/lines" | tee "$work/report"

if [ "$1" = "--check" ]; then
    floor=$(cat "$here/floor")
    total=$(awk '/^TOTAL/ { sub(/ %$/, ""); print $NF }' "$work/report")
    awk -v t="$total" -v f="$floor" 'BEGIN { if (t + 0 < f + 0) { printf "line coverage %.1f %% is below the floor %s %%\n", t, f; exit 1 } printf "line coverage %.1f %% meets the floor %s %%\n", t, f }'
fi
