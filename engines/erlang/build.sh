#!/bin/sh
# Compile the engine (src/<area>/*.erl) into ebin/: the behaviours first.
set -e
cd "$(dirname "$0")"
mkdir -p ebin
erlc -Werror -o ebin src/io/io_engine.erl src/correlate/correlate_methods.erl
erlc -Werror -pa ebin -o ebin src/*/*.erl
