%% Tests (correlate.md 1.0 "Tests"): the table of test kinds and the runner.
%%
%% The registration point of a test kind. A kind is
%%   #{params => [Name], values => number | text, run => fun((Params, View) -> Result)}
%% and optionally check => fun((Params) -> boolean()), the ranges of its
%% parameters, checked when the pack loads (false is a load error),
%% with View = {EA, EB, PredB} (correlate:pair_view/3) and Result
%% {Pass, Fields}, Fields the record's test, value and limit (and skipped).
%% builtin/0 is the spec's table; a pack loaded with
%% correlate:load_pack(Dir, #{tests => #{Name => Kind}}) also knows the
%% extra kinds, for that pack only. Adding a kind is one entry here.
-module(correlate_test_kinds).
-export([builtin/0, table/1, run_tests/5]).
-export([distance/2, mahalanobis/2, course/2, speed/2, altitude/2, same/2, state/2,
         state_check/1, state_axes/1]).

builtin() ->
    #{<<"distance">> => kind([<<"max_m">>], number, fun ?MODULE:distance/2),
      <<"mahalanobis">> => kind([<<"gate">>], number, fun ?MODULE:mahalanobis/2),
      <<"course">> => kind([<<"max_deg">>, <<"min_speed_ms">>], number, fun ?MODULE:course/2),
      <<"speed">> => kind([<<"max_pct">>, <<"min_speed_ms">>], number, fun ?MODULE:speed/2),
      <<"altitude">> => kind([<<"max_m">>], number, fun ?MODULE:altitude/2),
      <<"same">> => kind([<<"key">>], text, fun ?MODULE:same/2),
      <<"state">> => (kind([<<"probability">>, <<"hae_sigma_m">>], number, fun ?MODULE:state/2))#{
                       check => fun ?MODULE:state_check/1}}.

kind(Params, Values, Run) -> #{params => Params, values => Values, run => Run}.

%% The built-in table with a pack's extra kinds.
table(Extra) -> maps:merge(builtin(), Extra).

%% Run tests in order between A and B, stopping at the first failure; one
%% record per test run. Returns {AllPassed, St}.
run_tests([], _Stage, _A, _B, St) -> {true, St};
run_tests(Tests, Stage, A, B, St) ->
    %% The view of the pair does not change while the tests run.
    run(Tests, Stage, A, B, correlate:pair_view(A, B, St),
        maps:get(tests, maps:get(pack, St)), St).

run([], _Stage, _A, _B, _View, _Table, St) -> {true, St};
run([{Name, Params} | Rest], Stage, A, B, View, Table, St) ->
    #{run := Run} = maps:get(Name, Table),
    {Pass, Fields} = Run(Params, View),
    St1 = trace_log:record(trace_correlate:test(Stage, A, B, Pass, Fields), St),
    case Pass of
        true -> run(Rest, Stage, A, B, View, Table, St1);
        false -> {false, St1}
    end.

result(Name, Value, Limit, Pass) -> {Pass, trace_correlate:result(Name, Value, Limit)}.
skipped(Name) -> {true, trace_correlate:skipped(Name)}.

%% ---------------------------------------------------------------- the kinds

distance(#{<<"max_m">> := Max}, {EA, _EB, PredB}) ->
    V = correlate_gating:distance(maps:get(filter, EA), PredB),
    result(<<"distance">>, V, Max, V < Max).

mahalanobis(#{<<"gate">> := Gate}, {EA, _EB, PredB}) ->
    V = correlate_gating:d2(maps:get(filter, EA), maps:get(r, EA), PredB),
    result(<<"mahalanobis">>, V, Gate, V < Gate).

course(#{<<"max_deg">> := Max, <<"min_speed_ms">> := Min}, {EA, EB, _}) ->
    case moving([EA, EB], Min, true) of
        [{CA, _}, {CB, _}] ->
            D = abs(CA - CB),
            V = min(D, 360 - D),
            result(<<"course">>, V, Max, V =< Max);
        skip -> skipped(<<"course">>)
    end.

speed(#{<<"max_pct">> := Max, <<"min_speed_ms">> := Min}, {EA, EB, _}) ->
    case moving([EA, EB], Min, false) of
        [{_, SA}, {_, SB}] ->
            Slow = min(SA, SB),
            Fast = max(SA, SB),
            V = case Fast == 0 of
                    true -> 0;
                    false -> abs(1 - Slow / Fast) * 100
                end,
            result(<<"speed">>, V, Max, V =< Max);
        skip -> skipped(<<"speed">>)
    end.

altitude(#{<<"max_m">> := Max}, {EA, EB, _}) ->
    case {correlate:value(<<"hae">>, EA), correlate:value(<<"hae">>, EB)} of
        {HA, HB} when is_number(HA), is_number(HB) ->
            V = abs(HA - HB),
            result(<<"altitude">>, V, Max, V =< Max);
        _ -> skipped(<<"altitude">>)
    end.

same(#{<<"key">> := K}, {EA, EB, _}) ->
    VA = correlate:value(K, EA),
    VB = correlate:value(K, EB),
    result(<<"same">>, VA, VB, same_value(VA, VB)).

%% same: numbers by value (1 equals 1.0), strings byte for byte, a string
%% never equals a number; null (absent) equals only null.
same_value(VA, VB) when is_number(VA), is_number(VB) -> VA == VB;
same_value(VA, VB) -> VA =:= VB.

%% Course and speed tests: skipped unless both entities have speed_ms (and,
%% for course, course) with speed at least min_speed_ms.
moving(Ents, Min, NeedCourse) ->
    CS = [{correlate:value(<<"course">>, E), correlate:value(<<"speed_ms">>, E)} || E <- Ents],
    case lists:all(fun({C, S}) -> (is_number(C) orelse not NeedCourse)
                                      andalso is_number(S) andalso S >= Min end, CS) of
        true -> CS;
        false -> skip
    end.

%% The state test: the full-state track-to-track statistic (Bar-Shalom 1981).
%% Per axis q (state_axis/2), east plus north, 4 degrees of freedom; with
%% both last reports' hae, plus dh*dh / (2*h*h), 5 degrees of freedom. The
%% limit is the chi-square quantile of the table, never computed.
state(#{<<"probability">> := Prob, <<"hae_sigma_m">> := H}, View = {EA, EB, _}) ->
    {{QE, _, _}, {QN, _, _}} = state_axes(View),
    {V, Dof} = case {correlate:value(<<"hae">>, EA), correlate:value(<<"hae">>, EB)} of
                   {HA, HB} when is_number(HA), is_number(HB) ->
                       Dh = HA - HB,
                       {QE + QN + Dh * Dh / (2 * H * H), 5};
                   _ -> {QE + QN, 4}
               end,
    Limit = chi2(Prob, Dof),
    {Pass, Fields} = result(<<"state">>, V, Limit, V < Limit),
    {Pass, Fields#{<<"dof">> => Dof}}.

%% The per-axis terms of the state test for the pair View = {EA, EB, PredB},
%% PredB B's prediction to A's time with B's timing variance added (and, with
%% method assign's bias, moved): {East, North}, each {Q, {Dp, Dv, Spp, Spv,
%% Svv}, Det}. Shared with the sequential test (correlate_sprt).
state_axes({EA, _EB, PredB}) ->
    #{east := FAE, north := FAN} = maps:get(filter, EA),
    #{east := FBE, north := FBN} = PredB,
    {TE, TN} = maps:get(timing, EA),
    {state_axis({FAE, TE}, FBE), state_axis({FAN, TN}, FBN)}.

%% One axis: A's filter [pa, va, ppa, pva, vva] with A's timing variance Ta,
%% B's prediction [pb, vb, ppb, pvb, vvb].
state_axis({{PA, VA, PPA, PVA, VVA}, Ta}, {PB, VB, PPB, PVB, VVB}) ->
    Dp = PA - PB,
    Dv = VA - VB,
    Spp = PPA + Ta + PPB,
    Spv = PVA + PVB,
    Svv = VVA + VVB,
    Det = Spp * Svv - Spv * Spv,
    Q = (Svv * Dp * Dp - 2 * Spv * Dp * Dv + Spp * Dv * Dv) / Det,
    {Q, {Dp, Dv, Spp, Spv, Svv}, Det}.

%% Chi-square quantiles (Abramowitz and Stegun 1964, table 26.8).
-define(CHI2, [{0.95, 9.4877, 11.0705}, {0.99, 13.2767, 15.0863},
               {0.995, 14.8603, 16.7496}, {0.999, 18.4668, 20.5150}]).

chi2(Prob, Dof) ->
    [{_, Q4, Q5}] = [Row || Row = {P, _, _} <- ?CHI2, P == Prob],
    case Dof of
        4 -> Q4;
        5 -> Q5
    end.

%% Pack: probability one of the table's values, compared as numbers;
%% hae_sigma_m above 0.
state_check(#{<<"probability">> := Prob, <<"hae_sigma_m">> := H}) ->
    lists:any(fun({P, _, _}) -> P == Prob end, ?CHI2) andalso H > 0.
