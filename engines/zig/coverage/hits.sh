#!/bin/sh
# hits.sh BINARY LINES OUT [ARGS...]: runs BINARY under gdb with a one-shot
# breakpoint on the first statement address of every line in LINES (from
# lines.awk) and writes to OUT the lines whose breakpoint was hit.
set -e
bin=$1; lines=$2; out=$3; shift 3
script=$(mktemp); left=$(mktemp)
{
    echo "set pagination off"
    echo "set confirm off"
    echo "set width 0"
    echo "set startup-with-shell off"
    echo "set breakpoint pending off"
    echo "set breakpoint always-inserted on"
    awk '{ print "tbreak *" $3; print "commands"; print "silent"; print "continue"; print "end" }' "$lines"
    echo "run $*"
    printf '%s\n' 'echo ==LEFT==\n'
    echo "info breakpoints"
} > "$script"
gdb -nx -batch -x "$script" "$bin" > "$left" 2>&1 || true
# A breakpoint still listed was not hit.
sed -n '/^==LEFT==$/,$p' "$left" | grep -oE '0x[0-9a-f]+' | sed 's/^0x0*/0x/' | sort -u > "$left.addr"
awk 'FILENAME == ARGV[1] { miss[$1] = 1; next } { a = $3; sub(/^0x0*/, "0x", a); if (!(a in miss)) print $1, $2 }' "$left.addr" "$lines" > "$out"
rm -f "$script" "$left" "$left.addr"
