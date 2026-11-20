%% The fuse vector runner: `erl -noshell -pa ebin -run fuse_vectors main <root>`
%% (engines/erlang/run_tests, tools/perf); io_vectors does the work.
-module(fuse_vectors).
-export([main/1]).

main([Root]) -> io_vectors:main(<<"fuse">>, Root).
