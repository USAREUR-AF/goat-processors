%% The fuse engine (spec/fuse.md, version 0.1): load_pack, ingest, tick,
%% snapshot. Frame and the per-entity filter are correlate.md's, shared with
%% the correlator through correlator_filter.
%%
%% State is a value; ingest and tick return {Events, Trace, NewState}.
%% An entity is #{time, group, filter, report}: last_time_ms, the group name
%% (a binary, or null for its own unnamed group), the filter
%% #{east => {P, V, PP, PV, VV}, north => ...} and the last normalised report.
-module(fuse).
-export([load_pack/1, new/1, ingest/2, tick/2, snapshot/1]).

%% correlate.md "Reports": required keys in table order, with their type.
-define(REQUIRED, [{<<"track.source_id">>, string}, {<<"uid">>, string},
                   {<<"time_ms">>, integer}, {<<"lat">>, number}, {<<"lon">>, number}]).
%% correlate.md "Reports": optional keys, absent when of the wrong type (a ce
%% of 0 or below is absent); fuse.md "Reports": fuse.group, absent unless a
%% non-empty string.
-define(OPTIONAL, [{<<"hae">>, number}, {<<"ce">>, positive}, {<<"course">>, number},
                   {<<"speed_ms">>, number}, {<<"type">>, string}, {<<"stale_ms">>, integer},
                   {<<"fuse.group">>, nonempty_string}]).

load_pack(Dir) -> fuse_pack:load_pack(Dir).

new(Pack) -> #{pack => Pack, ref => none, entities => #{}}.

%% ================================================================ Reports

%% fuse.md "Reports": reject a missing required key; ignore a stale report;
%% otherwise accept the normalised report.
ingest(Report, St) ->
    case [K || {K, Type} <- ?REQUIRED, not typed(Type, maps:get(K, Report, null))] of
        [Missing | _] ->
            {[#{<<"ev">> => <<"reject">>, <<"reason">> => <<"missing:", Missing/binary>>}],
             [], St};
        [] ->
            R = normalise(Report),
            Key = <<(maps:get(<<"track.source_id">>, R))/binary, "/",
                    (maps:get(<<"uid">>, R))/binary>>,
            T = maps:get(<<"time_ms">>, R),
            case maps:find(Key, maps:get(entities, St)) of
                {ok, #{time := Last}} when T < Last ->
                    {[#{<<"ev">> => <<"stale-report">>, <<"entity">> => Key,
                        <<"time_ms">> => T, <<"last_time_ms">> => Last}], [], St};
                _ ->
                    accept(Key, R, St)
            end
    end.

typed(string, V) -> is_binary(V);
typed(nonempty_string, V) -> is_binary(V) andalso V =/= <<>>;
typed(integer, V) -> is_integer(V);
typed(number, V) -> is_number(V);
typed(positive, V) -> is_number(V) andalso V > 0.

%% The normalised report: every null key removed, and every optional key that
%% is treated as absent.
normalise(Report) ->
    maps:filter(fun(_K, null) -> false;
                   (K, V) ->
                        case lists:keyfind(K, 1, ?OPTIONAL) of
                            {K, Type} -> typed(Type, V);
                            false -> true
                        end
                end, Report).

%% Accept: frame reference, filter update (correlate.md "Track estimate"),
%% then the group (fuse.md "Groups"): new, move, or nothing.
accept(Key, R, St0) ->
    #{pack := Pack, entities := Ents} = St0,
    F = maps:get(filter, Pack),
    T = maps:get(<<"time_ms">>, R),
    Ref = case maps:get(ref, St0) of
              none -> {maps:get(<<"lat">>, R), maps:get(<<"lon">>, R)};
              Ref0 -> Ref0
          end,
    Z = correlator_filter:to_plane(Ref, maps:get(<<"lat">>, R), maps:get(<<"lon">>, R)),
    Ce = maps:get(<<"ce">>, R, maps:get(<<"default_ce_m">>, F)),
    Vel = correlator_filter:velocity(maps:get(<<"course">>, R, null),
                                     maps:get(<<"speed_ms">>, R, null)),
    Group = maps:get(<<"fuse.group">>, R, null),
    {Filter, Events} =
        case maps:find(Key, Ents) of
            error ->
                {correlator_filter:init(Z, Vel, Ce, F),
                 [#{<<"ev">> => <<"new">>, <<"entity">> => Key, <<"group">> => Group}]};
            {ok, #{time := Last, filter := Old, group := OldGroup}} ->
                {Updated, _} = correlator_filter:update(Old, (T - Last) / 1000,
                                                    maps:get(<<"accel_var">>, F), Z, Vel, Ce, F),
                {Updated,
                 case OldGroup =:= Group of
                     true -> [];
                     false -> [#{<<"ev">> => <<"move">>, <<"entity">> => Key,
                                 <<"from">> => OldGroup, <<"to">> => Group}]
                 end}
        end,
    Ent = #{time => T, group => Group, filter => Filter, report => R},
    {Events, [], St0#{ref := Ref, entities := Ents#{Key => Ent}}}.

%% ================================================================ Tick

%% fuse.md "On each tick": 1. staleness, 2. fused output per group.
tick(Now, St0) ->
    {Drops, St1} = staleness(Now, St0),
    {Fused, Trace} = fused_output(Now, St1),
    {Drops ++ Fused, Trace, St1}.

%% Step 1, staleness, entities in key order.
staleness(Now, St = #{pack := Pack, entities := Ents}) ->
    Stale = [K || K <- lists:sort(maps:keys(Ents)),
                  is_stale(maps:get(K, Ents), Now, maps:get(stale_ms, Pack))],
    Drops = [#{<<"ev">> => <<"drop">>, <<"entity">> => K,
               <<"group">> => maps:get(group, maps:get(K, Ents))} || K <- Stale],
    {Drops, St#{entities := maps:without(Stale, Ents)}}.

is_stale(#{time := Last, report := R}, Now, PackStale) ->
    Now - Last > PackStale orelse
        case maps:find(<<"stale_ms">>, R) of
            {ok, S} -> Now >= S;
            error -> false
        end.

%% fuse.md "Groups", output order: named groups in byte order of name, then
%% unnamed groups in key order of their one member. Members in key order.
groups(Ents) ->
    Keyed = lists:sort([{K, maps:get(group, E)} || K := E <- Ents]),
    Names = lists:usort([G || {_, G} <- Keyed, G =/= null]),
    [{G, [K || {K, GK} <- Keyed, GK =:= G]} || G <- Names] ++
        [{null, [K]} || {K, null} <- Keyed].

%% Step 2, fused output.
fused_output(Now, St) ->
    Results = [fuse_group(G, Ms, Now, St) || {G, Ms} <- groups(maps:get(entities, St))],
    {[Ev || {Ev, _} <- Results], lists:append([Tr || {_, Tr} <- Results])}.

%% One group: 2.1 predict, 2.2 combine, 2.3 attributes, 2.4 the fused event.
fuse_group(G, Ms, Now, St = #{pack := Pack, entities := Ents}) ->
    F = maps:get(filter, Pack),
    Method = maps:get(kinematics, Pack),
    %% Members as {Key, Entity, Predicted}, in key order.
    Members = [begin
                   E = maps:get(K, Ents),
                   {K, E, correlator_filter:predict(maps:get(filter, E),
                                                    (Now - maps:get(time, E)) / 1000,
                                                    maps:get(<<"accel_var">>, F))}
               end || K <- Ms],
    {{East, North}, From, Folds} = kinematics(Method, Members, Pack),
    FoldTrace = [#{<<"stage">> => <<"intersect">>, <<"group">> => G,
                   <<"member">> => Y, <<"value">> => W} || {Y, W} <- Folds],
    KinTrace = #{<<"stage">> => <<"kinematics">>, <<"group">> => G,
                 <<"method">> => atom_to_binary(Method),
                 <<"candidates">> => [#{<<"member">> => K, <<"var">> => var(P),
                                        <<"time_ms">> => maps:get(time, E),
                                        <<"rank">> => rank_or_null(E, Pack)}
                                      || {K, E, P} <- Members],
                 <<"winner">> => From},
    {Attributes, AttrTrace} = attributes(G, Members, Pack),
    Ev = fused_event(G, Ms, From, East, North, height(Method, From, Members), Attributes, St),
    {Ev, FoldTrace ++ [KinTrace | AttrTrace]}.

%% fuse.md "Fused event".
fused_event(G, Ms, From, {PE, VE, PPE, _}, {PN, VN, PPN, _}, Height, Attributes, St) ->
    {Lat, Lon} = correlator_filter:from_plane(maps:get(ref, St), PE, PN),
    C0 = math:atan2(VE, VN) * 180 / math:pi(),
    Course = if C0 < 0 -> C0 + 360; C0 >= 360 -> C0 - 360; true -> C0 end,
    Ev = #{<<"ev">> => <<"fused">>, <<"group">> => G, <<"members">> => Ms,
           <<"from">> => From, <<"lat">> => Lat, <<"lon">> => Lon,
           <<"course">> => Course, <<"speed_ms">> => math:sqrt(VE * VE + VN * VN),
           <<"ce">> => math:sqrt((PPE + PPN) / 2), <<"attributes">> => Attributes},
    case Height of
        none -> Ev;
        {Hae, HaeFrom} -> Ev#{<<"hae">> => Hae, <<"hae_from">> => HaeFrom}
    end.

%% fuse.md "Fused event", Height.
height(Method, _From, Members)
  when Method =:= inverse_variance; Method =:= covariance_intersection ->
    WithHae = [{K, E} || {K, E, _} <- Members, maps:is_key(<<"hae">>, maps:get(report, E))],
    case first_best(WithHae, fun({_, E}) -> -maps:get(time, E) end) of
        none -> none;
        {K, E} -> {maps:get(<<"hae">>, maps:get(report, E)), K}
    end;
height(_Method, From, Members) ->
    {From, E, _} = lists:keyfind(From, 1, Members),
    case maps:find(<<"hae">>, maps:get(report, E)) of
        {ok, H} -> {H, From};
        error -> none
    end.

%% ================================================================ Kinematics

%% Position variance var = ppe + ppn of a predicted filter.
var(#{east := {_, _, PPE, _, _}, north := {_, _, PPN, _, _}}) -> PPE + PPN.

%% Rank: index of the source among the pack's source lines; unlisted ranks
%% after every listed source (for comparison) and is null in the trace.
rank(E, #{sources := Ss}) ->
    Src = maps:get(<<"track.source_id">>, maps:get(report, E)),
    index(Src, Ss, 0).

index(_, [], I) -> I;
index(X, [X | _], I) -> I;
index(X, [_ | Rest], I) -> index(X, Rest, I + 1).

rank_or_null(E, Pack = #{sources := Ss}) ->
    case rank(E, Pack) of
        R when R =:= length(Ss) -> null;
        R -> R
    end.

%% One axis {p, v, pp, vv} of a predicted filter.
axes(#{east := {PE, VE, PPE, _, VVE}, north := {PN, VN, PPN, _, VVN}}) ->
    {{PE, VE, PPE, VVE}, {PN, VN, PPN, VVN}}.

%% Returns {{East, North}, From, Folds}; Folds is [{Y, W}] for intersect trace.
kinematics(inverse_variance, Members, _Pack) ->
    Axes = [axes(P) || {_, _, P} <- Members],
    {{inverse_variance_axis([E || {E, _} <- Axes]),
      inverse_variance_axis([N || {_, N} <- Axes])}, null, []};
kinematics(covariance_intersection, [{_, _, P0} | Rest], _Pack) ->
    {X, Folds} = intersect(axes(P0), Rest, []),
    {X, null, Folds};
kinematics(best, Members, _Pack) ->
    pick(Members, fun({_, _, P}) -> var(P) end);
kinematics(priority, Members, Pack) ->
    pick(Members, fun({_, E, _}) -> rank(E, Pack) end);
kinematics(latest, Members, _Pack) ->
    pick(Members, fun({_, E, _}) -> -maps:get(time, E) end).

%% best, priority, latest: the member with the smallest score, ties to key
%% order; its predicted filter, and from that member.
pick(Members, Score) ->
    {K, _, P} = first_best(Members, Score),
    {axes(P), K, []}.

%% inverse_variance, one axis, members in key order.
inverse_variance_axis(Axes) ->
    {IP, SP, IV, SV} =
        lists:foldl(fun({P, V, PP, VV}, {IP, SP, IV, SV}) ->
                            {IP + 1 / PP, SP + P / PP, IV + 1 / VV, SV + V / VV}
                    end, {0.0, 0.0, 0.0, 0.0}, Axes),
    PP = 1 / IP,
    VV = 1 / IV,
    {PP * SP, VV * SV, PP, VV}.

%% covariance_intersection: fold each later member Y into X, in key order.
intersect(X, [], Folds) -> {X, lists:reverse(Folds)};
intersect(X, [{K, _, P} | Rest], Folds) ->
    Y = axes(P),
    W = weight(X, Y),
    intersect(fold(W, X, Y), Rest, [{K, W} | Folds]).

%% Weight: steps 1 to 5.
weight({{_, _, XPPE, _}, {_, _, XPPN, _}}, {{_, _, YPPE, _}, {_, _, YPPN, _}}) ->
    AE = 1 / YPPE,
    AN = 1 / YPPN,
    DE = 1 / XPPE - AE,
    DN = 1 / XPPN - AN,
    C2 = DE * DN,
    C1 = AE * DN + AN * DE,
    if
        C2 < 0 -> clamp01(-C1 / (2 * C2));
        C1 + C2 > 0 -> 1.0;
        C1 + C2 < 0 -> 0.0;
        true -> 0.5
    end.

clamp01(W) when W < 0 -> 0.0;
clamp01(W) when W > 1 -> 1.0;
clamp01(W) -> W.

%% Fold: w = 1 keeps X, w = 0 takes Y, otherwise per axis.
fold(W, X, _Y) when W == 1 -> X;
fold(W, _X, Y) when W == 0 -> Y;
fold(W, {XE, XN}, {YE, YN}) -> {fold_axis(W, XE, YE), fold_axis(W, XN, YN)}.

fold_axis(W, {XP, XV, XPP, XVV}, {YP, YV, YPP, YVV}) ->
    A = W / XPP,
    B = (1 - W) / YPP,
    PP = 1 / (A + B),
    P = PP * (A * XP + B * YP),
    C = W / XVV,
    D = (1 - W) / YVV,
    VV = 1 / (C + D),
    V = VV * (C * XV + D * YV),
    {P, V, PP, VV}.

%% ================================================================ Attributes

%% fuse.md "Attributes": one record per attribute line, in pack order; the
%% event's map holds the attributes that have a winner.
attributes(G, Members, Pack) ->
    Results = [attribute(G, Key, Rule, Members, Pack) || {Key, Rule} <- maps:get(attributes, Pack)],
    {maps:from_list([{Key, #{<<"value">> => V, <<"from">> => W}}
                     || {{Key, W, V}, _} <- Results, W =/= null]),
     [Tr || {_, Tr} <- Results]}.

attribute(G, Key, Rule, Members, Pack) ->
    %% Candidates as {Member, Value, Time, Rank}, in key order.
    Cands = [{K, maps:get(Key, maps:get(report, E)), maps:get(time, E), rank(E, Pack),
              rank_or_null(E, Pack)}
             || {K, E, _} <- Members, usable(Rule, maps:get(Key, maps:get(report, E), null))],
    {W, V} = case Cands of
                 [] -> {null, null};
                 _ -> {Winner, Value, _, _, _} = winner(Rule, Cands), {Winner, Value}
             end,
    Trace = #{<<"stage">> => <<"attribute">>, <<"group">> => G, <<"key">> => Key,
              <<"rule">> => atom_to_binary(Rule),
              <<"candidates">> => [#{<<"member">> => K, <<"value">> => Val,
                                     <<"time_ms">> => T, <<"rank">> => RN}
                                   || {K, Val, T, _, RN} <- Cands],
              <<"winner">> => W, <<"value">> => V},
    {{Key, W, V}, Trace}.

%% Usable value: a string, number or boolean; a number (not a boolean) for
%% max and min. Erlang booleans are atoms, never numbers.
usable(Rule, V) when Rule =:= max; Rule =:= min -> is_number(V);
usable(_Rule, V) -> is_binary(V) orelse is_number(V) orelse is_boolean(V).

winner(priority, Cands) -> first_best(Cands, fun({_, _, _, R, _}) -> R end);
winner(latest, Cands) -> first_best(Cands, fun({_, _, T, _, _}) -> -T end);
winner(max, Cands) -> first_best(Cands, fun({_, V, _, _, _}) -> -V end);
winner(min, Cands) -> first_best(Cands, fun({_, V, _, _, _}) -> V end);
winner(majority, Cands) ->
    %% Classes of equal values, in order of their first holder: {First, Count}.
    Classes = lists:foldl(
                fun(C = {_, V, _, _, _}, Acc) ->
                        case lists:splitwith(fun({{_, FV, _, _, _}, _}) -> not equal(FV, V) end,
                                             Acc) of
                            {Before, [{First, N} | After]} -> Before ++ [{First, N + 1} | After];
                            {_, []} -> Acc ++ [{C, 1}]
                        end
                end, [], Cands),
    {First, _} = first_best(Classes, fun({_, N}) -> -N end),
    First.

%% majority equality: strings byte for byte, numbers by value, booleans by
%% identity; values of different kinds are never equal.
equal(A, B) when is_number(A), is_number(B) -> A == B;
equal(A, B) -> A =:= B.

%% The first element with the smallest score (ties to list order), or none.
first_best([], _Score) -> none;
first_best([X | Xs], Score) ->
    {_, Best} = lists:foldl(fun(Y, {S, B}) ->
                                    SY = Score(Y),
                                    if SY < S -> {SY, Y}; true -> {S, B} end
                            end, {Score(X), X}, Xs),
    Best.

%% ================================================================ Snapshot

snapshot(#{ref := Ref, entities := Ents}) ->
    Axis = fun({P, V, PP, PV, VV}) -> [P, V, PP, PV, VV] end,
    #{<<"ref">> => case Ref of none -> null; {Lat, Lon} -> [Lat, Lon] end,
      <<"entities">> =>
          maps:map(fun(_K, #{time := T, group := G, filter := Fl, report := R}) ->
                           #{<<"last_time_ms">> => T, <<"group">> => G,
                             <<"filter">> => #{<<"east">> => Axis(maps:get(east, Fl)),
                                               <<"north">> => Axis(maps:get(north, Fl))},
                             <<"report">> => R}
                   end, Ents)}.
