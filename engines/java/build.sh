#!/bin/sh
# Compiles the java engines (correlate, fuse) and runs every vector; exits non-zero on any failure.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
rm -rf "$here/build"
mkdir -p "$here/build"
javac --release 17 -Xlint:all -Werror -d "$here/build" $(find "$here/src" -name '*.java' | sort)
status=0
java -cp "$here/build" correlator.VectorTest "$root" || status=1
java -cp "$here/build" fuse.FuseVectorTest "$root" || status=1
exit $status
