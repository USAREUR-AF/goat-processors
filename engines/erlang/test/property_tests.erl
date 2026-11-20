%% Property tests over every scenario vector of every function:
%%  - determinism: the same input gives the same output, twice in one VM;
%%  - order independence where the specs say order does not matter: the
%%    order of a report's keys (a JSON object), and the order of a pack's
%%    lines other than the repeating ones (correlate.md "Pack": a range is
%%    checked once the whole file is read; every spec: a once directive may
%%    come anywhere);
%%  - restore: the engine state is a value, so a state stored at any step
%%    (term_to_binary) and restored gives the same continued output. The
%%    engine has no restore from snapshot(): the snapshot of the specs does
%%    not hold the whole state (correlate's holds no last report), so it
%%    cannot be restored from.
-module(property_tests).
-include_lib("eunit/include/eunit.hrl").

determinism_test_() ->
    {timeout, 300,
     [{filename:basename(F),
       fun() ->
               Steps = test_support:steps(F),
               ?assertEqual(test_support:run(Mod, {Dir, Steps}),
                            test_support:run(Mod, {Dir, Steps}))
       end} || {_Fn, Mod, Dir, F} <- test_support:scenarios()]}.

%% Every report's keys in a shuffled order, through JSON text and back.
report_key_order_test_() ->
    {timeout, 300,
     [{filename:basename(F),
       fun() ->
               Steps = test_support:steps(F),
               {Shuffled, _} = lists:mapfoldl(fun shuffle_step/2, test_support:rand_state(7), Steps),
               ?assertEqual(test_support:run(Mod, {Dir, Steps}),
                            test_support:run(Mod, {Dir, Shuffled}))
       end} || {_Fn, Mod, Dir, F} <- test_support:scenarios()]}.

shuffle_step({ingest, R}, S0) when is_map(R) ->
    {Pairs, S1} = test_support:shuffle(maps:to_list(R), S0),
    Text = iolist_to_binary(json:encode_key_value_list(Pairs, fun json:encode_value/2)),
    {{ingest, json:decode(Text)}, S1};
shuffle_step(Step, S) -> {Step, S}.

%% The once directives of every pack in reversed and shuffled order: the
%% same pack, so the same output on every vector.
pack_line_order_test_() ->
    {timeout, 300,
     [{Dir, fun() -> pack_line_order(Fn, Dir) end}
      || Fn <- [<<"correlate">>, <<"filter">>, <<"fuse">>, <<"quality">>],
         Dir <- test_support:pack_dirs(Fn)]}.

%% Repeating directives keep their relative order (it is the order tests and
%% rules run); every other line moves.
repeating(<<"correlate">>) -> [<<"gate">>, <<"confirm">>, <<"hold">>, <<"priority">>];
repeating(<<"filter">>) -> [<<"rule">>, <<"when">>];
repeating(<<"fuse">>) -> [<<"attribute">>, <<"source">>];
repeating(<<"quality">>) -> [<<"rule">>].

pack_line_order(Fn, Dir) ->
    {ok, Text} = file:read_file(filename:join(Dir, "pack.def")),
    Lines = [L || L <- binary:split(Text, <<"\n">>, [global]), io_pack:words(L) =/= []],
    Rep = repeating(Fn),
    {Fixed, Free} = lists:partition(fun(L) -> lists:member(hd(hd(io_pack:words(L))), Rep) end,
                                    Lines),
    {Shuffled, _} = test_support:shuffle(Free, test_support:rand_state(11)),
    Parse = io_engine:pack_parser(Fn),
    {ok, Want} = Parse(Text),
    [?assertEqual({ok, Want}, Parse(iolist_to_binary(lists:join(<<"\n">>, Order ++ Fixed))))
     || Order <- [lists:reverse(Free), Shuffled]].

%% Restore: store the state at step K, restore it, run the rest.
restore_test_() ->
    {timeout, 300,
     [{filename:basename(F),
       fun() ->
               Steps = test_support:steps(F),
               {WantOut, WantSnap} = test_support:run(Mod, {Dir, Steps}),
               K = length(Steps) div 2,
               {Before, After} = lists:split(K, Steps),
               {_, St} = io_engine:run(Mod, Before, test_support:load(Mod, Dir)),
               Restored = binary_to_term(term_to_binary(St)),
               {Out, Snap} = test_support:run_from(Mod, Restored, After),
               ?assertEqual(lists:nthtail(K, WantOut), Out),
               ?assertEqual(WantSnap, Snap)
       end} || {_Fn, Mod, Dir, F} <- test_support:scenarios()]}.
