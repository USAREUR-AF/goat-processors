%% Tests (correlate.md "Tests"): the table of test kinds and the runner.
%%
%% The registration point of a test kind. A kind is
%%   #{params => [Name], values => number | text, run => fun((Params, View) -> Result)}
%% with View = {EA, EB, PredB} (correlate:pair_view/3) and Result
%% {Pass, Fields}, Fields the record's test, value and limit (and skipped).
%% builtin/0 is the spec's table; a pack loaded with
%% correlate:load_pack(Dir, #{tests => #{Name => Kind}}) also knows the
%% extra kinds, for that pack only. Adding a kind is one entry here.
-module(correlate_test_kinds).
-export([builtin/0, table/1, run_tests/5]).
-export([distance/2, window/2, mahalanobis/2, course/2, speed/2, altitude/2, same/2]).

builtin() ->
    #{<<"distance">> => kind([<<"max_m">>], number, fun ?MODULE:distance/2),
      <<"window">> => kind([<<"multiplier">>, <<"window_m">>, <<"err_min_m">>, <<"err_max_m">>],
                           number, fun ?MODULE:window/2),
      <<"mahalanobis">> => kind([<<"gate">>], number, fun ?MODULE:mahalanobis/2),
      <<"course">> => kind([<<"max_deg">>, <<"min_speed_ms">>], number, fun ?MODULE:course/2),
      <<"speed">> => kind([<<"max_pct">>, <<"min_speed_ms">>], number, fun ?MODULE:speed/2),
      <<"altitude">> => kind([<<"max_m">>], number, fun ?MODULE:altitude/2),
      <<"same">> => kind([<<"key">>], text, fun ?MODULE:same/2)}.

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

window(P, {EA, EB, PredB}) ->
    #{<<"multiplier">> := M, <<"window_m">> := W,
      <<"err_min_m">> := Lo, <<"err_max_m">> := Hi} = P,
    Ea = clamp(maps:get(ce, EA), Lo, Hi),
    Eb = clamp(maps:get(ce, EB), Lo, Hi),
    Limit = M * math:sqrt(Ea * Ea + Eb * Eb) + W,
    V = correlate_gating:distance(maps:get(filter, EA), PredB),
    result(<<"window">>, V, Limit, V < Limit).

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

clamp(X, Lo, Hi) -> max(Lo, min(Hi, X)).
