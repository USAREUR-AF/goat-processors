#!/bin/sh
# Compiles the java engine (src/) and its tests (test/), runs the unit, property and fuzz tests
# (goat.TestMain), then every conformance vector; exits non-zero on any failure.
#   correlator.VectorTest: spec/correlate-load-vectors and packs/correlate-*
#   filter.VectorTest:     spec/filter-load-vectors and packs/filter-*
#   fuse.FuseVectorTest:   spec/fuse-load-vectors and packs/fuse-*
#   quality.VectorTest:    spec/quality-load-vectors and packs/quality-*
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
rm -rf "$here/build" "$here/build-test"
mkdir -p "$here/build" "$here/build-test"
javac --release 17 -Xlint:all -Werror -d "$here/build" $(find "$here/src" -name '*.java' | sort)
javac --release 17 -Xlint:all -Werror -cp "$here/build" -d "$here/build-test" $(find "$here/test" -name '*.java' | sort)
status=0
java -Dgoat.root="$root" -cp "$here/build:$here/build-test" goat.TestMain || status=1
java -cp "$here/build" correlator.VectorTest "$root" || status=1
java -cp "$here/build" filter.VectorTest "$root" || status=1
java -cp "$here/build" fuse.FuseVectorTest "$root" || status=1
java -cp "$here/build" quality.VectorTest "$root" || status=1
exit $status
