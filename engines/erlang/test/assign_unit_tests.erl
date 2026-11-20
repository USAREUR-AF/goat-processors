%% Unit tests of src/assign: ranking (against every assignment), memberships,
%% sensor bias.
-module(assign_unit_tests).
-include_lib("eunit/include/eunit.hrl").

ranked_ties_by_vector_test() ->
    Rows = [{[1.0, 1.0], 1.0}],
    ?assertEqual([{1.0, [0], [1.0]}, {1.0, [1], [1.0]}, {1.0, [2], [1.0]}],
                 assign_rank:ranked(Rows, 2, 5)),
    ?assertEqual([{0.0, [], []}], assign_rank:ranked([], 3, 2)).

total_sorted_sum_test() ->
    ?assertEqual(0.0 + -1.0 + 0.5 + 2.0, assign_rank:total([2.0, 0.5, -1.0])).

membership_test() ->
    M0 = assign_membership:empty(),
    {M1, E1} = assign_membership:start(<<"a">>, {M0, []}),
    ?assertEqual(1, assign_membership:system_of(<<"a">>, M1)),
    {M2, E2} = assign_membership:join(<<"b">>, 1, {M1, E1}),
    ?assertEqual(#{1 => [<<"a">>, <<"b">>]}, maps:get(systems, M2)),
    {M3, E3} = assign_membership:leave(<<"a">>, 1, <<"assign">>, {M2, E2}),
    {M4, E4} = assign_membership:leave(<<"b">>, 1, <<"stale">>, {M3, E3}),
    ?assertEqual(#{}, maps:get(systems, M4)),
    ?assertEqual([<<"start">>, <<"join">>, <<"leave">>, <<"leave">>, <<"end">>],
                 [maps:get(<<"ev">>, E) || E <- E4]),
    ?assertEqual(none, assign_membership:system_of(<<"a">>, M4)).

stale_record_and_apply_test() ->
    Mem = #{systems => #{1 => [<<"a">>, <<"b">>], 2 => [<<"c">>]}, next => 3},
    R = assign_membership:stale_record(Mem, [<<"a">>], [<<"c">>]),
    ?assertEqual(0.0, maps:get(cost, R)),
    ?assertEqual(#{1 => [<<"b">>]}, maps:get(systems, maps:get(membership, R))),
    ?assertEqual([<<"leave">>, <<"drop">>, <<"leave">>, <<"end">>],
                 [maps:get(<<"ev">>, E) || E <- maps:get(events, R)]),
    R2 = assign_membership:apply_assignment([{<<"c">>, 1, 0.5}, {<<"d">>, alone, 9.0}], 9.5, R),
    ?assertEqual(9.5, maps:get(cost, R2)),
    ?assertEqual([[<<"c">>, <<"s1">>], [<<"d">>, <<"alone">>]], maps:get(choices, R2)),
    ?assertEqual(#{1 => [<<"b">>, <<"c">>], 3 => [<<"d">>]},
                 maps:get(systems, maps:get(membership, R2))),
    ?assertEqual(9.5, assign_membership:total([R, R2])),
    ?assertEqual(Mem, assign_membership:latest([], Mem)).

restarted_without_system_test() ->
    Mem = #{systems => #{1 => [<<"a">>]}, next => 2},
    R = assign_membership:stale_record(Mem, [], [<<"x">>]),
    ?assertEqual(Mem, maps:get(membership, R)),
    ?assertEqual([], maps:get(events, R)).

pred(P) -> #{east => {P, 1.0, 4.0, 0.0, 1.0}, north => {P, 1.0, 4.0, 0.0, 1.0}}.

bias_move_test() ->
    Pairs = #{{<<"a">>, <<"b">>} => (assign_bias:initial(10))#{oe := 5.0, on := -5.0, var := 2.0,
                                                               tau := 0.5}},
    %% no bias line, or one source: not moved
    ?assertEqual(pred(1.0), assign_bias:move(pred(1.0), <<"a">>, <<"b">>, none)),
    ?assertEqual(pred(1.0), assign_bias:move(pred(1.0), <<"a">>, <<"a">>, {Pairs, 10, false})),
    %% B = b seen by a: pair a|b, a first, so p - o; pp + var
    #{east := {PE, _, PPE, _, _}, north := {PN, _, _, _, _}} =
        assign_bias:move(pred(1.0), <<"a">>, <<"b">>, {Pairs, 10, false}),
    ?assertEqual({-4.0, 6.0, 6.0}, {PE, PN, PPE}),
    %% B = a seen by b: p + o; with time_offset o - v*tau
    #{east := {QE, _, _, _, _}} = assign_bias:move(pred(1.0), <<"b">>, <<"a">>, {Pairs, 10, true}),
    ?assertEqual(1.0 + (5.0 - 1.0 * 0.5), QE),
    %% a pair with no state: o = 0, var = s²
    #{east := {RE, _, RPE, _, _}} = assign_bias:move(pred(1.0), <<"c">>, <<"a">>, {Pairs, 10, false}),
    ?assertEqual({1.0, 104.0}, {RE, RPE}).

bias_observe_test() ->
    Params = #{<<"sigma_m">> => 10, <<"floor_m">> => 1, <<"gate">> => 13.82},
    S0 = assign_bias:initial(10),
    {D2, true, S1} = assign_bias:observe(S0, pred(0.0), pred(3.0), Params, none),
    ?assert(D2 > 0),
    ?assertEqual(1, maps:get(n, S1)),
    %% the first accepted pair takes its offset whole: w = 1/r, o = y
    ?assertEqual(3.0, maps:get(oe, S1)),
    {_, false, S0} = assign_bias:observe(S0, pred(0.0), pred(300.0), Params, none),
    {_, true, S2} = assign_bias:observe(S0, pred(0.0), pred(3.0), Params, #{<<"sigma_ms">> => 500}),
    ?assertEqual(8, tuple_size(maps:get(sums, S2))).

cost_and_fused_test() ->
    F = assign_cost:fused([pred(0.0), pred(2.0)]),
    ?assertEqual({1.0, 1.0, 2.0, 0.5}, maps:get(east, F)),
    %% (0 - 1)² / (4 + 0 + 2) per axis
    ?assertEqual(2 * (1 / 6.0), assign_cost:cost(pred(0.0), {0.0, 0.0}, F)).
