%% Ranking (correlate-assign.md "Ranking"): the first K assignments of the
%% rows of one source, ordered by total and, for equal totals, by choice
%% vector. Pure.
%%
%% The result is the first K of every assignment ordered by (total, choice
%% vector), as the spec defines it (every/3 is that definition, kept for the
%% tests), found without building every assignment: a depth-first search
%% over the rows, each row's options cheapest first, keeps the K smallest
%% totals found so far and leaves out a branch whose least possible total
%% (its entries so far plus each later row's cheapest entry) is above the
%% K-th of them by more than the slack, a bound far above any rounding of
%% the sums. Every assignment left out therefore has a total strictly above
%% K assignments found, so it is not among the first K; the ones found are
%% ordered by the same rule as every/3.
-module(assign_rank).
-export([ranked/3, every/3, total/1]).

%% Rows: per entity {[Cost | forbidden] per column, AloneCost}. Returns the
%% first K assignments, each {Total, ChoiceVector, Entries}. A choice index
%% is a column's position (0 first) or NCols for alone.
ranked(Rows, NCols, K) ->
    Options = [options(Row, NCols) || Row <- Rows],
    Least = rest_sums([element(2, hd(Os)) || Os <- Options]),
    Abs = lists:sum([lists:max([abs(C) || {_, C} <- Os]) || Os <- Options]),
    Slack = 1.0e-9 * (1 + Abs),
    {_, Found} = search(Options, Least, NCols, K, Slack, #{}, 0.0, [], [], {[], []}),
    lists:sublist(lists:sort(fun ranks_before/2, Found), K).

%% Every assignment, ordered: the definition (correlate-assign.md "Ranking").
every(Rows, NCols, K) ->
    All = [{total(Values), Vector, Values} || {Vector, Values} <- assignments(Rows, NCols, [])],
    lists:sublist(lists:sort(fun ranks_before/2, All), K).

ranks_before({T1, V1, _}, {T2, V2, _}) ->
    T1 < T2 orelse (T1 == T2 andalso V1 =< V2).

%% The total of an assignment: its entries in ascending order of value, added
%% left to right from 0.
total(Values) ->
    lists:foldl(fun(X, Acc) -> Acc + X end, 0.0, lists:sort(Values)).

%% ---------------------------------------------------------------- search

%% A row's options {J, Cost}: each column not forbidden, and alone; cheapest
%% first.
options({Costs, Alone}, NCols) ->
    lists:keysort(2, [{J, C} || {J, C} <- lists:zip(lists:seq(0, NCols - 1), Costs),
                                C =/= forbidden] ++ [{NCols, Alone}]).

%% [L0, L1, ..., 0.0]: Li the sum of the cheapest entries of rows i and on.
rest_sums(Mins) -> lists:foldr(fun(M, [S | _] = Acc) -> [M + S | Acc] end, [0.0], Mins).

%% Best is {Totals, Found}: the K smallest totals so far (ascending) and
%% every assignment found.
search([], _Least, _NCols, K, _Slack, _Taken, _Partial, VRev, CRev, {Totals, Found}) ->
    Values = lists:reverse(CRev),
    Total = total(Values),
    {lists:sublist(insert(Total, Totals), K), [{Total, lists:reverse(VRev), Values} | Found]};
search([Os | More], [_ | Least], NCols, K, Slack, Taken, Partial, VRev, CRev, Best0) ->
    Rest = hd(Least),
    lists:foldl(
      fun({J, C}, Best = {Totals, _}) ->
              case (J =:= NCols orelse not is_map_key(J, Taken))
                  andalso not pruned(Partial + C + Rest, Totals, K, Slack) of
                  false -> Best;
                  true ->
                      search(More, Least, NCols, K, Slack, Taken#{J => true}, Partial + C,
                             [J | VRev], [C | CRev], Best)
              end
      end, Best0, Os).

pruned(Bound, Totals, K, Slack) ->
    length(Totals) >= K andalso Bound - Slack > lists:last(Totals).

insert(T, []) -> [T];
insert(T, [X | Xs]) when T =< X -> [T, X | Xs];
insert(T, [X | Xs]) -> [X | insert(T, Xs)].

%% ---------------------------------------------------------------- every

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
