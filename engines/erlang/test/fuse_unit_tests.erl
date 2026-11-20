%% Unit tests of src/fuse: kinematics, attributes, pack, engine.
-module(fuse_unit_tests).
-include_lib("eunit/include/eunit.hrl").

pred(P, PP) -> #{east => {P, 1.0, PP, 0.0, 4.0}, north => {P, 1.0, PP, 0.0, 4.0}}.

member(K, Src, T, P, PP, Report) ->
    {K, #{time => T, report => Report#{<<"track.source_id">> => Src}}, pred(P, PP)}.

pack() -> #{sources => [<<"b">>, <<"a">>]}.

inverse_variance_test() ->
    Ms = [member(<<"a/1">>, <<"a">>, 0, 0.0, 1.0, #{}), member(<<"b/1">>, <<"b">>, 0, 3.0, 1.0, #{})],
    {{{PE, _, PPE, _}, _}, null, []} = fuse_kinematics:combine(inverse_variance, Ms, pack()),
    ?assertEqual(1.5, PE),
    ?assertEqual(0.5, PPE).

pick_methods_test() ->
    Ms = [member(<<"a/1">>, <<"a">>, 5, 0.0, 9.0, #{}), member(<<"b/1">>, <<"b">>, 1, 3.0, 1.0, #{})],
    ?assertMatch({_, <<"b/1">>, []}, fuse_kinematics:combine(best, Ms, pack())),
    ?assertMatch({_, <<"b/1">>, []}, fuse_kinematics:combine(priority, Ms, pack())),
    ?assertMatch({_, <<"a/1">>, []}, fuse_kinematics:combine(latest, Ms, pack())).

covariance_intersection_test() ->
    Ms = [member(<<"a/1">>, <<"a">>, 0, 0.0, 1.0, #{}), member(<<"b/1">>, <<"b">>, 0, 3.0, 1.0, #{})],
    {_, null, [{<<"b/1">>, W}]} = fuse_kinematics:combine(covariance_intersection, Ms, pack()),
    ?assert(W >= 0 andalso W =< 1).

height_test() ->
    Ms = [member(<<"a/1">>, <<"a">>, 5, 0.0, 9.0, #{<<"hae">> => 10}),
          member(<<"b/1">>, <<"b">>, 1, 3.0, 1.0, #{<<"hae">> => 20})],
    ?assertEqual({10, <<"a/1">>}, fuse_kinematics:height(inverse_variance, null, Ms)),
    ?assertEqual({20, <<"b/1">>}, fuse_kinematics:height(best, <<"b/1">>, Ms)).

attributes_test() ->
    Ms = [member(<<"a/1">>, <<"a">>, 5, 0.0, 9.0, #{<<"k">> => <<"x">>, <<"n">> => 3}),
          member(<<"b/1">>, <<"b">>, 1, 3.0, 1.0, #{<<"k">> => <<"y">>, <<"n">> => 7}),
          member(<<"c/1">>, <<"c">>, 2, 3.0, 1.0, #{<<"k">> => <<"y">>, <<"n">> => true})],
    P = (pack())#{attributes => [{<<"k">>, majority}, {<<"n">>, max}, {<<"z">>, latest},
                                 {<<"k">>, priority}]},
    {Map, Trace} = fuse_attributes:attributes(<<"g">>, Ms, P),
    ?assertEqual(4, length(Trace)),
    ?assertEqual(#{<<"value">> => <<"y">>, <<"from">> => <<"b/1">>}, maps:get(<<"k">>, Map)),
    %% max takes numbers only; true is not a number
    ?assertMatch([_, #{<<"winner">> := <<"b/1">>, <<"candidates">> := [_, _]} | _], Trace),
    ?assertMatch([_, _, #{<<"winner">> := null} | _], Trace).

pack_test() ->
    Good = <<"pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 "
             "unknown_vel_ms=100\nkinematics best\nstale_ms 10\nattribute k rule=max\r\n">>,
    {ok, P} = fuse_pack:parse(Good),
    ?assertEqual(best, maps:get(kinematics, P)),
    ?assertEqual([{<<"k">>, max}], maps:get(attributes, P)),
    ?assertMatch({error, _}, fuse_pack:parse(binary:replace(Good, <<"best">>, <<"Best">>))),
    ?assertMatch({error, _}, fuse_pack:parse(binary:replace(Good, <<"rule=max">>, <<"rule=mode">>))),
    ?assertMatch({error, _}, fuse_pack:parse(<<Good/binary, "source a\nsource a\n">>)).

%% Covariance intersection when one member is better on one axis and worse
%% on the other: the weight is the interior minimum (c2 < 0), clamped to
%% [0, 1].
covariance_intersection_crossing_test() ->
    X = {<<"a/1">>, #{time => 0, report => #{}},
         #{east => {0.0, 0.0, 1.0, 0.0, 1.0}, north => {0.0, 0.0, 9.0, 0.0, 1.0}}},
    Y = {<<"b/1">>, #{time => 0, report => #{}},
         #{east => {1.0, 0.0, 9.0, 0.0, 1.0}, north => {1.0, 0.0, 1.0, 0.0, 1.0}}},
    {_, null, [{<<"b/1">>, W}]} = fuse_kinematics:combine(covariance_intersection, [X, Y], pack()),
    ?assert(W > 0 andalso W < 1),
    Z = {<<"c/1">>, #{time => 0, report => #{}},
         #{east => {1.0, 0.0, 1.0e-6, 0.0, 1.0}, north => {1.0, 0.0, 100.0, 0.0, 1.0}}},
    {_, null, [_, {<<"c/1">>, W2}]} = fuse_kinematics:combine(covariance_intersection, [X, Y, Z], pack()),
    ?assert(W2 >= 0 andalso W2 =< 1).

pack_numbers_test() ->
    Text = fun(Q) -> <<"pack p\nversion 1\nfilter accel_var=", Q/binary,
                       " default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics best\nstale_ms 10\n">> end,
    {ok, P} = fuse_pack:parse(Text(<<"1.5">>)),
    ?assertEqual(1.5, maps:get(<<"accel_var">>, maps:get(filter, P))),
    {ok, P2} = fuse_pack:parse(Text(<<"15e-1">>)),
    ?assertEqual(1.5, maps:get(<<"accel_var">>, maps:get(filter, P2))),
    ?assertMatch({error, {not_finite, _}}, fuse_pack:parse(Text(<<"1e400">>))).
