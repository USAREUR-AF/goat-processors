%% The filter vector runner: `erl -noshell -pa ebin -run filter_vectors main <root>`
%% (engines/erlang/run_tests, tools/perf); io_vectors does the work.
-module(filter_vectors).
-export([main/1]).

main([Root]) -> halt(io_vectors:main(<<"filter">>, Root)).
