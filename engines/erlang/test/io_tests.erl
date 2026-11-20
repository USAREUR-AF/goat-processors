%% Unit tests of src/io: pack.def text, the function table, the vector
%% comparison, the runner's steps reader; and src/trace, src/snapshot
%% helpers.
-module(io_tests).
-include_lib("eunit/include/eunit.hrl").

words_test() ->
    ?assertEqual([[<<"pack">>, <<"x">>], [<<"a">>, <<"b=1">>]],
                 io_pack:words(<<"pack x # c\n\n  a\tb=1\r\n# only\n">>)).

words_strip_cr_test() ->
    %% only one CR at the end of a line is removed; a CR inside stays a token
    ?assertEqual([[<<"a">>, <<"b">>]], io_pack:words_strip_cr(<<"a b\r\n">>)),
    ?assertEqual([[<<"a">>, <<"\r">>]], io_pack:words_strip_cr(<<"a \r\r\n">>)).

strict_lines_test() ->
    ?assertEqual([[<<"a">>]], io_pack:strict_lines(<<"a\r\n">>)),
    ?assertThrow({pack_error, {control_character, 13}}, io_pack:strict_lines(<<"a\r\r\n">>)),
    ?assertThrow({pack_error, {control_character, 0}}, io_pack:strict_lines(<<"a # \0">>)),
    ?assertEqual([[<<"a">>, <<"b">>]], io_pack:strict_lines(<<"a\tb">>)).

catching_test() ->
    ?assertEqual({error, why}, io_pack:catching(fun() -> io_pack:fail(why) end)),
    ?assertEqual({ok, 1}, io_pack:catching(fun() -> 1 end)).

read_missing_pack_test() ->
    ?assertMatch({error, {read, enoent}}, io_pack:read("/nonexistent", fun(_) -> ok end)).

functions_test() ->
    ?assertEqual({ok, correlate}, io_engine:module(<<"correlate">>)),
    ?assertEqual({ok, quality}, io_engine:module(<<"quality">>)),
    ?assertEqual(error, io_engine:module(<<"other">>)),
    ?assertEqual(4, map_size(io_engine:functions())).

compare_test() ->
    ?assertEqual(ok, io_vectors:compare(1.0, 1.0000001, "x")),
    ?assertMatch({mismatch, "x", _, _}, io_vectors:compare(1.0, 1.1, "x")),
    ?assertEqual(ok, io_vectors:compare(1000000.0, 1000000.5, "x")),
    ?assertEqual(ok, io_vectors:compare(1, 1.0, "x")),
    ?assertMatch({mismatch, "x (keys)", _, _}, io_vectors:compare(#{a => 1}, #{b => 1}, "x")),
    ?assertMatch({mismatch, "x (length)", _, _}, io_vectors:compare([1], [1, 2], "x")),
    ?assertMatch({mismatch, "x[1]", 2, 3}, io_vectors:compare([1, 2], [1, 3], "x")),
    ?assertMatch({mismatch, "x", null, false}, io_vectors:compare(null, false, "x")),
    ?assertEqual(ok, io_vectors:compare(#{<<"k">> => [null, <<"s">>]},
                                        #{<<"k">> => [null, <<"s">>]}, "x")).

parse_steps_test() ->
    ?assertEqual({ok, [{tick, 5}, {ingest, #{<<"a">> => 1}}]},
                 io_runner:parse_steps(<<"{\"steps\":[{\"tick\":5,\"name\":1},"
                                         "{\"ingest\":{\"a\":1},\"expect\":[]}],\"x\":0}">>)),
    ?assertMatch({error, _}, io_runner:parse_steps(<<"{\"steps\":[{\"tick\":1.5}]}">>)),
    ?assertMatch({error, _}, io_runner:parse_steps(<<"{\"steps\":[{}]}">>)),
    ?assertMatch({error, _}, io_runner:parse_steps(<<"[]">>)),
    ?assertMatch({error, _}, io_runner:parse_steps(<<"{\"steps\":">>)).

trace_log_test() ->
    St = trace_log:record(r2, trace_log:emit_all([e2, e3], trace_log:record(r1,
             trace_log:emit(e1, trace_log:fields())))),
    ?assertEqual({[e1, e2, e3], [r1, r2], #{events => [], trace => []}}, trace_log:finish(St)).

snapshot_json_test() ->
    ?assertEqual(null, snapshot_json:ref(none)),
    ?assertEqual(null, snapshot_json:ref(null)),
    ?assertEqual([1.0, 2.0], snapshot_json:ref({1.0, 2.0})),
    ?assertEqual(#{<<"east">> => [1, 2, 3, 4, 5], <<"north">> => [6, 7, 8, 9, 10]},
                 snapshot_json:filter(#{east => {1, 2, 3, 4, 5}, north => {6, 7, 8, 9, 10}})).

%% The runner (tools/perf "Runner contract"): one run writes the events
%% file, one line per step and the snapshot; bad arguments give status 2.
runner_test() ->
    Root = test_support:root(),
    Pack = filename:join(Root, "packs/correlate-gnn"),
    Steps = filename:join(Pack, "vectors/01-two-sources-one-object.json"),
    Dir = filename:join(["/tmp", "erlang-runner-test-" ++ os:getpid()]),
    ok = filelib:ensure_path(Dir),
    Events = filename:join(Dir, "events.jsonl"),
    ?assertEqual(0, io_runner:main(["--function", "correlate", "--pack", Pack, "--steps", Steps,
                                    "--events", Events, "--trace"])),
    {ok, Text} = file:read_file(Events),
    Lines = [json:decode(L) || L <- binary:split(Text, <<"\n">>, [global, trim_all])],
    N = length(test_support:steps(Steps)),
    ?assertEqual(N + 1, length(Lines)),
    ?assertMatch(#{<<"step">> := 0, <<"events">> := _, <<"trace">> := _}, hd(Lines)),
    ?assertMatch(#{<<"snapshot">> := _}, lists:last(Lines)),
    ?assertEqual(0, io_runner:main(["--function", "correlate", "--pack", Pack, "--steps", Steps,
                                    "--events", Events])),
    {ok, Text2} = file:read_file(Events),
    ?assertNot(maps:is_key(<<"trace">>, json:decode(hd(binary:split(Text2, <<"\n">>))))),
    ?assertEqual(0, io_runner:main(["--function", "correlate", "--pack", Pack, "--steps", Steps])),
    Bad = filename:join(Dir, "bad.json"),
    ok = file:write_file(Bad, <<"{\"steps\": [">>),
    [?assertEqual(2, io_runner:main(Args)) || Args <- [
        ["--function", "nope", "--pack", Pack, "--steps", Steps],
        ["--function", "correlate", "--pack", "/nonexistent", "--steps", Steps],
        ["--function", "correlate", "--pack", Pack, "--steps", Bad],
        ["--function", "correlate", "--pack", Pack, "--steps", "/nonexistent.json"],
        ["--function", "correlate", "--pack", Pack],
        ["--what"]]],
    file:del_dir_r(Dir).

vector_runner_test() ->
    ?assertEqual(0, io_vectors:main(<<"fuse">>, test_support:root())).

%% A vector whose expected output is wrong fails, with the path of the
%% first mismatch; a load vector likewise.
failing_vector_test() ->
    Root = filename:join(["/tmp", "erlang-vectors-test-" ++ os:getpid()]),
    Pack = filename:join(Root, "packs/fuse-x"),
    ok = filelib:ensure_path(filename:join(Pack, "vectors")),
    ok = filelib:ensure_path(filename:join(Root, "spec/fuse-load-vectors")),
    ok = file:write_file(filename:join(Pack, "pack.def"),
                         <<"pack fuse-x\nversion 1\nfilter accel_var=1 default_ce_m=50 "
                           "vel_sigma_ms=5 unknown_vel_ms=100\nkinematics best\nstale_ms 10\n">>),
    Step = #{<<"tick">> => 5, <<"expect">> => [#{<<"ev">> => <<"nothing">>}], <<"trace">> => []},
    ok = file:write_file(filename:join(Pack, "vectors/v.json"),
                         json:encode(#{<<"name">> => <<"v">>, <<"pack">> => <<"fuse-x">>,
                                       <<"steps">> => [Step], <<"snapshot">> => #{}})),
    ok = file:write_file(filename:join(Root, "spec/fuse-load-vectors/l.json"),
                         json:encode(#{<<"name">> => <<"l">>, <<"pack_def">> => <<"nope">>,
                                       <<"expect_error">> => false})),
    ?assertEqual([fail, fail], io_vectors:results(<<"fuse">>, Root)),
    ?assertEqual(1, io_vectors:main(<<"fuse">>, Root)),
    file:del_dir_r(Root).
