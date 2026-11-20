%% Kinematics (fuse.md "Kinematics", "Fused event" Height): the five
%% methods and the height. The table of methods is methods/0 (the pack's
%% kinematics line names one); adding a method is one entry there. Pure:
%% each method maps the members [{Key, Entity, Predicted}] in key order to
%% {{East, North}, From, Folds}, an axis {p, v, pp, vv}, From the member it
%% comes from (or null), Folds [{Y, W}] for the intersect trace.
-module(fuse_kinematics).
-export([methods/0, combine/3, height/3, var/1]).
-export([inverse_variance/2, covariance_intersection/2, best/2, priority/2, latest/2]).

methods() ->
    #{inverse_variance => fun ?MODULE:inverse_variance/2,
      covariance_intersection => fun ?MODULE:covariance_intersection/2,
      best => fun ?MODULE:best/2,
      priority => fun ?MODULE:priority/2,
      latest => fun ?MODULE:latest/2}.

combine(Method, Members, Pack) -> (maps:get(Method, methods()))(Members, Pack).

%% Position variance var = ppe + ppn of a predicted filter.
var(#{east := {_, _, PPE, _, _}, north := {_, _, PPN, _, _}}) -> PPE + PPN.

%% The axes {p, v, pp, vv} of a predicted filter.
axes(#{east := {PE, VE, PPE, _, VVE}, north := {PN, VN, PPN, _, VVN}}) ->
    {{PE, VE, PPE, VVE}, {PN, VN, PPN, VVN}}.

inverse_variance(Members, _Pack) ->
    Axes = [axes(P) || {_, _, P} <- Members],
    {{inverse_variance_axis([E || {E, _} <- Axes]),
      inverse_variance_axis([N || {_, N} <- Axes])}, null, []}.

covariance_intersection([{_, _, P0} | Rest], _Pack) ->
    {X, Folds} = intersect(axes(P0), Rest, []),
    {X, null, Folds}.

best(Members, _Pack) -> pick(Members, fun({_, _, P}) -> var(P) end).
priority(Members, Pack) -> pick(Members, fun({_, E, _}) -> fuse:rank(E, Pack) end).
latest(Members, _Pack) -> pick(Members, fun({_, E, _}) -> -maps:get(time, E) end).

%% best, priority, latest: the member with the smallest score, ties to key
%% order; its predicted filter, and from that member.
pick(Members, Score) ->
    {K, _, P} = fuse:first_best(Members, Score),
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

%% Height: with inverse_variance and covariance_intersection, the hae of the
%% member with the latest report that has one (ties to key order); with the
%% other methods, the from member's hae. none without one.
height(Method, _From, Members)
  when Method =:= inverse_variance; Method =:= covariance_intersection ->
    WithHae = [{K, E} || {K, E, _} <- Members, maps:is_key(<<"hae">>, maps:get(report, E))],
    case fuse:first_best(WithHae, fun({_, E}) -> -maps:get(time, E) end) of
        none -> none;
        {K, E} -> {maps:get(<<"hae">>, maps:get(report, E)), K}
    end;
height(_Method, From, Members) ->
    {From, E, _} = lists:keyfind(From, 1, Members),
    case maps:find(<<"hae">>, maps:get(report, E)) of
        {ok, H} -> {H, From};
        error -> none
    end.
