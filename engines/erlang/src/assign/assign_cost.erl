%% Assignment of one source (correlate-assign.md "Assignment of one source"),
%% steps 1 and 2: the columns and the entries, with their gate and cost
%% records; the fused estimate of a system track's members.
-module(assign_cost).
-export([entries/4, fused/4]).

-import(correlate, [entity/2]).

%% The columns [{S, Members, Others}] in creation order, and per entity of R
%% its row {[Cost | forbidden] per column, AloneCost}. Writes the gate
%% records as they run, then the cost records.
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
                                  trace_log:record(trace_assign:assign(A, B, <<"cost">>, C,
                                                                       C =/= forbidden), Acc)
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
        - case assign_membership:system_of(A, Mem) of
              none -> 0;
              Own -> case maps:get(Own, Systems) of
                         [A] -> KeepBonus;
                         _ -> 0
                     end
          end,
    {{Costs, Alone}, St1}.

%% Gate tests between A and each other in key order; stop at the first failure.
gate(_Tests, _A, [], St) -> {true, St};
gate(Tests, A, [B | Bs], St0) ->
    case correlate_test_kinds:run_tests(Tests, <<"gate">>, A, B, St0) of
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
                 _ -> assign_bias:move(correlate:add_timing(Pred, E), FrameSrc,
                                       maps:get(source, E), St)
             end
             || M <- Ms, E <- [entity(M, St)], Pred <- [correlate:predict(E, T, St)]],
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
