%% Ranking (correlate-assign.md "Ranking"): the first K assignments of the
%% rows of one source, ordered by total and, for equal totals, by choice
%% vector. Pure.
-module(assign_rank).
-export([ranked/3, total/1]).

%% Rows: per entity {[Cost | forbidden] per column, AloneCost}. Returns the
%% first K assignments, each {Total, ChoiceVector, Entries}. A choice index
%% is a column's position (0 first) or NCols for alone. Every assignment is
%% enumerated (exact, and small at vector sizes).
ranked(Rows, NCols, K) ->
    All = [{total(Values), Vector, Values}
           || {Vector, Values} <- assignments(Rows, NCols, [])],
    lists:sublist(lists:sort(fun ranks_before/2, All), K).

ranks_before({T1, V1, _}, {T2, V2, _}) ->
    T1 < T2 orelse (T1 == T2 andalso V1 =< V2).

%% Every assignment: each row takes a column not yet taken and not forbidden,
%% or alone. Returns [{ChoiceVector, Entries}].
assignments([], _NCols, _Taken) -> [{[], []}];
assignments([{Costs, Alone} | Rows], NCols, Taken) ->
    Options = [{J, C} || {J, C} <- lists:zip(lists:seq(0, NCols - 1), Costs),
                         C =/= forbidden, not lists:member(J, Taken)]
        ++ [{NCols, Alone}],
    [{[J | Vector], [C | Values]}
     || {J, C} <- Options,
        {Vector, Values} <- assignments(Rows, NCols, case J of NCols -> Taken; _ -> [J | Taken] end)].

%% The total of an assignment: its entries in ascending order of value, added
%% left to right from 0.
total(Values) ->
    lists:foldl(fun(X, Acc) -> Acc + X end, 0.0, lists:sort(Values)).
