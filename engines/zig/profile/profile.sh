#!/bin/sh
# profile.sh <runner arguments>: runs the runner under the sampling profiler of
# src/profile_main.zig (ReleaseFast, frame pointers kept) and prints the
# functions by self and by total (inclusive) share of the CPU samples.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
bin="$root/zig-out/bin/goat-profile"
mkdir -p "$root/zig-out/bin"
(cd "$root" && zig build-exe -O ReleaseFast -fno-omit-frame-pointer src/profile_main.zig -femit-bin="$bin")
out=$(mktemp)
GOAT_PROFILE_OUT="$out" "$bin" "$@" >&2
total=$(awk '$2 == "samples" { print $1 }' "$out")
echo "samples: $total (1 ms of CPU each)"
# Resolve every address to its function (inlined frames: the outermost).
awk '$2 != "samples" { print $3 }' "$out" | sort -u > "$out.addr"
addr2line -f -C -e "$bin" < "$out.addr" | awk 'NR % 2 == 1' > "$out.fn"
# Generic names are shortened: the type arguments of a container become "(..)".
paste -d' ' "$out.addr" "$out.fn" | sed -E 's/\(\[\]const u8,[^)]*\)/(..)/g' > "$out.map"
for kind in self total; do
    echo "== by $kind"
    awk -v kind="$kind" -v n="$total" 'FILENAME == ARGV[1] { a = $1; $1 = ""; fn[a] = substr($0, 2); next }
        $2 == kind { s[fn[$3]] += $1 }
        END { for (f in s) printf "%6.1f %%  %s\n", 100 * s[f] / n, f }' "$out.map" "$out" | sort -rn | head -${TOP:-25}
done
rm -f "$out" "$out.addr" "$out.fn" "$out.map"
