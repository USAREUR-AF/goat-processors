#!/bin/sh
# Compiles the java engine and runs every vector; exits non-zero on any failure.
#   correlator.VectorTest: spec/correlate-load-vectors and packs/correlate-*
#   filter.VectorTest:     spec/filter-load-vectors and packs/filter-*
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
rm -rf "$here/build"
mkdir -p "$here/build"
javac --release 17 -Xlint:all -Werror -d "$here/build" $(find "$here/src" -name '*.java' | sort)
status=0
java -cp "$here/build" correlator.VectorTest "$root" || status=1
java -cp "$here/build" filter.VectorTest "$root" || status=1
exit $status
