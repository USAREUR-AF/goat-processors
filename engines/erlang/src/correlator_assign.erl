%% Method assign (spec/correlate-assign.md): system tracks, per-source exact
%% least-cost assignment at each tick, inverse-variance fused estimate.
%% Reports, frame, track estimate and tests are shared with correlator.
%% Explicit recursion stands in for lists:mapfoldl (see correlator.erl).
-module(correlator_assign).
-export([tick/2, snapshot/1, solve/2]).

-import(correlator, [emit/2, record/2, entity/2, put_entity/3, value/2]).

system_name(S) -> <<"s", (integer_to_binary(S))/binary>>.
members(S, St) -> maps:get(S, maps:get(systems, St)).
put_members(S, Ms, St = #{systems := Sys}) -> St#{systems := Sys#{S => Ms}}.

%% ---------------------------------------------------------------- tick

%% Staleness, then per source the assignment, then one system per track.
tick(Now, St0) ->
    St1 = lists:foldl(fun(K, S) -> stale(K, Now, S) end, St0,
                      lists:sort(maps:keys(maps:get(entities, St0)))),
    Ents = maps:get(entities, St1),
    Reported = lists:sort([K || K <- maps:keys(maps:get(reported, St1)),
                                maps:is_key(K, Ents)]),
    Sources = lists:usort([maps:get(source, maps:get(K, Ents)) || K <- Reported]),
    St2 = lists:foldl(
            fun(Src, S) ->
                    R = [K || K <- Reported, maps:get(source, maps:get(K, Ents)) =:= Src],
                    assign_source(Src, R, S)
            end, St1, Sources),
    St3 = St2#{reported := #{}},
    St4 = lists:foldl(fun(S, Acc) -> output(S, Now, Acc) end, St3,
                      lists:sort(maps:keys(maps:get(systems, St3)))),
    correlator:finish(St4).

%% Staleness: leave (reason stale), end when empty, drop.
stale(K, Now, St0) ->
    Ent = entity(K, St0),
    case correlator:is_stale(Ent, Now, St0) of
        false -> St0;
        true ->
            St1 = case maps:get(system, Ent) of
                      none -> St0;
                      S -> leave(K, S, <<"stale">>, St0)
                  end,
            St2 = St1#{entities := maps:remove(K, maps:get(entities, St1))},
            emit(#{<<"ev">> => <<"drop">>, <<"entity">> => K}, St2)
    end.

%% Leave a system track; a system track left empty ends.
leave(A, S, Reason, St0) ->
    St1 = put_entity(A, (entity(A, St0))#{system := none}, St0),
    St2 = emit(#{<<"ev">> => <<"leave">>, <<"system">> => system_name(S),
                 <<"entity">> => A, <<"reason">> => Reason}, St1),
    case [M || M <- members(S, St2), M =/= A] of
        [] ->
            St3 = St2#{systems := maps:remove(S, maps:get(systems, St2))},
            emit(#{<<"ev">> => <<"end">>, <<"system">> => system_name(S)}, St3);
        Rest -> put_members(S, Rest, St2)
    end.

join(A, S, St0) ->
    St1 = put_entity(A, (entity(A, St0))#{system := S}, St0),
    St2 = put_members(S, lists:sort([A | members(S, St1)]), St1),
    emit(#{<<"ev">> => <<"join">>, <<"system">> => system_name(S), <<"entity">> => A}, St2).

start(A, St0 = #{next_system := S}) ->
    St1 = put_entity(A, (entity(A, St0))#{system := S}, St0),
    St2 = put_members(S, [A], St1#{next_system := S + 1}),
    emit(#{<<"ev">> => <<"start">>, <<"system">> => system_name(S), <<"entity">> => A}, St2).

%% ---------------------------------------------------------------- one source

%% Columns, entries, assignment, apply, for source Src and its reported R.
assign_source(Src, R, St0) ->
    Pack = maps:get(pack, St0),
    Columns = [{S, Ms, Others}
               || {S, Ms} <- lists:sort(maps:to_list(maps:get(systems, St0))),
                  Others <- [[M || M <- Ms, not lists:member(M, R)]],
                  Others =/= [],
                  not lists:any(fun(M) -> maps:get(source, entity(M, St0)) =:= Src end,
                                Others)],
    {Rows, St1} = entries(R, Columns, Pack, [], St0),
    St2 = lists:foldl(
            fun({A, Row}, S) ->
                    lists:foldl(fun({B, Cost}, S1) ->
                                        record(trace(A, B, <<"cost">>, Cost, Cost =/= forbidden), S1)
                                end, S, Row)
            end, St1, lists:zip(R, Rows)),
    Choices = solve_rows(Rows, length(Columns)),
    St3 = lists:foldl(
            fun({A, {B, Cost}}, S) -> record(trace(A, B, <<"choice">>, Cost, true), S) end,
            St2, lists:zip(R, Choices)),
    lists:foldl(fun({A, {B, _}}, S) -> apply_choice(A, B, S) end, St3,
                lists:zip(R, Choices)).

trace(A, B, Test, Cost, Pass) ->
    #{<<"stage">> => <<"assign">>, <<"a">> => A,
      <<"b">> => case B of alone -> <<"alone">>; S -> system_name(S) end,
      <<"test">> => Test,
      <<"value">> => case Cost of forbidden -> null; _ -> Cost end,
      <<"limit">> => null, <<"pass">> => Pass}.

%% Per entity of R: [{System, Cost | forbidden}] in column order, then
%% {alone, Cost}. Gate records are written as the entries are computed.
entries([], _Columns, _Pack, Acc, St) -> {lists:reverse(Acc), St};
entries([A | As], Columns, Pack, Acc, St0) ->
    {Row, St1} = row(A, Columns, Pack, [], St0),
    Own = maps:get(system, entity(A, St1)),
    Alone = maps:get(new_cost, Pack)
        - case Own =/= none andalso members(Own, St1) =:= [A] of
              true -> maps:get(keep_bonus, Pack);
              false -> 0
          end,
    entries(As, Columns, Pack, [Row ++ [{alone, Alone}] | Acc], St1).

row(_A, [], _Pack, Acc, St) -> {lists:reverse(Acc), St};
row(A, [{S, Ms, Others} | Cs], Pack, Acc, St0) ->
    {Pass, St1} = gate(maps:get(gate, Pack), A, Others, St0),
    Cost = case Pass of
               false -> forbidden;
               true ->
                   cost(A, Others, St1)
                       - case lists:member(A, Ms) of
                             true -> maps:get(keep_bonus, Pack);
                             false -> 0
                         end
           end,
    row(A, Cs, Pack, [{S, Cost} | Acc], St1).

%% Gate tests between A and each other in key order; stop at the first failure.
gate(_Tests, _A, [], St) -> {true, St};
gate(Tests, A, [B | Bs], St0) ->
    case correlator:run_tests(Tests, <<"gate">>, A, B, St0) of
        {true, St1} -> gate(Tests, A, Bs, St1);
        {false, St1} -> {false, St1}
    end.

%% Cost: d² of A's filter against the fused estimate of Ms at A's time.
cost(A, Ms, St) ->
    EA = entity(A, St),
    Fused = fused(Ms, maps:get(time, EA), St),
    Axis = fun(Ax) ->
                   {PA, _, PPA, _, _} = maps:get(Ax, maps:get(filter, EA)),
                   {P, _, PP, _} = maps:get(Ax, Fused),
                   (PA - P) * (PA - P) / (PPA + PP)
           end,
    Axis(east) + Axis(north).

%% Fused estimate of Ms at time T, per axis {P, V, PP, VV}.
fused(Ms, T, St) ->
    F = maps:get(filter, maps:get(pack, St)),
    Preds = [correlator_filter:predict(maps:get(filter, E), (T - maps:get(time, E)) / 1000, F)
             || M <- Ms, E <- [entity(M, St)]],
    Axis = fun(Ax) ->
                   As = [maps:get(Ax, P) || P <- Preds],
                   PP = 1 / lists:sum([1 / X || {_, _, X, _, _} <- As]),
                   VV = 1 / lists:sum([1 / X || {_, _, _, _, X} <- As]),
                   {PP * lists:sum([P / X || {P, _, X, _, _} <- As]),
                    VV * lists:sum([V / X || {_, V, _, _, X} <- As]),
                    PP, VV}
           end,
    #{east => Axis(east), north => Axis(north)}.

%% Apply one entity's choice.
apply_choice(A, B, St0) ->
    Own = maps:get(system, entity(A, St0)),
    Stay = case B of
               alone -> Own =/= none andalso members(Own, St0) =:= [A];
               S -> Own =:= S
           end,
    case Stay of
        true -> St0;
        false ->
            St1 = case Own of
                      none -> St0;
                      _ -> leave(A, Own, <<"assign">>, St0)
                  end,
            case B of
                alone -> start(A, St1);
                S2 -> join(A, S2, St1)
            end
    end.

%% ---------------------------------------------------------------- assignment

%% Rows: each [{System, Cost | forbidden}] * NCols, then {alone, Cost}.
%% Columns of the solver: the NCols system columns, then one alone column per
%% row (only its own row may take it). Returns per row {Choice, Cost}.
solve_rows(Rows, NCols) ->
    N = length(Rows),
    Matrix = maps:from_list(
               [{{I, J}, C}
                || {I, Row} <- lists:zip(lists:seq(1, N), Rows),
                   {J, {_, C}} <- lists:zip(lists:seq(1, NCols), lists:sublist(Row, NCols)),
                   C =/= forbidden]
               ++ [{{I, NCols + I}, element(2, lists:last(Row))}
                   || {I, Row} <- lists:zip(lists:seq(1, N), Rows)]),
    Assigned = solve(Matrix, {N, NCols + N}),
    [begin
         J = maps:get(I, Assigned),
         case J > NCols of
             true -> lists:last(Row);
             false -> lists:nth(J, Row)
         end
     end || {I, Row} <- lists:zip(lists:seq(1, N), Rows)].

%% Exact minimum-cost assignment of N rows to M >= N columns, Hungarian method
%% with potentials. Matrix maps {Row, Col} (1-based) to a cost; a missing entry
%% is forbidden. Every row must have a feasible assignment. Returns Row => Col.
solve(Matrix, {N, M}) ->
    Cols = lists:seq(0, M),
    P0 = maps:from_list([{J, 0} || J <- Cols]),
    V0 = maps:from_list([{J, 0.0} || J <- Cols]),
    U0 = maps:from_list([{I, 0.0} || I <- lists:seq(0, N)]),
    {_, _, P} = lists:foldl(fun(I, {U, V, P}) -> add_row(I, Matrix, M, U, V, P) end,
                            {U0, V0, P0}, lists:seq(1, N)),
    maps:from_list([{I, J} || {J, I} <- maps:to_list(P), J > 0, I > 0]).

add_row(I, Matrix, M, U, V, P0) ->
    Cols = lists:seq(1, M),
    MinV = maps:from_list([{J, inf} || J <- Cols]),
    Way = maps:from_list([{J, 0} || J <- Cols]),
    {U1, V1, P1, Way1, J0} = search(0, Matrix, Cols, U, V, P0#{0 := I}, MinV, Way, #{0 => true}),
    {U1, V1, augment(J0, P1, Way1)}.

%% Grow the alternating tree from column J0 until a free column is reached.
search(J0, Matrix, Cols, U, V, P, MinV0, Way0, Used) ->
    I0 = maps:get(J0, P),
    UI0 = maps:get(I0, U),
    {MinV1, Way1, Delta, J1} =
        lists:foldl(
          fun(J, {Mv, Wy, D, Jb} = Acc) ->
                  case maps:is_key(J, Used) of
                      true -> Acc;
                      false ->
                          {Mv1, Wy1} =
                              case maps:find({I0, J}, Matrix) of
                                  {ok, C} ->
                                      Cur = C - UI0 - maps:get(J, V),
                                      case Cur < maps:get(J, Mv) of
                                          true -> {Mv#{J := Cur}, Wy#{J := J0}};
                                          false -> {Mv, Wy}
                                      end;
                                  error -> {Mv, Wy}
                              end,
                          MJ = maps:get(J, Mv1),
                          case MJ < D of
                              true -> {Mv1, Wy1, MJ, J};
                              false -> {Mv1, Wy1, D, Jb}
                          end
                  end
          end, {MinV0, Way0, inf, none}, Cols),
    %% A free column is always reachable (each row's own alone column), so
    %% Delta is finite.
    {U2, V2, MinV2} =
        lists:foldl(
          fun(J, {Ua, Va, Mv}) ->
                  case maps:is_key(J, Used) of
                      true ->
                          Row = maps:get(J, P),
                          {Ua#{Row := maps:get(Row, Ua) + Delta},
                           Va#{J := maps:get(J, Va) - Delta}, Mv};
                      false ->
                          case maps:get(J, Mv) of
                              inf -> {Ua, Va, Mv};
                              X -> {Ua, Va, Mv#{J := X - Delta}}
                          end
                  end
          end, {U, V, MinV1}, [0 | Cols]),
    case maps:get(J1, P) of
        0 -> {U2, V2, P, Way1, J1};
        _ -> search(J1, Matrix, Cols, U2, V2, P, MinV2, Way1, Used#{J1 => true})
    end.

augment(0, P, _Way) -> P;
augment(J0, P, Way) ->
    J1 = maps:get(J0, Way),
    augment(J1, P#{J0 := maps:get(J1, P)}, Way).

%% ---------------------------------------------------------------- output

%% Event system: fused estimate of all members at Now, hae from the latest
%% member whose last report has one (ties to key order).
output(S, Now, St) ->
    Ms = members(S, St),
    #{east := {PE, VE, _, _}, north := {PN, VN, _, _}} = fused(Ms, Now, St),
    {Lat, Lon} = correlator_filter:from_plane(maps:get(ref, St), PE, PN),
    C0 = math:atan2(VE, VN) * 180 / math:pi(),
    Course = if C0 < 0 -> C0 + 360; C0 >= 360 -> C0 - 360; true -> C0 end,
    Ev0 = #{<<"ev">> => <<"system">>, <<"system">> => system_name(S), <<"members">> => Ms,
            <<"lat">> => Lat, <<"lon">> => Lon, <<"course">> => Course,
            <<"speed_ms">> => math:sqrt(VE * VE + VN * VN)},
    WithHae = [{maps:get(time, E), H} || M <- Ms, E <- [entity(M, St)],
                                         H <- [value(<<"hae">>, E)], is_number(H)],
    Ev = case WithHae of
             [] -> Ev0;
             [First | Rest] ->
                 {_, H} = lists:foldl(fun({T, X}, {TB, _}) when T > TB -> {T, X};
                                         (_, Best) -> Best
                                      end, First, Rest),
                 Ev0#{<<"hae">> => H}
         end,
    emit(Ev, St).

%% ---------------------------------------------------------------- snapshot

snapshot(St) ->
    #{ref := Ref, entities := Ents, systems := Systems, next_system := Next,
      reported := Reported} = St,
    Axis = fun({P, V, PP, PV, VV}) -> [P, V, PP, PV, VV] end,
    #{<<"ref">> => case Ref of none -> null; {Lat, Lon} -> [Lat, Lon] end,
      <<"entities">> =>
          maps:from_list(
            [{K, #{<<"last_time_ms">> => maps:get(time, E),
                   <<"system">> => case maps:get(system, E) of
                                       none -> null;
                                       S -> system_name(S)
                                   end,
                   <<"filter">> => #{<<"east">> => Axis(maps:get(east, maps:get(filter, E))),
                                     <<"north">> => Axis(maps:get(north, maps:get(filter, E)))}}}
             || {K, E} <- maps:to_list(Ents)]),
      <<"systems">> => maps:from_list([{system_name(S), Ms} || {S, Ms} <- maps:to_list(Systems)]),
      <<"next_system">> => Next,
      <<"reported">> => lists:sort([K || K <- maps:keys(Reported), maps:is_key(K, Ents)])}.
