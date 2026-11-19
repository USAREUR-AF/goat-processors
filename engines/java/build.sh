#!/bin/sh
# Compiles the java engine and runs every vector; exits non-zero on any failure.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
rm -rf "$here/build"
mkdir -p "$here/build"
javac --release 17 -Xlint:all -Werror -d "$here/build" $(find "$here/src" -name '*.java' | sort)
exec java -cp "$here/build" correlator.VectorTest "$root"
