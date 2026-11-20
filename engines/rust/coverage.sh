#!/bin/sh
# Line coverage of the rust engine with the toolchain's own coverage support:
# rustc `-C instrument-coverage`, and llvm-profdata / llvm-cov from the rustup
# component `llvm-tools` (rustup component add llvm-tools). No third-party
# crate. Counts the lines of src/ run by `cargo test`.
#
#   ./coverage.sh            print the line coverage of src/
#   ./coverage.sh 85.0       ... and exit 1 when it is below 85.0 %
set -eu
cd "$(dirname "$0")"
floor=${1:-}
host=$(rustc -vV | sed -n 's/^host: //p')
bin="$(rustc --print sysroot)/lib/rustlib/$host/bin"
[ -x "$bin/llvm-cov" ] || { echo "coverage.sh: needs the rustup component llvm-tools" >&2; exit 2; }
target=target/coverage
rm -rf "$target/profraw"
mkdir -p "$target/profraw"
export RUSTFLAGS="-C instrument-coverage"
export CARGO_TARGET_DIR="$target"
export LLVM_PROFILE_FILE="$PWD/$target/profraw/%p-%m.profraw"
cargo test --quiet >/dev/null
objects=$(cargo test --no-run --message-format=json 2>/dev/null | sed -n 's/.*"executable":"\([^"]*\)".*/\1/p')
"$bin/llvm-profdata" merge -sparse "$target"/profraw/*.profraw -o "$target/coverage.profdata"
set --
for o in $objects; do set -- "$@" -object "$o"; done
"$bin/llvm-cov" report --instr-profile "$target/coverage.profdata" "$@" \
  --ignore-filename-regex '(/rustc/|/\.cargo/|/tests/)' > "$target/report.txt"
cat "$target/report.txt"
total=$(awk '$1 == "TOTAL" { print $10 }' "$target/report.txt" | tr -d '%')
echo "line coverage: $total %"
if [ -n "$floor" ]; then
  awk -v t="$total" -v f="$floor" 'BEGIN { exit !(t + 0 >= f + 0) }' || { echo "below the floor of $floor %" >&2; exit 1; }
fi
