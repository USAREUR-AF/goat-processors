%% Method assign (spec/correlate-assign.md 0.6): system tracks, per-source ranked
%% assignments at each tick, kept as the best `hypotheses` histories over a
%% window of `window` ticks (only near-ties with `margin`), the optional sensor
%% bias per pair of sources with its optional clock offset (`time_offset`),
%% and the inverse-variance fused estimate.
%% Reports, frame, track estimate and tests are shared with correlator.
%%
%% Data, as in the spec's Memberships section:
%%   membership  #{systems => #{N => [Entity]}, next => N}   (system track sN)
%%   record      #{cost, choices => [[Entity, Chosen]], events, membership}
%%   history     [record], oldest first
%% The state holds the committed membership, the histories in rank order, the
%% retiring entities, the restarted entities (pack line restart) and the
%% sensor bias state per pair of sources (pack line bias):
%%   bias        #{{S, T} => #{oe, we, on, wn, var, n, tau, sums}}
%%               (pair key "S|T", S < T; tau in seconds and sums [S1..S8] are
%%               used only with the pack line time_offset)
-module(correlator_assign).
-export([new/1, tick/2, snapshot/1]).
%% Shared with correlator: Sensor bias, moving B into A's frame for a test.
-export([move/4]).

-import(correlator, [emit/2, record/2, entity/2, value/2]).

new(Pack) ->
    #{pack => Pack, ref => none, entities => #{}, reported => #{}, retiring => #{},
      restarted => #{}, bias => #{},
      committed => #{systems => #{}, next => 1},
      histories => [[]],
      events => [], trace => []}.

system_name(S) -> <<"s", (integer_to_binary(S))/binary>>.

window(St) -> maps:get(window, maps:get(pack, St)).
hypotheses(St) -> maps:get(hypotheses, maps:get(pack, St)).

%% ---------------------------------------------------------------- memberships

%% A history's latest membership: its newest record's, or the committed one.
latest([], St) -> maps:get(committed, St);
latest(History, _St) -> maps:get(membership, lists:last(History)).

%% A history's total: its records' costs added left to right from 0, oldest first.
total(History) -> lists:foldl(fun(#{cost := C}, Acc) -> Acc + C end, 0.0, History).

%% The system track A belongs to in a membership, or none.
system_of(A, #{systems := Systems}) ->
    case [S || {S, Ms} <- maps:to_list(Systems), lists:member(A, Ms)] of
        [S] -> S;
        [] -> none
    end.

%% Membership events. Each takes and returns {Membership, Events}, the events
%% in the order they happen.

%% Leave a system track; a system track left empty ends.
leave(A, S, Reason, {Mem = #{systems := Systems}, Evs}) ->
    Ev = #{<<"ev">> => <<"leave">>, <<"system">> => system_name(S), <<"entity">> => A,
           <<"reason">> => Reason},
    case lists:delete(A, maps:get(S, Systems)) of
        [] -> {Mem#{systems := maps:remove(S, Systems)},
               Evs ++ [Ev, #{<<"ev">> => <<"end">>, <<"system">> => system_name(S)}]};
        Rest -> {Mem#{systems := Systems#{S := Rest}}, Evs ++ [Ev]}
    end.

join(A, S, {Mem = #{systems := Systems}, Evs}) ->
    {Mem#{systems := Systems#{S := lists:sort([A | maps:get(S, Systems)])}},
     Evs ++ [#{<<"ev">> => <<"join">>, <<"system">> => system_name(S), <<"entity">> => A}]}.

%% Start a new system track alone, named by the membership's counter.
start(A, {Mem = #{systems := Systems, next := S}, Evs}) ->
    {Mem#{systems := Systems#{S => [A]}, next := S + 1},
     Evs ++ [#{<<"ev">> => <<"start">>, <<"system">> => system_name(S), <<"entity">> => A}]}.

%% ---------------------------------------------------------------- tick (Window)

tick(Now, St0) ->
    Ents = maps:get(entities, St0),
    %% 1. Staleness, among entities that are not retiring.
    Stale = [K || K <- lists:sort(maps:keys(Ents)),
                  not maps:is_key(K, maps:get(retiring, St0)),
                  correlator:is_stale(maps:get(K, Ents), Now, St0)],
    %% Restarted entities (correlate.md "Restart") that are not stale leave
    %% their system track in the same new record; none is restarted after.
    Restarted = [K || K <- lists:sort(maps:keys(maps:get(restarted, St0))),
                      not lists:member(K, Stale)],
    Histories = [H ++ [stale_record(latest(H, St0), Stale, Restarted)]
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
    St3 = output(Now, bias_update(Now, Reported, commit(St2))),
    correlator:finish(St3#{reported := #{}}).

%% Step 1: a copy of the latest membership with cost 0 and no choices, in which
%% each stale entity leaves its system track and is dropped, then each
%% restarted entity leaves its system track.
stale_record(Mem0, Stale, Restarted) ->
    {Mem1, Evs1} =
        lists:foldl(fun(K, Acc = {M, _}) ->
                            {M1, E1} = case system_of(K, M) of
                                           none -> Acc;
                                           S -> leave(K, S, <<"stale">>, Acc)
                                       end,
                            {M1, E1 ++ [#{<<"ev">> => <<"drop">>, <<"entity">> => K}]}
                    end, {Mem0, []}, Stale),
    {Mem, Evs} =
        lists:foldl(fun(K, Acc = {M, _}) ->
                            case system_of(K, M) of
                                none -> Acc;
                                S -> leave(K, S, <<"restart">>, Acc)
                            end
                    end, {Mem1, Evs1}, Restarted),
    #{cost => 0.0, choices => [], events => Evs, membership => Mem}.

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
                                      record((history_trace(H, Rank, <<"total">>, Total, Kept))
                                             #{<<"limit">> := Cut}, S)
                              end, St1, Numbered)
          end,
    St2#{histories := [History || {_, {_, _, _, History}, true} <- Numbered]}.

%% Candidates are ordered by their total, then by h, then by r.
candidate_before({T1, H1, R1, _}, {T2, H2, R2, _}) ->
    T1 < T2 orelse (T1 == T2 andalso {H1, R1} =< {H2, R2}).

history_trace(A, B, Test, Value, Pass) ->
    #{<<"stage">> => <<"history">>, <<"a">> => A, <<"b">> => B, <<"test">> => Test,
      <<"value">> => Value, <<"limit">> => null, <<"pass">> => Pass}.

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
    {{Columns, Rows}, St1} = entries(Src, R, Mem, St0#{trace := []}),
    St2 = St1#{trace := [tag(T, #{<<"h">> => H}, St1) || T <- maps:get(trace, St1)] ++ Old},
    Ranked = ranked(Rows, length(Columns), hypotheses(St2)),
    lists:foldl(
      fun({Rank, {Total, Vector, Values}}, {Acc, S}) ->
              Choices = [{A, chosen(J, Columns), V}
                         || {A, J, V} <- lists:zip3(R, Vector, Values)],
              S1 = lists:foldl(fun({A, B, V}, S0) ->
                                       record(tag(assign_trace(A, B, <<"choice">>, V, true),
                                                  #{<<"h">> => H, <<"r">> => Rank}, S0), S0)
                               end, S, Choices),
              Record = apply_assignment(Choices, Total, Newest),
              NewHistory = lists:droplast(History) ++ [Record],
              {Acc ++ [{total(NewHistory), H, Rank, NewHistory}], S1}
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
                                              record(history_trace(Rank, null, <<"commit">>,
                                                                   total(H), Keep), S)
                                      end, St0,
                                      lists:zip3(lists:seq(0, length(Histories) - 1),
                                                 Histories, Kept))
                  end,
            Events = maps:get(events, Committed),
            St2 = lists:foldl(fun correlator:emit/2, St1, Events),
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
            lists:foldl(fun(S, Acc) ->
                                emit(#{<<"ev">> => <<"provisional">>,
                                       <<"system">> => system_name(S),
                                       <<"members">> => maps:get(S, Latest)}, Acc)
                        end, St1, lists:sort(maps:keys(Latest)))
    end.

%% Event system: fused estimate of all members at Now, hae from the member with
%% the greatest last_time_ms whose last report has one (ties to key order).
system_event(S, Ms, Now, St) ->
    #{east := {PE, VE, _, _}, north := {PN, VN, _, _}} = fused(Ms, Now, none, St),
    {Lat, Lon} = correlator_filter:from_plane(maps:get(ref, St), PE, PN),
    Ev = #{<<"ev">> => <<"system">>, <<"system">> => system_name(S), <<"members">> => Ms,
           <<"lat">> => Lat, <<"lon">> => Lon, <<"course">> => correlator:course(VE, VN),
           <<"speed_ms">> => math:sqrt(VE * VE + VN * VN)},
    WithHae = [{maps:get(time, E), H} || M <- Ms, E <- [entity(M, St)],
                                         H <- [value(<<"hae">>, E)], is_number(H)],
    case WithHae of
        [] -> Ev;
        [First | Rest] ->
            {_, H} = lists:foldl(fun({T, X}, {TB, _}) when T > TB -> {T, X};
                                    (_, Best) -> Best
                                 end, First, Rest),
            Ev#{<<"hae">> => H}
    end.

%% ---------------------------------------------------------------- one source

%% Assignment of one source, steps 1 and 2: the columns [{S, Members, Others}]
%% in creation order, and per entity of R its row {[Cost | forbidden] per
%% column, AloneCost}. Writes the gate records as they run, then the cost
%% records.
entries(Src, R, Mem = #{systems := Systems}, St0) ->
    Pack = maps:get(pack, St0),
    Columns = [{S, Ms, Others}
               || {S, Ms} <- lists:sort(maps:to_list(Systems)),
                  Others <- [[M || M <- Ms, not lists:member(M, R)]],
                  Others =/= [],
                  not lists:any(fun(M) -> maps:get(source, entity(M, St0)) =:= Src end,
                                Others)],
    {Rows, St1} = lists:foldl(fun(A, {Acc, S}) ->
                                      {Row, S1} = row(A, Columns, Mem, Pack, S),
                                      {Acc ++ [Row], S1}
                              end, {[], St0}, R),
    St2 = lists:foldl(
            fun({A, {Costs, Alone}}, S) ->
                    Rec = fun(B, C, Acc) ->
                                  record(assign_trace(A, B, <<"cost">>, C, C =/= forbidden), Acc)
                          end,
                    S1 = lists:foldl(fun({{B, _, _}, C}, Acc) -> Rec(B, C, Acc) end, S,
                                     lists:zip(Columns, Costs)),
                    Rec(alone, Alone, S1)
            end, St1, lists:zip(R, Rows)),
    {{Columns, Rows}, St2}.

%% One entity's entries: d² against each column's others, minus keep_bonus when
%% A is a member of it; forbidden when a gate test fails. Alone: new_cost, minus
%% keep_bonus when A is now the only member of its system track.
row(A, Columns, Mem = #{systems := Systems}, Pack, St0) ->
    KeepBonus = maps:get(keep_bonus, Pack),
    {Costs, St1} =
        lists:foldl(
          fun({_S, Ms, Others}, {Acc, S0}) ->
                  {Pass, S1} = gate(maps:get(gate, Pack), A, Others, S0),
                  Cost = case Pass of
                             false -> forbidden;
                             true -> cost(A, Others, S1)
                                         - case lists:member(A, Ms) of
                                               true -> KeepBonus;
                                               false -> 0
                                           end
                         end,
                  {Acc ++ [Cost], S1}
          end, {[], St0}, Columns),
    Alone = maps:get(new_cost, Pack)
        - case system_of(A, Mem) of
              none -> 0;
              Own -> case maps:get(Own, Systems) of
                         [A] -> KeepBonus;
                         _ -> 0
                     end
          end,
    {{Costs, Alone}, St1}.

assign_trace(A, B, Test, Cost, Pass) ->
    #{<<"stage">> => <<"assign">>, <<"a">> => A,
      <<"b">> => case B of alone -> <<"alone">>; S -> system_name(S) end,
      <<"test">> => Test,
      <<"value">> => case Cost of forbidden -> null; _ -> Cost end,
      <<"limit">> => null, <<"pass">> => Pass}.

%% Gate tests between A and each other in key order; stop at the first failure.
gate(_Tests, _A, [], St) -> {true, St};
gate(Tests, A, [B | Bs], St0) ->
    case correlator:run_tests(Tests, <<"gate">>, A, B, St0) of
        {true, St1} -> gate(Tests, A, Bs, St1);
        {false, St1} -> {false, St1}
    end.

%% Cost: d² of A's filter against the fused estimate of Ms at A's time, each
%% member's prediction with its timing variance added, then moved into A's
%% frame (Sensor bias), before the fused estimate; pp_a is A's filter pp plus
%% A's timing variance (correlate.md "Track estimate", Measurement variance).
cost(A, Ms, St) ->
    EA = entity(A, St),
    Fused = fused(Ms, maps:get(time, EA), maps:get(source, EA), St),
    {VarAE, VarAN} = maps:get(timing, EA),
    Axis = fun(Ax, VarA) ->
                   {PA, _, PPA0, _, _} = maps:get(Ax, maps:get(filter, EA)),
                   PPA = PPA0 + VarA,
                   {P, _, PP, _} = maps:get(Ax, Fused),
                   (PA - P) * (PA - P) / (PPA + PP)
           end,
    Axis(east, VarAE) + Axis(north, VarAN).

%% Fused estimate of Ms at time T, per axis {P, V, PP, VV}; sums over members
%% in key order. With FrameSrc a source (a comparison, Cost), each member's
%% prediction first gets its timing variance and is then moved into that
%% source's frame (Sensor bias); with none (output) neither applies.
fused(Ms, T, FrameSrc, St) ->
    Preds = [case FrameSrc of
                 none -> Pred;
                 _ -> move(correlator:add_timing(Pred, E), FrameSrc, maps:get(source, E), St)
             end
             || M <- Ms, E <- [entity(M, St)], Pred <- [correlator:predict(E, T, St)]],
    Sum = fun(L) -> lists:foldl(fun(X, Acc) -> Acc + X end, 0, L) end,
    Axis = fun(Ax) ->
                   As = [maps:get(Ax, P) || P <- Preds],
                   PP = 1 / Sum([1 / X || {_, _, X, _, _} <- As]),
                   VV = 1 / Sum([1 / X || {_, _, _, _, X} <- As]),
                   {PP * Sum([P / X || {P, _, X, _, _} <- As]),
                    VV * Sum([V / X || {_, V, _, _, X} <- As]),
                    PP, VV}
           end,
    #{east => Axis(east), north => Axis(north)}.

%% Step 4 of the assignment applied to a copy of the newest record: entities
%% of R in key order, each with {Entity, Chosen, Entry}.
apply_assignment(Choices, Total, Record) ->
    #{cost := Cost, choices := Choices0, events := Events0, membership := Mem0} = Record,
    {Mem, Events} = lists:foldl(fun({A, B, _}, Acc) -> apply_choice(A, B, Acc) end,
                                {Mem0, []}, Choices),
    Record#{cost := Cost + Total,
            choices := Choices0 ++ [[A, case B of alone -> <<"alone">>; S -> system_name(S) end]
                                    || {A, B, _} <- Choices],
            events := Events0 ++ Events,
            membership := Mem}.

apply_choice(A, B, Acc = {Mem = #{systems := Systems}, _}) ->
    Own = system_of(A, Mem),
    Stay = case B of
               alone -> Own =/= none andalso maps:get(Own, Systems) =:= [A];
               S -> Own =:= S
           end,
    case Stay of
        true -> Acc;
        false ->
            Acc1 = case Own of
                       none -> Acc;
                       _ -> leave(A, Own, <<"assign">>, Acc)
                   end,
            case B of
                alone -> start(A, Acc1);
                S2 -> join(A, S2, Acc1)
            end
    end.

%% ---------------------------------------------------------------- sensor bias

%% A pair's state, or the state of a pair with none stored:
%% o = 0, w = 0, var = s², n = 0; with time_offset also tau = 0 and S1..S8 = 0.
bias_state(Pair, St) ->
    #{<<"sigma_m">> := Sigma} = maps:get(bias, maps:get(pack, St)),
    maps:get(Pair, maps:get(bias, St),
             #{oe => 0.0, we => 0.0, on => 0.0, wn => 0.0, var => Sigma * Sigma, n => 0,
               tau => 0.0, sums => {0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0}}).

time_offset(St) -> maps:is_key(time_offset, maps:get(pack, St)).

%% Moving B into A's frame: B's prediction Pred (source BSrc) as seen by
%% source ASrc. p + o from pair "BSrc|ASrc" when BSrc is first, p - o from
%% pair "ASrc|BSrc" when ASrc is first; pp + var either way. With
%% time_offset, o - v*tau takes the place of o, v B's predicted velocity on
%% that axis. Never moved without the pack line bias, or between two
%% entities of one source.
move(Pred, ASrc, BSrc, St) ->
    case maps:is_key(bias, maps:get(pack, St)) of
        false -> Pred;
        true when ASrc =:= BSrc -> Pred;
        true ->
            {Pair, Sign} = case BSrc < ASrc of
                               true -> {{BSrc, ASrc}, 1};
                               false -> {{ASrc, BSrc}, -1}
                           end,
            #{oe := OE, on := ON, var := Var, tau := Tau} = bias_state(Pair, St),
            TimeOffset = time_offset(St),
            Shift = fun({P, V, PP, PV, VV}, O0) ->
                            O = case TimeOffset of
                                    true -> O0 - V * Tau;
                                    false -> O0
                                end,
                            Moved = case Sign of
                                        1 -> P + O;
                                        -1 -> P - O
                                    end,
                            {Moved, V, PP + Var, PV, VV}
                    end,
            Pred#{east := Shift(maps:get(east, Pred), OE),
                  north := Shift(maps:get(north, Pred), ON)}
    end.

%% Window step 5, Sensor bias "Update": per committed system track in creation
%% order, its members that are not retiring in key order, each pair X < Y of
%% two different sources with at least one of them among the tick's rows.
bias_update(Now, Rows, St0) ->
    case maps:find(bias, maps:get(pack, St0)) of
        error -> St0;
        {ok, Params} ->
            #{systems := Systems} = maps:get(committed, St0),
            Retiring = maps:get(retiring, St0),
            Pairs = [{X, Y}
                     || S <- lists:sort(maps:keys(Systems)),
                        Ms <- [[M || M <- maps:get(S, Systems), not maps:is_key(M, Retiring)]],
                        X <- Ms, Y <- Ms, X < Y,
                        maps:get(source, entity(X, St0)) =/= maps:get(source, entity(Y, St0)),
                        lists:member(X, Rows) orelse lists:member(Y, Rows)],
            lists:foldl(fun({X, Y}, S) -> bias_pair(X, Y, Now, Params, S) end, St0, Pairs)
    end.

bias_pair(X, Y, Now, #{<<"sigma_m">> := Sigma, <<"floor_m">> := Floor, <<"gate">> := Gate}, St0) ->
    TimeOffset = time_offset(St0),
    %% 1. ES is the entity whose source is first in key order, ET the other;
    %% both predicted to now (not moved).
    [ES, ET] = lists:sort(fun(P, Q) -> maps:get(source, entity(P, St0))
                                           =< maps:get(source, entity(Q, St0)) end, [X, Y]),
    Pair = {maps:get(source, entity(ES, St0)), maps:get(source, entity(ET, St0))},
    PredS = correlator:predict(entity(ES, St0), Now, St0),
    PredT = correlator:predict(entity(ET, St0), Now, St0),
    %% Per axis y = p_ET - p_ES, r = pp_ES + pp_ET; with time_offset also
    %% v = (v_ES + v_ET) / 2.
    Axis = fun(Ax) ->
                   {PS, VS, PPS, _, _} = maps:get(Ax, PredS),
                   {PT, VT, PPT, _, _} = maps:get(Ax, PredT),
                   {PT - PS, PPS + PPT, (VS + VT) / 2}
           end,
    {YE, RE, VE} = Axis(east),
    {YN, RN, VN} = Axis(north),
    State0 = #{oe := OE, we := WE, on := ON, wn := WN, var := Var, n := N, tau := Tau} =
        bias_state(Pair, St0),
    %% 2. d² with the pair's state; with time_offset the expected offset on
    %% each axis is o - v*tau in place of o.
    {XE, XN} = case TimeOffset of
                   true -> {OE - VE * Tau, ON - VN * Tau};
                   false -> {OE, ON}
               end,
    D2 = (YE - XE) * (YE - XE) / (Var + RE) + (YN - XN) * (YN - XN) / (Var + RN),
    %% 3. Accepted when d² < gate: the state is updated and stored.
    Accepted = D2 < Gate,
    {State, St1} =
        case Accepted of
            false -> {State0, St0};
            true ->
                N1 = N + 1,
                Var1 = max(Sigma * Sigma / (N1 + 1), Floor * Floor),
                New = case TimeOffset of
                          false ->
                              WE1 = WE + 1 / RE,
                              WN1 = WN + 1 / RN,
                              State0#{oe := OE + ((1 / RE) / WE1) * (YE - OE), we := WE1,
                                      on := ON + ((1 / RN) / WN1) * (YN - ON), wn := WN1,
                                      var := Var1, n := N1};
                          true ->
                              Fit = time_offset_fit(maps:get(sums, State0), 1 / RE, 1 / RN,
                                                    VE, VN, YE, YN, Sigma, St0),
                              maps:merge(State0#{var := Var1, n := N1}, Fit)
                      end,
                {New, St0#{bias := (maps:get(bias, St0))#{Pair => New}}}
        end,
    %% 4. Trace, with the state after step 3.
    Rec = #{<<"stage">> => <<"bias">>, <<"a">> => X, <<"b">> => Y, <<"test">> => <<"offset">>,
            <<"value">> => D2, <<"limit">> => Gate, <<"pass">> => Accepted,
            <<"east">> => maps:get(oe, State), <<"north">> => maps:get(on, State),
            <<"var">> => maps:get(var, State), <<"pairs">> => maps:get(n, State)},
    record(case TimeOffset of
               true -> Rec#{<<"time_offset_ms">> => maps:get(tau, State) * 1000};
               false -> Rec
           end, St1).

%% Sensor bias, "Time offset", an accepted pair: add this pair's terms to the
%% sums S1..S8 (each += one addition of the whole right-hand side), then fit
%% y = o - v*tau by weighted least squares with priors po = 1/s² on o and
%% pt = 1/(t/1000)² on tau, in closed form. Returns the new oe, on, tau, sums
%% and the weight sums we = S1, wn = S2.
time_offset_fit({S1, S2, S3, S4, S5, S6, S7, S8}, We, Wn, Ve, Vn, Ye, Yn, Sigma, St) ->
    #{<<"sigma_ms">> := T} = maps:get(time_offset, maps:get(pack, St)),
    NS1 = S1 + We,
    NS2 = S2 + Wn,
    NS3 = S3 + We * Ve,
    NS4 = S4 + Wn * Vn,
    NS5 = S5 + (We * Ve * Ve + Wn * Vn * Vn),
    NS6 = S6 + We * Ye,
    NS7 = S7 + Wn * Yn,
    NS8 = S8 + (We * Ve * Ye + Wn * Vn * Yn),
    Po = 1 / (Sigma * Sigma),
    Pt = 1 / ((T / 1000) * (T / 1000)),
    A11 = Po + NS1,
    A22 = Po + NS2,
    A13 = -NS3,
    A23 = -NS4,
    A33 = Pt + NS5,
    B1 = NS6,
    B2 = NS7,
    B3 = -NS8,
    Tau = (B3 - A13 * B1 / A11 - A23 * B2 / A22) / (A33 - A13 * A13 / A11 - A23 * A23 / A22),
    #{oe => (B1 - A13 * Tau) / A11, on => (B2 - A23 * Tau) / A22, tau => Tau,
      we => NS1, wn => NS2, sums => {NS1, NS2, NS3, NS4, NS5, NS6, NS7, NS8}}.

%% ---------------------------------------------------------------- ranking

%% Ranking: the first K assignments of the rows, each {Total, ChoiceVector,
%% Entries}. A choice index is a column's position (0 first) or NCols for
%% alone. Every assignment is enumerated (exact, and small at vector sizes),
%% then ordered by total and, for equal totals, by choice vector.
ranked(Rows, NCols, K) ->
    All = [{assignment_total(Values), Vector, Values}
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
assignment_total(Values) ->
    lists:foldl(fun(X, Acc) -> Acc + X end, 0.0, lists:sort(Values)).

%% ---------------------------------------------------------------- snapshot

snapshot(St) ->
    #{ref := Ref, entities := Ents, reported := Reported, retiring := Retiring,
      committed := Committed = #{systems := Systems, next := Next}} = St,
    Base = #{<<"ref">> => case Ref of none -> null; {Lat, Lon} -> [Lat, Lon] end,
             <<"entities">> =>
                 maps:from_list(
                   [{K, (correlator:snapshot_entity(E))#{
                          <<"system">> => case system_of(K, Committed) of
                                              none -> null;
                                              S -> system_name(S)
                                          end}}
                    || {K, E} <- maps:to_list(Ents)]),
             <<"systems">> => systems_json(Systems),
             <<"next_system">> => Next,
             <<"reported">> => lists:sort([K || K <- maps:keys(Reported), maps:is_key(K, Ents)])},
    Pack = maps:get(pack, St),
    WithRestart = case maps:is_key(restart, Pack) of
                      false -> Base;
                      true -> Base#{<<"restarted">> =>
                                        lists:sort(maps:keys(maps:get(restarted, St)))}
                  end,
    WithBias = case maps:is_key(bias, Pack) of
                   false -> WithRestart;
                   true ->
                       TimeOffset = time_offset(St),
                       Pair = fun(#{oe := OE, we := WE, on := ON, wn := WN, var := Var, n := N,
                                    tau := Tau, sums := Sums}) ->
                                      P = #{<<"east">> => OE, <<"weight_east">> => WE,
                                            <<"north">> => ON, <<"weight_north">> => WN,
                                            <<"var">> => Var, <<"pairs">> => N},
                                      case TimeOffset of
                                          true -> P#{<<"time_offset_ms">> => Tau * 1000,
                                                     <<"sums">> => tuple_to_list(Sums)};
                                          false -> P
                                      end
                              end,
                       WithRestart#{<<"bias">> =>
                                        maps:from_list(
                                          [{<<S/binary, "|", T/binary>>, Pair(State)}
                                           || {{S, T}, State} <- maps:to_list(maps:get(bias, St))])}
               end,
    case window(St) > 1 of
        false -> WithBias;
        true ->
            WithBias#{<<"retiring">> => lists:sort(maps:keys(Retiring)),
                  <<"histories">> =>
                      [#{<<"total">> => total(H),
                         <<"records">> =>
                             [#{<<"cost">> => C, <<"choices">> => Ch, <<"events">> => Evs,
                                <<"systems">> => systems_json(Sys), <<"next_system">> => N}
                              || #{cost := C, choices := Ch, events := Evs,
                                   membership := #{systems := Sys, next := N}} <- H]}
                       || H <- maps:get(histories, St)]}
    end.

systems_json(Systems) ->
    maps:from_list([{system_name(S), Ms} || {S, Ms} <- maps:to_list(Systems)]).
