#!/bin/sh
# Compiles the java engine and runs every vector: the correlate vectors
# (correlator.VectorTest) and the quality vectors (quality.VectorTest).
# Exits non-zero on any failure.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
rm -rf "$here/build"
mkdir -p "$here/build"
javac --release 17 -Xlint:all -Werror -d "$here/build" $(find "$here/src" -name '*.java' | sort)
status=0
java -cp "$here/build" correlator.VectorTest "$root" || status=1
java -cp "$here/build" quality.VectorTest "$root" || status=1
exit $status
