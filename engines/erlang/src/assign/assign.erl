%% Method assign (spec/correlate-assign.md 0.7): system tracks, per-source
%% ranked assignments at each tick, kept as the best `hypotheses` histories
%% over a window of `window` ticks (only near-ties with `margin`), the
%% optional sensor bias per pair of sources with its optional clock offset
%% (`time_offset`), and the inverse-variance fused estimate. Reports, frame,
%% track estimate and tests are the correlator's (correlate.erl).
%%
%% The state holds the committed membership, the histories in rank order, the
%% retiring entities, the restarted entities (pack line restart) and the
%% sensor bias state per pair of sources (assign_bias).
-module(assign).
-behaviour(correlate_methods).
-export([directives/0, defaults/0, directive/2, check/1, finish_pack/1,
         new/1, entity_fields/0, restarted/2, reported/2, move/4, tick/2, snapshot/1]).

-import(correlate_pack, [number/1, integer/1, params/2, number_params/1]).
-import(io_pack, [fail/1]).
-import(trace_log, [emit/2, record/2]).

-define(BIAS_PARAMS, [<<"sigma_m">>, <<"floor_m">>, <<"gate">>]).
-define(TIME_OFFSET_PARAMS, [<<"sigma_ms">>]).

%% ---------------------------------------------------------------- pack

directives() ->
    {[<<"method">>, <<"new_cost">>, <<"keep_bonus">>],
     [],
     [<<"new_cost">>, <<"keep_bonus">>, <<"bias">>, <<"time_offset">>, <<"window">>,
      <<"hypotheses">>, <<"margin">>]}.

defaults() -> #{window => 1, hypotheses => 1}.

directive([<<"new_cost">>, N], P) -> P#{new_cost => number(N)};
directive([<<"keep_bonus">>, N], P) -> P#{keep_bonus => number(N)};
directive([<<"window">>, N], P) -> P#{window := integer(N)};
directive([<<"hypotheses">>, N], P) -> P#{hypotheses := integer(N)};
directive([<<"bias">> | Params], P) ->
    P#{bias => number_params(params(Params, ?BIAS_PARAMS))};
directive([<<"time_offset">> | Params], P) ->
    P#{time_offset => number_params(params(Params, ?TIME_OFFSET_PARAMS))};
directive([<<"margin">>, M], P) -> P#{margin => number(M)};
directive(_, _) -> unknown.

%% Ranges, once the whole file is read (correlate-assign.md "Pack").
check(P) ->
    %% bias: sigma_m and gate above 0, floor_m above 0 and at most sigma_m.
    case P of
        #{bias := #{<<"sigma_m">> := Sig, <<"floor_m">> := Floor, <<"gate">> := BG}} ->
            Sig > 0 orelse fail({not_above_zero, sigma_m}),
            BG > 0 orelse fail({not_above_zero, bias_gate}),
            Floor > 0 orelse fail({not_above_zero, floor_m}),
            Floor =< Sig orelse fail({above_sigma, floor_m});
        _ -> ok
    end,
    %% time_offset: sigma_ms above 0, and needs bias.
    case P of
        #{time_offset := #{<<"sigma_ms">> := TS}} ->
            TS > 0 orelse fail({not_above_zero, sigma_ms}),
            maps:is_key(bias, P) orelse fail(time_offset_without_bias);
        _ -> ok
    end,
    %% margin: above 0, and needs hypotheses above 1.
    case P of
        #{margin := M, hypotheses := HK} ->
            M > 0 orelse fail({not_above_zero, margin}),
            HK > 1 orelse fail({margin_without_hypotheses, HK});
        _ -> ok
    end,
    #{new_cost := NC, keep_bonus := KB, window := N, hypotheses := K} = P,
    NC > 0 orelse fail({not_above_zero, new_cost}),
    KB >= 0 orelse fail({below_zero, keep_bonus}),
    N >= 1 orelse fail({below_one, window}),
    K >= 1 orelse fail({below_one, hypotheses}),
    K =:= 1 orelse N > 1 orelse fail({hypotheses_without_window, K}),
    ok.

finish_pack(P) -> P.

%% ---------------------------------------------------------------- state

new(_Pack) ->
    #{reported => #{}, retiring => #{}, restarted => #{}, bias => #{},
      committed => assign_membership:empty(), histories => [[]]}.

entity_fields() -> #{}.

%% Restart: the entity is restarted until the next tick.
restarted(Key, St) -> St#{restarted := (maps:get(restarted, St))#{Key => true}}.

%% A report gives only new; the tick decides.
reported(Key, St) -> St#{reported := (maps:get(reported, St))#{Key => true}}.

move(Pred, ASrc, BSrc, St) -> assign_bias:move(Pred, ASrc, BSrc, assign_bias:context(St)).

snapshot(St) -> snapshot_assign:snapshot(St).

window(St) -> maps:get(window, maps:get(pack, St)).
hypotheses(St) -> maps:get(hypotheses, maps:get(pack, St)).

latest(History, St) -> assign_membership:latest(History, maps:get(committed, St)).

%% ---------------------------------------------------------------- tick (Window)

tick(Now, St0) ->
    Ents = maps:get(entities, St0),
    %% 1. Staleness, among entities that are not retiring.
    Stale = [K || K <- lists:sort(maps:keys(Ents)),
                  not maps:is_key(K, maps:get(retiring, St0)),
                  correlate:is_stale(maps:get(K, Ents), Now, St0)],
    %% Restarted entities (correlate.md "Restart") that are not stale leave
    %% their system track in the same new record; none is restarted after.
    Restarted = [K || K <- lists:sort(maps:keys(maps:get(restarted, St0))),
                      not lists:member(K, Stale)],
    Histories = [H ++ [assign_membership:stale_record(latest(H, St0), Stale, Restarted)]
                 || H <- maps:get(histories, St0)],
    St1 = St0#{histories := Histories, restarted := #{},
               retiring := maps:merge(maps:get(retiring, St0), maps:from_keys(Stale, true))},
    %% 2. Rows: entities reported since the previous tick, not found stale,
    %% grouped by source.
    Reported = [K || K <- lists:sort(maps:keys(maps:get(reported, St1))),
                     not lists:member(K, Stale)],
    Source = fun(K) -> maps:get(source, maps:get(K, Ents)) end,
    %% 3. Sources, in key order.
    St2 = lists:foldl(fun(Src, S) -> source(Src, [K || K <- Reported, Source(K) =:= Src], S) end,
                      St1, lists:usort([Source(K) || K <- Reported])),
    %% 4. Commit; 5. Bias; 6. Output.
    St3 = output(Now, assign_bias:update(Now, Reported, commit(St2))),
    trace_log:finish(St3#{reported := #{}}).

%% Step 3, one source: every history in rank order gives one candidate per
%% ranked assignment; the first k candidates are the histories for the next
%% source.
source(Src, R, St0) ->
    K = hypotheses(St0),
    {Candidates, St1} =
        lists:foldl(fun({H, History}, {Acc, S}) ->
                            {Cs, S1} = history_candidates(Src, R, H, History, S),
                            {Acc ++ Cs, S1}
                    end, {[], St0},
                    lists:zip(lists:seq(0, length(maps:get(histories, St0)) - 1),
                              maps:get(histories, St0))),
    Ordered = lists:sort(fun candidate_before/2, Candidates),
    %% The first k candidates are kept; with margin, of those only the ones
    %% whose total is at most cut = best + m, best the first candidate's total.
    [{Best, _, _, _} | _] = Ordered,
    Cut = case maps:find(margin, maps:get(pack, St1)) of
              error -> null;
              {ok, M} -> Best + M
          end,
    Numbered = [{I, C, I < K andalso (Cut =:= null orelse Total =< Cut)}
                || {I, C = {Total, _, _, _}} <- lists:zip(lists:seq(0, length(Ordered) - 1),
                                                          Ordered)],
    St2 = case window(St1) > 1 of
              false -> St1;
              true ->
                  lists:foldl(fun({_I, {Total, H, Rank, _}, Kept}, S) ->
                                      record((trace_assign:history(H, Rank, <<"total">>, Total, Kept))
                                             #{<<"limit">> := Cut}, S)
                              end, St1, Numbered)
          end,
    St2#{histories := [History || {_, {_, _, _, History}, true} <- Numbered]}.

%% Candidates are ordered by their total, then by h, then by r.
candidate_before({T1, H1, R1, _}, {T2, H2, R2, _}) ->
    T1 < T2 orelse (T1 == T2 andalso {H1, R1} =< {H2, R2}).

%% With window above 1 the source's trace records carry "h" (and "r").
tag(Rec, Keys, St) ->
    case window(St) > 1 of
        true -> maps:merge(Rec, Keys);
        false -> Rec
    end.

%% One history h: columns and entries against its newest record's membership,
%% the ranked assignments, and per assignment r one candidate
%% {Total, h, r, History}.
history_candidates(Src, R, H, History, St0) ->
    Newest = lists:last(History),
    Mem = maps:get(membership, Newest),
    %% Gate and cost records, tagged with h.
    Old = maps:get(trace, St0),
    {{Columns, Rows}, St1} = assign_cost:entries(Src, R, Mem, St0#{trace := []}),
    St2 = St1#{trace := [tag(T, #{<<"h">> => H}, St1) || T <- maps:get(trace, St1)] ++ Old},
    Ranked = assign_rank:ranked(Rows, length(Columns), hypotheses(St2)),
    lists:foldl(
      fun({Rank, {Total, Vector, Values}}, {Acc, S}) ->
              Choices = [{A, chosen(J, Columns), V}
                         || {A, J, V} <- lists:zip3(R, Vector, Values)],
              S1 = lists:foldl(fun({A, B, V}, S0) ->
                                       record(tag(trace_assign:assign(A, B, <<"choice">>, V, true),
                                                  #{<<"h">> => H, <<"r">> => Rank}, S0), S0)
                               end, S, Choices),
              Record = assign_membership:apply_assignment(Choices, Total, Newest),
              NewHistory = lists:droplast(History) ++ [Record],
              {Acc ++ [{assign_membership:total(NewHistory), H, Rank, NewHistory}], S1}
      end, {[], St2}, lists:zip(lists:seq(0, length(Ranked) - 1), Ranked)).

chosen(J, Columns) when J =:= length(Columns) -> alone;
chosen(J, Columns) -> element(1, lists:nth(J + 1, Columns)).

%% Step 4, commit, when the best history has n records.
commit(St0 = #{histories := Histories = [Best | _]}) ->
    case length(Best) =:= window(St0) of
        false -> St0;
        true ->
            Committed = hd(Best),
            Choices = maps:get(choices, Committed),
            Kept = [maps:get(choices, hd(H)) =:= Choices
                    || H <- Histories],
            St1 = case window(St0) > 1 of
                      false -> St0;
                      true ->
                          lists:foldl(fun({Rank, H, Keep}, S) ->
                                              record(trace_assign:history(
                                                       Rank, null, <<"commit">>,
                                                       assign_membership:total(H), Keep), S)
                                      end, St0,
                                      lists:zip3(lists:seq(0, length(Histories) - 1),
                                                 Histories, Kept))
                  end,
            Events = maps:get(events, Committed),
            St2 = trace_log:emit_all(Events, St1),
            Dropped = [E || #{<<"ev">> := <<"drop">>, <<"entity">> := E} <- Events],
            St2#{committed := maps:get(membership, Committed),
                 entities := maps:without(Dropped, maps:get(entities, St2)),
                 retiring := maps:without(Dropped, maps:get(retiring, St2)),
                 histories := [tl(H) || {H, true} <- lists:zip(Histories, Kept)]}
    end.

%% Step 6, output: one system per committed system track (with margin, per
%% system track of the best history's latest membership), then (window above
%% 1) one provisional per system track of the best history.
output(Now, St0) ->
    #{systems := Systems} = case maps:is_key(margin, maps:get(pack, St0)) of
                                false -> maps:get(committed, St0);
                                true -> latest(hd(maps:get(histories, St0)), St0)
                            end,
    St1 = lists:foldl(fun(S, Acc) -> emit(system_event(S, maps:get(S, Systems), Now, Acc), Acc) end,
                      St0, lists:sort(maps:keys(Systems))),
    case window(St1) > 1 of
        false -> St1;
        true ->
            #{systems := Latest} = latest(hd(maps:get(histories, St1)), St1),
            lists:foldl(fun(S, Acc) -> emit(trace_assign:provisional(S, maps:get(S, Latest)), Acc)
                        end, St1, lists:sort(maps:keys(Latest)))
    end.

%% Event system: fused estimate of all members at Now, hae from the member with
%% the greatest last_time_ms whose last report has one (ties to key order).
system_event(S, Ms, Now, St) ->
    #{east := {PE, VE, _, _}, north := {PN, VN, _, _}} =
        assign_cost:fused([correlate:predict(correlate:entity(M, St), Now, maps:get(pack, St))
                           || M <- Ms]),
    {Lat, Lon} = model_frame:from_plane(maps:get(ref, St), PE, PN),
    Ev = #{<<"ev">> => <<"system">>, <<"system">> => trace_assign:system_name(S),
           <<"members">> => Ms,
           <<"lat">> => Lat, <<"lon">> => Lon, <<"course">> => model_frame:course(VE, VN),
           <<"speed_ms">> => math:sqrt(VE * VE + VN * VN)},
    WithHae = [{maps:get(time, E), H} || M <- Ms, E <- [correlate:entity(M, St)],
                                         H <- [correlate:value(<<"hae">>, E)], is_number(H)],
    case WithHae of
        [] -> Ev;
        [First | Rest] ->
            {_, H} = lists:foldl(fun({T, X}, {TB, _}) when T > TB -> {T, X};
                                    (_, Best) -> Best
                                 end, First, Rest),
            Ev#{<<"hae">> => H}
    end.
