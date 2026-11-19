#!/bin/sh
# Compile the engine and the vector runner into ebin/.
set -e
cd "$(dirname "$0")"
mkdir -p ebin
erlc -Werror -o ebin src/*.erl
