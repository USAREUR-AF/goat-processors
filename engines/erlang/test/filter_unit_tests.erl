%% Unit tests of src/filter: geometry, conditions, pack, engine.
-module(filter_unit_tests).
-include_lib("eunit/include/eunit.hrl").

distance_test() ->
    ?assertEqual(0.0, filter_geometry:distance(50.0, 8.0, 50.0, 8.0)),
    D = filter_geometry:distance(0.0, 0.0, 0.0, 1.0),
    ?assert(abs(D - 111195.08) < 1.0),
    %% across the antimeridian the short way
    ?assert(filter_geometry:distance(0.0, 179.5, 0.0, -179.5) < 112000).

predict_test() ->
    Ref = #{time_ms => 0, lat => 0.0, lon => 0.0, course => 90, speed_ms => 10},
    {Lat, Lon} = filter_geometry:predict(Ref, 1000),
    ?assert(abs(Lat) < 1.0e-9 andalso Lon > 0),
    Still = Ref#{course := null},
    ?assertEqual({0.0, 0.0}, filter_geometry:predict(Still, 1000)).

polygon_test() ->
    Square = [{0.0, 0.0}, {0.0, 1.0}, {1.0, 1.0}, {1.0, 0.0}],
    ?assertEqual(inside, filter_geometry:polygon(Square, 0.5, 0.5)),
    ?assertEqual(outside, filter_geometry:polygon(Square, 1.5, 0.5)),
    ?assertEqual(boundary, filter_geometry:polygon(Square, 0.0, 0.5)),
    ?assertEqual(boundary, filter_geometry:polygon(Square, 1.0, 1.0)).

condition_table_test() ->
    T = filter_conditions:table(),
    ?assertEqual(13, map_size(T)),
    ?assertEqual([[]], filter_conditions:parameter_sets(<<"order">>)),
    ?assertEqual(unknown, filter_conditions:parameter_sets(<<"nope">>)).

ctx(R) -> #{report => R, key => <<"s/u">>, prior => none, entities => #{}}.

evaluate(Test, Params, Negated, R) ->
    {_, Eval} = maps:get(Test, filter_conditions:table()),
    filter_conditions:evaluate(#{test => Test, negated => Negated, params => Params,
                                 eval => Eval}, <<"r">>, ctx(R)).

evaluate_unknown_negated_fails_test() ->
    {Rec, Pass} = evaluate(<<"env">>, #{<<"in">> => [<<"A">>]}, true, #{}),
    ?assertEqual(false, Pass),
    ?assertEqual(true, maps:get(<<"unknown">>, Rec)),
    {Rec2, Pass2} = evaluate(<<"env">>, #{<<"in">> => [<<"A">>]}, true,
                             #{<<"type">> => <<"a-f-G">>}),
    ?assertEqual(true, Pass2),
    ?assertEqual(false, maps:is_key(<<"unknown">>, Rec2)).

key_condition_test() ->
    R = #{<<"x">> => 2, <<"s">> => <<"a">>, <<"b">> => true},
    {_, P1} = evaluate(<<"key">>, #{<<"name">> => <<"x">>, <<"eq">> => <<"2.0">>}, false, R),
    ?assert(P1),
    {_, P2} = evaluate(<<"key">>, #{<<"name">> => <<"b">>, <<"in">> => [<<"true">>]}, false, R),
    ?assert(P2),
    {_, P3} = evaluate(<<"key">>, #{<<"name">> => <<"x">>, <<"min">> => 3.0}, false, R),
    ?assertNot(P3),
    {Rec, _} = evaluate(<<"key">>, #{<<"name">> => <<"s">>, <<"max">> => 3.0}, false, R),
    ?assertEqual([null, 3.0], maps:get(<<"limit">>, Rec)).

pack_test() ->
    Good = <<"pack p\nversion 1\ndefault keep\nforget_ms 10\nrule r drop\nwhen speed max=5\n">>,
    {ok, P} = filter_pack:parse(Good),
    ?assertMatch([#{name := <<"r">>, action := drop, conditions := [#{test := <<"speed">>}]}],
                 maps:get(rules, P)),
    [?assertMatch({error, _}, filter_pack:parse(T)) || T <- [
        <<"pack p\nversion 1\ndefault keep\nforget_ms 10\nrule r drop\n">>,
        <<"pack p\nversion 1\ndefault keep\nforget_ms 0\n">>,
        <<"pack p\nversion 1\ndefault keep\nforget_ms 10\nwhen speed max=5\n">>,
        <<"pack p\nversion 1\ndefault keep\nforget_ms 10\nrule r drop\nwhen speed min=5 max=1\n">>,
        <<"pack p\nversion 1\ndefault keep\nforget_ms 10\nrule r drop\nwhen nope\n">>]],
    ?assertEqual(1.5, filter_pack:read_number(<<"1.5">>)),
    ?assertEqual(not_a_number, filter_pack:read_number(<<"1e5">>)).

engine_test() ->
    {ok, P} = filter_pack:parse(<<"pack p\nversion 1\ndefault keep\nforget_ms 10\n"
                                  "rule fast drop\nwhen speed min=100\n">>),
    St0 = filter:new(P),
    R = #{<<"track.source_id">> => <<"s">>, <<"uid">> => <<"u">>, <<"time_ms">> => 0,
          <<"lat">> => 1.0, <<"lon">> => 2.0, <<"speed_ms">> => 200},
    {[#{<<"ev">> := <<"drop">>, <<"rule">> := <<"fast">>}], [_], St1} = filter:ingest(R, St0),
    {[#{<<"ev">> := <<"keep">>, <<"rule">> := <<"default">>}], _, St2} =
        filter:ingest(R#{<<"speed_ms">> := 1, <<"time_ms">> := 5}, St1),
    ?assertMatch(#{<<"entities">> := #{<<"s/u">> := #{<<"kept_ms">> := 5}}}, filter:snapshot(St2)),
    {[], [#{<<"pass">> := false}], St3} = filter:tick(15, St2),
    {[#{<<"ev">> := <<"forget">>}], _, St4} = filter:tick(16, St3),
    ?assertEqual(#{<<"entities">> => #{}}, filter:snapshot(St4)),
    {[#{<<"ev">> := <<"reject">>}], [], _} = filter:ingest(#{}, St0).

key_boolean_and_overflow_test() ->
    R = #{<<"b">> => false, <<"x">> => 2},
    {_, P} = evaluate(<<"key">>, #{<<"name">> => <<"b">>, <<"eq">> => <<"false">>}, false, R),
    ?assert(P),
    Huge = list_to_binary(lists:duplicate(400, $9)),
    {_, Q} = evaluate(<<"key">>, #{<<"name">> => <<"x">>, <<"eq">> => Huge}, false, R),
    ?assertNot(Q),
    ?assertMatch({error, {not_finite, _}},
                 filter_pack:parse(<<"pack p\nversion 1\ndefault keep\nforget_ms 10\nrule r drop\n"
                                     "when speed max=", Huge/binary, "\n">>)).
