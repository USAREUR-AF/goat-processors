#!/bin/sh
# Line coverage of the java engine with the JDK's own debugger interface (jdk.jdi; no
# third-party package): the engine's tests and every conformance vector, every line of src/.
# Fails when the total is below the floor: max(baseline 96.6 %, 80 %). The baseline is the
# pre-refactor engine (commit 407a295) under its conformance vectors, measured the same way.
# Writes the per-file report to build-test/coverage.tsv.
set -eu
floor=${1:-96.6}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
rm -rf "$here/build" "$here/build-test"
mkdir -p "$here/build" "$here/build-test"
javac --release 17 -Xlint:all -Werror -d "$here/build" $(find "$here/src" -name '*.java' | sort)
javac --release 17 -Xlint:all -Werror -cp "$here/build" -d "$here/build-test" $(find "$here/test" -name '*.java' | sort)
exec java -cp "$here/build-test" goat.coverage.Coverage "$here/build:$here/build-test" "$here/build" \
    "$here/build-test/coverage.tsv" "$floor" "-Dgoat.root=$root" \
    goat.TestMain "correlator.VectorTest $root" "filter.VectorTest $root" "fuse.FuseVectorTest $root" \
    "quality.VectorTest $root"
