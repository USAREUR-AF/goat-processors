%% The quality vector runner: `erl -noshell -pa ebin -run quality_vectors main <root>`
%% (engines/erlang/run_tests, tools/perf); io_vectors does the work.
-module(quality_vectors).
-export([main/1]).

main([Root]) ->
    io_engine:preload(<<"quality">>),
    halt(io_vectors:main(<<"quality">>, Root)).
