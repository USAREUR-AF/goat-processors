%% The correlate vector runner: `erl -noshell -pa ebin -run correlator_vectors main <root>`
%% (engines/erlang/run_tests, tools/perf); io_vectors does the work.
-module(correlator_vectors).
-export([main/1]).

main([Root]) -> io_vectors:main(<<"correlate">>, Root).
