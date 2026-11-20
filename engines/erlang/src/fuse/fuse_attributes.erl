%% Attributes (fuse.md "Attributes"): one result per attribute line, in pack
%% order, each with its trace record. The rules are rules/0 (the pack's
%% attribute lines name them); adding a rule is one entry there. Pure.
-module(fuse_attributes).
-export([rules/0, attributes/3]).
-export([priority/1, latest/1, max/1, min/1, majority/1]).

%% Each rule's winner among the candidates [{Member, Value, Time, Rank,
%% RankOrNull}] in key order, and whether it takes numbers only.
rules() ->
    #{priority => {any, fun ?MODULE:priority/1},
      latest => {any, fun ?MODULE:latest/1},
      max => {number, fun ?MODULE:max/1},
      min => {number, fun ?MODULE:min/1},
      majority => {any, fun ?MODULE:majority/1}}.

%% The event's map holds the attributes that have a winner.
attributes(G, Members, Pack) ->
    Results = [attribute(G, Key, Rule, Members, Pack) || {Key, Rule} <- maps:get(attributes, Pack)],
    {maps:from_list([{Key, #{<<"value">> => V, <<"from">> => W}}
                     || {{Key, W, V}, _} <- Results, W =/= null]),
     [Tr || {_, Tr} <- Results]}.

attribute(G, Key, Rule, Members, Pack) ->
    {Takes, Winner} = maps:get(Rule, rules()),
    Cands = [{K, maps:get(Key, maps:get(report, E)), maps:get(time, E), fuse:rank(E, Pack),
              fuse:rank_or_null(E, Pack)}
             || {K, E, _} <- Members, usable(Takes, maps:get(Key, maps:get(report, E), null))],
    {W, V} = case Cands of
                 [] -> {null, null};
                 _ -> {Win, Value, _, _, _} = Winner(Cands), {Win, Value}
             end,
    {{Key, W, V}, trace_fuse:attribute(G, Key, Rule, Cands, W, V)}.

%% Usable value: a string, number or boolean; a number (not a boolean) for
%% max and min. Erlang booleans are atoms, never numbers.
usable(number, V) -> is_number(V);
usable(any, V) -> is_binary(V) orelse is_number(V) orelse is_boolean(V).

priority(Cands) -> fuse:first_best(Cands, fun({_, _, _, R, _}) -> R end).
latest(Cands) -> fuse:first_best(Cands, fun({_, _, T, _, _}) -> -T end).
max(Cands) -> fuse:first_best(Cands, fun({_, V, _, _, _}) -> -V end).
min(Cands) -> fuse:first_best(Cands, fun({_, V, _, _, _}) -> V end).

majority(Cands) ->
    %% Classes of equal values, in order of their first holder: {First, Count}.
    Classes = lists:foldl(
                fun(C = {_, V, _, _, _}, Acc) ->
                        case lists:splitwith(fun({{_, FV, _, _, _}, _}) -> not equal(FV, V) end,
                                             Acc) of
                            {Before, [{First, N} | After]} -> Before ++ [{First, N + 1} | After];
                            {_, []} -> Acc ++ [{C, 1}]
                        end
                end, [], Cands),
    {First, _} = fuse:first_best(Classes, fun({_, N}) -> -N end),
    First.

%% majority equality: strings byte for byte, numbers by value, booleans by
%% identity; values of different kinds are never equal.
equal(A, B) when is_number(A), is_number(B) -> A == B;
equal(A, B) -> A =:= B.
