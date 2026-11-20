#!/bin/sh
# Compile the tests (test/*.erl) into test/ebin/, after the engine.
set -e
cd "$(dirname "$0")"
mkdir -p ebin
erlc -Werror -pa ../ebin -o ebin ./*.erl
