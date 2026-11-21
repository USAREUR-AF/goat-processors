%% Unit tests of src/correlate: pack, methods and tests tables, gating, the
%% test kinds, the entry point.
-module(correlate_unit_tests).
-include_lib("eunit/include/eunit.hrl").

base() ->
    <<"pack p\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
      "stale_ms 1000\n">>.

confirm() -> <<(base())/binary, "confirm_count 2\nhold_failures 2\n">>.
assign() -> <<(base())/binary, "method assign\nnew_cost 9\nkeep_bonus 1\n">>.

pack_method_test() ->
    {ok, C} = correlate_pack:parse(confirm()),
    ?assertEqual(correlate_confirm, maps:get(method, C)),
    {ok, A} = correlate_pack:parse(assign()),
    ?assertEqual(assign, maps:get(method, A)),
    ?assertMatch({error, {bad_method, _}},
                 correlate_pack:parse(<<(base())/binary, "method other\n">>)),
    %% a confirm directive under method assign is unknown
    ?assertMatch({error, {unknown_directive, <<"confirm_count">>}},
                 correlate_pack:parse(<<(assign())/binary, "confirm_count 2\n">>)),
    ?assertMatch({error, {missing, <<"new_cost">>}},
                 correlate_pack:parse(<<(base())/binary, "method assign\nkeep_bonus 1\n">>)).

pack_tests_table_test() ->
    {ok, P} = correlate_pack:parse(<<(confirm())/binary, "gate distance max_m=5\n"
                                     "gate same key=@env\nconfirm speed max_pct=1e1 min_speed_ms=.5\n">>),
    ?assertEqual([{<<"distance">>, #{<<"max_m">> => 5}}, {<<"same">>, #{<<"key">> => <<"@env">>}}],
                 maps:get(gate, P)),
    ?assertEqual([{<<"speed">>, #{<<"max_pct">> => 10.0, <<"min_speed_ms">> => 0.5}}],
                 maps:get(confirm, P)),
    ?assertMatch({error, {unknown_test, _}},
                 correlate_pack:parse(<<(confirm())/binary, "gate nope x=1\n">>)),
    ?assertMatch({error, _}, correlate_pack:parse(<<(confirm())/binary, "gate distance\n">>)),
    ?assertMatch({error, _}, correlate_pack:parse(<<(confirm())/binary, "gate distance max_m=5 x=1\n">>)).

pack_ranges_test() ->
    [?assertMatch({error, _}, correlate_pack:parse(T)) || T <- [
        binary:replace(confirm(), <<"default_ce_m=50">>, <<"default_ce_m=0">>),
        <<(confirm())/binary, "maneuver accel_var=0.5 p_enter=0.1 p_leave=0.1\n">>,
        <<(confirm())/binary, "maneuver accel_var=5 p_enter=0.5 p_leave=0.5\n">>,
        <<(confirm())/binary, "restart gate=0\n">>,
        <<(assign())/binary, "time_offset sigma_ms=5\n">>,
        <<(assign())/binary, "bias sigma_m=1 floor_m=2 gate=1\n">>,
        <<(assign())/binary, "margin 1\n">>,
        <<(assign())/binary, "hypotheses 2\n">>,
        <<(confirm())/binary, "time_default s error_ms=1\ntime_default s state=drifting\n">>,
        <<(confirm())/binary, "time_default s state=late\n">>,
        <<(confirm())/binary, "time_default error_ms=1\n">>]],
    {ok, P} = correlate_pack:parse(<<(confirm())/binary, "maneuver p_enter=0.1 accel_var=5 p_leave=0.1\n"
                                     "time_default s error_ms=+2e1\n">>),
    ?assertEqual(#{<<"s">> => #{<<"error_ms">> => 20.0}}, maps:get(time_default, P)).

numbers_test() ->
    ?assertEqual(12, correlate_pack:number(<<"12">>)),
    ?assertEqual(-0.5, correlate_pack:number(<<"-.5">>)),
    ?assertEqual(5.0, correlate_pack:number(<<"5.">>)),
    ?assertEqual(150.0, correlate_pack:number(<<"1.5E2">>)),
    ?assertThrow({pack_error, _}, correlate_pack:number(<<"1e">>)),
    ?assertEqual(-3, correlate_pack:integer(<<"-3">>)),
    ?assertThrow({pack_error, _}, correlate_pack:integer(<<"3.0">>)).

tables_test() ->
    ?assertEqual(#{<<"confirm">> => correlate_confirm, <<"assign">> => assign},
                 correlate_methods:builtin()),
    ?assertEqual(7, map_size(correlate_test_kinds:builtin())),
    ?assertEqual(8, map_size(correlate_test_kinds:table(#{<<"x">> => #{}}))).

filter(P, V, PP) -> #{east => {P, V, PP, 0.0, 1.0}, north => {P, V, PP, 0.0, 1.0}}.

gating_test() ->
    ?assertEqual(5.0, correlate_gating:distance(filter(0.0, 0, 1), #{east => {3.0, 0, 0, 0, 0},
                                                                    north => {4.0, 0, 0, 0, 0}})),
    %% (0 - 2)² / (3 + 1) + (0 - 2)² / (3 + 3)
    ?assertEqual(4 / 4.0 + 4 / 6.0, correlate_gating:d2(filter(0.0, 0, 1), {1.0, 3.0}, filter(2.0, 0, 3.0))).

entity(Report, Ce) -> #{filter => filter(0.0, 0.0, 1.0), r => {1.0, 1.0}, ce => Ce, report => Report}.

test_kinds_test() ->
    A = entity(#{<<"course">> => 10, <<"speed_ms">> => 10, <<"hae">> => 5, <<"type">> => <<"a-f-A">>}, 10),
    B = entity(#{<<"course">> => 350, <<"speed_ms">> => 5, <<"hae">> => 1, <<"type">> => <<"a-f-G">>}, 20),
    View = {A, B, filter(3.0, 0.0, 1.0)},
    ?assertMatch({true, #{<<"value">> := 20}}, correlate_test_kinds:course(
                                                 #{<<"max_deg">> => 45, <<"min_speed_ms">> => 1}, View)),
    ?assertMatch({false, #{<<"value">> := 50.0}}, correlate_test_kinds:speed(
                                                    #{<<"max_pct">> => 40, <<"min_speed_ms">> => 1}, View)),
    ?assertMatch({true, #{<<"skipped">> := true}}, correlate_test_kinds:speed(
                                                     #{<<"max_pct">> => 40, <<"min_speed_ms">> => 6}, View)),
    ?assertMatch({true, #{<<"value">> := 4}}, correlate_test_kinds:altitude(#{<<"max_m">> => 5}, View)),
    ?assertMatch({false, #{<<"value">> := <<"A">>, <<"limit">> := <<"G">>}},
                 correlate_test_kinds:same(#{<<"key">> => <<"@env">>}, View)),
    {Pass, #{<<"value">> := D}} = correlate_test_kinds:distance(#{<<"max_m">> => 5}, View),
    ?assert(Pass andalso abs(D - math:sqrt(18)) < 1.0e-12),
    %% state: per axis (9 * 2) / (2 * 2) = 4.5, plus 4 * 4 / (2 * 2 * 2) = 2 for
    %% hae; 5 degrees of freedom, limit the table's 15.0863 at 0.99.
    TA = A#{timing => {0.0, 0.0}},
    ?assertMatch({true, #{<<"value">> := 11.0, <<"limit">> := 15.0863, <<"dof">> := 5}},
                 correlate_test_kinds:state(#{<<"probability">> => 0.99, <<"hae_sigma_m">> => 2},
                                            {TA, B, filter(3.0, 0.0, 1.0)})),
    ?assertMatch({true, #{<<"value">> := 9.0, <<"limit">> := 13.2767, <<"dof">> := 4}},
                 correlate_test_kinds:state(#{<<"probability">> => 0.99, <<"hae_sigma_m">> => 2},
                                            {TA, B#{report := #{}}, filter(3.0, 0.0, 1.0)})),
    ?assert(correlate_test_kinds:state_check(#{<<"probability">> => 0.995, <<"hae_sigma_m">> => 1})),
    ?assertNot(correlate_test_kinds:state_check(#{<<"probability">> => 0.9, <<"hae_sigma_m">> => 1})),
    ?assertNot(correlate_test_kinds:state_check(#{<<"probability">> => 0.99, <<"hae_sigma_m">> => 0})),
    ?assertMatch({true, _}, correlate_test_kinds:mahalanobis(#{<<"gate">> => 10}, View)).

engine_test() ->
    {ok, P} = correlate_pack:parse(<<(confirm())/binary, "gate distance max_m=500\n">>),
    St0 = correlate:new(P),
    R = #{<<"track.source_id">> => <<"a">>, <<"uid">> => <<"1">>, <<"time_ms">> => 1000,
          <<"lat">> => 50.0, <<"lon">> => 8.0},
    {[#{<<"ev">> := <<"new">>}], [], St1} = correlate:ingest(R, St0),
    {[#{<<"reason">> := <<"out-of-order">>}], [], _} = correlate:ingest(R#{<<"time_ms">> := 0}, St1),
    {[#{<<"reason">> := <<"missing:uid">>}], [], _} = correlate:ingest(maps:remove(<<"uid">>, R), St1),
    {[#{<<"ev">> := <<"new">>}], [_, _], St2} =
        correlate:ingest(R#{<<"track.source_id">> := <<"b">>}, St1),
    ?assertMatch(#{<<"counts">> := #{<<"a/1|b/1">> := 1}}, correlate:snapshot(St2)),
    %% confirm_count 2: the second passing report correlates
    {[#{<<"ev">> := <<"correlate">>, <<"members">> := [<<"a/1">>, <<"b/1">>]}], [_, _, _], St3} =
        correlate:ingest(R#{<<"track.source_id">> := <<"b">>, <<"time_ms">> := 2000}, St2),
    ?assertMatch(#{<<"counts">> := #{<<"a/1|b/1">> := 0}, <<"next_group">> := 2},
                 correlate:snapshot(St3)),
    {[#{<<"ev">> := <<"fused">>}], [], _} = correlate:tick(2000, St3),
    {[_, _, _, #{<<"ev">> := <<"drop">>}], [], St4} = correlate:tick(5000, St3),
    ?assertMatch(#{<<"entities">> := E} when map_size(E) =:= 0, correlate:snapshot(St4)).

pack_number_beyond_binary64_test() ->
    ?assertMatch({error, {not_finite, _}},
                 correlate_pack:parse(binary:replace(confirm(), <<"accel_var=1">>, <<"accel_var=1e400">>))),
    ?assertMatch({error, _}, correlate_pack:parse(<<(confirm())/binary, "time_default\n">>)),
    ?assertMatch({error, _}, correlate_pack:parse(<<(confirm())/binary, "time_default s error_ms\n">>)).

track_test() ->
    Pack = #{filter => #{<<"accel_var">> => 1}, restart => #{<<"gate">> => 10}},
    Ent = #{time => 0, filter => filter(0.0, 1.0, 4.0)},
    ?assertEqual({{100, 100}, {0.0, 0.0}, none},
                 correlate_track:measurement_variance(error, 0, none, 10, 0, Pack)),
    {{RE, _}, {VarE, _}, {VarE, _}} =
        correlate_track:measurement_variance({ok, Ent}, 1000, none, 10, 1000, Pack),
    ?assertEqual(100 + VarE, RE),
    ?assert(VarE > 0),
    {D2, 10, Pass} = correlate_track:restart(Ent, 1000, {1.0, 1.0}, {1, 1}, Pack),
    ?assertEqual(D2 < 10, Pass),
    ?assertEqual(none, correlate_track:restart(Ent, 1000, {1.0, 1.0}, {1, 1}, maps:remove(restart, Pack))).
