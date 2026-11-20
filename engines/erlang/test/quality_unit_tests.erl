%% Unit tests of src/quality: samples, measures, rules, pack, engine.
-module(quality_unit_tests).
-include_lib("eunit/include/eunit.hrl").

median_test() ->
    ?assertEqual(none, quality_samples:median([])),
    ?assertEqual(3, quality_samples:median([1, 3, 9])),
    ?assertEqual(2.0, quality_samples:median([1, 3])).

input_clock_test() ->
    Ents = #{<<"a/1">> => #{source => <<"a">>, last => 10},
             <<"a/2">> => #{source => <<"a">>, last => 30},
             <<"b/1">> => #{source => <<"b">>, last => 20},
             <<"c/1">> => #{source => <<"c">>, last => 5}},
    %% other sources' latest: b 20, c 5 -> mean of the two middle values
    ?assertEqual(12.5, quality_samples:input_clock(<<"a">>, Ents)),
    ?assertEqual(none, quality_samples:input_clock(<<"a">>, maps:with([<<"a/1">>], Ents))),
    ?assertEqual(30, quality_samples:source_latest(<<"a">>, Ents)),
    ?assertEqual(none, quality_samples:source_latest(<<"z">>, Ents)).

rec(Interval, Order, Ce) ->
    #{<<"interval">> => Interval, <<"order">> => Order, <<"ce">> => Ce, <<"vel">> => true,
      <<"hae">> => false, <<"time_state">> => null, <<"time_error">> => null,
      <<"latency">> => null, <<"lateness">> => null, <<"nis">> => null,
      <<"speed_err">> => null, <<"source_out_of_order">> => false}.

entity_measures_test() ->
    Table = quality_measures:builtin(),
    W = [rec(null, <<"first">>, true), rec(1000, <<"advance">>, false), rec(3000, <<"advance">>, true),
         rec(null, <<"duplicate">>, true)],
    Ms = quality_measures:entity(Table, #{window => W, last => 4000}, 5000, 2),
    ?assertEqual(4, maps:get(<<"reports">>, Ms)),
    ?assertEqual(3000, maps:get(<<"interval_last">>, Ms)),
    ?assertEqual(2000.0, maps:get(<<"interval_mean">>, Ms)),
    ?assertEqual(1000, maps:get(<<"age">>, Ms)),
    ?assertEqual(1, maps:get(<<"duplicate">>, Ms)),
    ?assertEqual(0.25, maps:get(<<"missing_ce">>, Ms)),
    ?assertEqual(1.0, maps:get(<<"missing_hae">>, Ms)),
    ?assertEqual(1.0, maps:get(<<"missing_time">>, Ms)),
    ?assertEqual(null, maps:get(<<"latency_mean">>, Ms)),
    ?assertEqual(23, map_size(Ms)),
    %% fewer than min_samples
    Few = quality_measures:entity(Table, #{window => W, last => 4000}, 5000, 5),
    ?assertEqual(null, maps:get(<<"interval_mean">>, Few)),
    ?assertEqual(null, maps:get(<<"missing_ce">>, Few)).

source_measures_test() ->
    Table = quality_measures:builtin(),
    E1 = maps:from_list([{N, null} || N <- quality_measures:entity_names(Table)]),
    A = E1#{<<"reports">> := 2, <<"age">> := 5, <<"interval_mean">> := 1.0, <<"interval_max">> := 3},
    B = E1#{<<"reports">> := 3, <<"age">> := 2, <<"interval_mean">> := 2.0},
    Ms = quality_measures:source(Table, [A, B]),
    ?assertEqual(5, maps:get(<<"reports">>, Ms)),
    ?assertEqual(2, maps:get(<<"age">>, Ms)),
    ?assertEqual(1.5, maps:get(<<"interval_mean">>, Ms)),
    ?assertEqual(3, maps:get(<<"interval_max">>, Ms)),
    ?assertEqual(null, maps:get(<<"nis_mean">>, Ms)),
    ?assertEqual(2, maps:get(<<"entities">>, Ms)),
    ?assertEqual(24, length(quality_measures:source_names(Table))).

pack() ->
    <<"pack q\nversion 1\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\n"
      "window window_ms=10000 min_samples=1 forget_ms=5000\n"
      "rule slow scope=entity measure=age op=> limit=1000 for=1 clear=500 action=downgrade factor=2\n"
      "rule few scope=source measure=entities op=< limit=2 for=2 clear=2 action=mark\n">>.

pack_test() ->
    {ok, P} = quality_pack:parse(pack()),
    ?assertMatch([#{name := <<"slow">>, factor := 2.0}, #{name := <<"few">>, factor := null}],
                 maps:get(rules, P)),
    [?assertMatch({error, _}, quality_pack:parse(T)) || T <- [
        binary:replace(pack(), <<"measure=age">>, <<"measure=entities">>),
        binary:replace(pack(), <<"clear=500">>, <<"clear=1500">>),
        binary:replace(pack(), <<" factor=2">>, <<>>),
        binary:replace(pack(), <<"for=2">>, <<"for=0">>),
        binary:replace(pack(), <<"limit=2">>, <<"limit=2e0">>),
        <<(pack())/binary, "rule slow scope=entity measure=age op=> limit=1 for=1 clear=0 action=alert\n">>,
        <<(pack())/binary, "\r\r\n">>]].

engine_test() ->
    {ok, P} = quality_pack:parse(pack()),
    St0 = quality:new(P),
    R = #{<<"track.source_id">> => <<"a">>, <<"uid">> => <<"1">>, <<"time_ms">> => 0,
          <<"lat">> => 50.0, <<"lon">> => 8.0, <<"ce">> => 10},
    {[#{<<"ev">> := <<"new">>}, #{<<"ev">> := <<"pass">>, <<"withheld">> := false}], _, St1} =
        quality:ingest(R, St0),
    {Evs, _, St2} = quality:tick(2000, St1),
    ?assertMatch([#{<<"ev">> := <<"quality">>}, #{<<"ev">> := <<"action-start">>},
                  #{<<"ev">> := <<"quality">>}], Evs),
    %% an advance on a/1: no new event; the active downgrade doubles ce
    {[#{<<"ev">> := <<"pass">>, <<"report">> := #{<<"ce">> := 20.0}, <<"rules">> := [<<"slow">>]}],
     _, St3} = quality:ingest(R#{<<"time_ms">> := 2500}, St2),
    {[#{<<"reason">> := <<"tick-out-of-order">>}], [], _} = quality:tick(1000, St3),
    {Forget, _, _} = quality:tick(20000, St3),
    ?assertMatch([#{<<"ev">> := <<"action-end">>, <<"reason">> := <<"forget">>},
                  #{<<"ev">> := <<"forget">>, <<"entity">> := <<"a/1">>},
                  #{<<"ev">> := <<"forget">>, <<"source">> := <<"a">>}], Forget).

rule(Op, Limit, Clear) ->
    #{name => <<"r">>, scope => entity, measure => <<"age">>, op => Op, limit => Limit,
      clear => Clear, for => 1, action => <<"alert">>, factor => null}.

rule_step_test() ->
    Off = #{count => 0, active => false},
    {5, true, #{active := true}, #{<<"ev">> := <<"action-start">>}} =
        quality_rules:step(rule(<<"<=">>, 5, 7), <<"s">>, Off, 5),
    {5, false, Off, none} = quality_rules:step(rule(<<"<=">>, 5, 7), <<"s">>, Off, 6),
    On = #{count => 0, active => true},
    {7, true, Off, #{<<"ev">> := <<"action-end">>, <<"reason">> := <<"clear">>}} =
        quality_rules:step(rule(<<"<">>, 5, 7), <<"s">>, On, 8),
    {7, false, On, none} = quality_rules:step(rule(<<"<">>, 5, 7), <<"s">>, On, null),
    {5, false, Off, none} = quality_rules:step(rule(<<">=">>, 5, 3), <<"s">>, Off, null).

marks_test() ->
    {ok, P0} = quality_pack:parse(<<"pack q\nversion 1\nfilter accel_var=1 default_ce_m=50 "
                                    "vel_sigma_ms=5 unknown_vel_ms=100\n"
                                    "window window_ms=10000 min_samples=1 forget_ms=5000\n"
                                    "rule m scope=entity measure=reports op=>= limit=1 for=1 "
                                    "clear=0 action=mark\n">>),
    R = #{<<"track.source_id">> => <<"a">>, <<"uid">> => <<"1">>, <<"time_ms">> => 0,
          <<"lat">> => 50.0, <<"lon">> => 8.0, <<"quality.marks">> => [<<"x">>, 1]},
    {_, _, St1} = quality:ingest(R, quality:new(P0)),
    {_, _, St2} = quality:tick(10, St1),
    %% a received list that is not all strings starts empty
    {[#{<<"report">> := #{<<"quality.marks">> := [<<"m">>]}}], _, _} =
        quality:ingest(R#{<<"time_ms">> := 20}, St2),
    {[#{<<"report">> := #{<<"quality.marks">> := [<<"x">>, <<"m">>]}}], _, _} =
        quality:ingest(R#{<<"time_ms">> := 20, <<"quality.marks">> := [<<"x">>]}, St2),
    ?assertMatch({error, rule_without_name},
                 quality_pack:parse(<<"pack q\nversion 1\nfilter accel_var=1 default_ce_m=50 "
                                      "vel_sigma_ms=5 unknown_vel_ms=100\n"
                                      "window window_ms=1 min_samples=1 forget_ms=1\nrule\n">>)).
