%% Method confirm (correlate.md 0.8 "Association", "Tick", "Snapshot" with
%% "Pack" for its own directives): gate and confirm tests, confirm_count,
%% hold and hold_failures, groups, staleness and the fused output by
%% priority or latest. Moved here from the correlator unchanged in logic;
%% correlate 1.0 replaces this pipeline.
-module(correlate_confirm).
-behaviour(correlate_methods).
-export([directives/0, defaults/0, directive/2, check/1, finish_pack/1,
         new/1, entity_fields/0, restarted/2, reported/2, move/4, tick/2, snapshot/1]).

-import(correlate, [entity/2, put_entity/3, value/2, predict/3, pair_view/3]).
-import(trace_log, [emit/2, record/2]).
-import(correlate_pack, [number/1, integer/1]).

%% ---------------------------------------------------------------- pack

directives() ->
    {[<<"confirm_count">>, <<"hold_failures">>],
     [<<"confirm">>, <<"hold">>, <<"priority">>],
     [<<"confirm_count">>, <<"hold_failures">>, <<"same_source">>, <<"output">>]}.

defaults() ->
    #{confirm => [], hold => [], priority => [], same_source => forbid, output => priority}.

directive([Stage, Test | Params], P = #{tests := Tests})
  when Stage =:= <<"confirm">>; Stage =:= <<"hold">> ->
    Key = binary_to_atom(Stage),
    P#{Key := [correlate_pack:test(Test, Params, Tests) | maps:get(Key, P)]};
directive([<<"confirm_count">>, N], P) -> P#{confirm_count => integer(N)};
directive([<<"hold_failures">>, N], P) -> P#{hold_failures => integer(N)};
directive([<<"same_source">>, <<"forbid">>], P) -> P#{same_source := forbid};
directive([<<"same_source">>, <<"allow">>], P) -> P#{same_source := allow};
directive([<<"output">>, <<"priority">>], P) -> P#{output := priority};
directive([<<"output">>, <<"latest">>], P) -> P#{output := latest};
directive([<<"priority">>, Source, N], P) ->
    P#{priority := [{Source, number(N)} | maps:get(priority, P)]};
directive(_, _) -> unknown.

check(_P) -> ok.

finish_pack(P) ->
    lists:foldl(fun(K, Acc) -> Acc#{K := lists:reverse(maps:get(K, Acc))} end, P,
                [confirm, hold, priority]).

%% ---------------------------------------------------------------- state

new(_Pack) -> #{groups => #{}, counts => #{}, next_group => 1}.

entity_fields() -> #{group => none, hold_failures => 0}.

%% Restart: key, group, pair counts and hold failure count are kept.
restarted(_Key, St) -> St.

reported(Key, St) ->
    case entity(Key, St) of
        #{group := none} -> associate(Key, St);
        #{group := G} -> hold(Key, G, St)
    end.

%% Tests compare in one frame.
move(Pred, _ASrc, _BSrc, _St) -> Pred.

snapshot(St) -> snapshot_correlate:confirm(St).

%% ---------------------------------------------------------------- association

pair(A, B) when A < B -> {A, B};
pair(A, B) -> {B, A}.

count(A, B, St) -> maps:get(pair(A, B), maps:get(counts, St), 0).
set_count(A, B, N, St = #{counts := C}) -> St#{counts := C#{pair(A, B) => N}}.

members(G, St) -> maps:get(G, maps:get(groups, St)).

%% Association, A in a group: hold.
hold(A, G, St0) ->
    Pack = maps:get(pack, St0),
    Others = [B || B <- members(G, St0), B =/= A],
    {Passed, St1} = hold_members(maps:get(hold, Pack), A, Others, St0),
    Ent = entity(A, St1),
    case Passed of
        true -> put_entity(A, Ent#{hold_failures := 0}, St1);
        false ->
            Fails = maps:get(hold_failures, Ent) + 1,
            St2 = put_entity(A, Ent#{hold_failures := Fails}, St1),
            case Fails >= maps:get(hold_failures, Pack) of
                true -> leave(A, G, <<"hold">>, St2);
                false -> St2
            end
    end.

%% Hold against each other member in key order; stops at the first pass.
hold_members(_Tests, _A, [], St) -> {false, St};
hold_members(Tests, A, [B | Bs], St0) ->
    case correlate_test_kinds:run_tests(Tests, <<"hold">>, A, B, St0) of
        {true, St1} -> {true, St1};
        {false, St1} -> hold_members(Tests, A, Bs, St1)
    end.

%% Leave a group (count reset); dissolve it when one member is left.
leave(A, G, Reason, St0) ->
    Ent = entity(A, St0),
    St1 = put_entity(A, Ent#{group := none, hold_failures := 0}, St0),
    St2 = emit(trace_correlate:leave(G, A, Reason), St1),
    case [M || M <- members(G, St2), M =/= A] of
        [Last] ->
            LastEnt = entity(Last, St2),
            St3 = put_entity(Last, LastEnt#{group := none, hold_failures := 0}, St2),
            St4 = St3#{groups := maps:remove(G, maps:get(groups, St3))},
            emit(trace_correlate:dissolve(G, Last), St4);
        Rest ->
            St2#{groups := (maps:get(groups, St2))#{G => Rest}}
    end.

%% Association, A not in a group: associate.
associate(A, St0) ->
    Pack = maps:get(pack, St0),
    CC = maps:get(confirm_count, Pack),
    St1 = lists:foldl(fun(B, S) -> candidate(A, B, Pack, S) end, St0, candidates(A, St0)),
    Ready = [B || B <- candidates(A, St1), count(A, B, St1) >= CC],
    {Ranked, St2} = rank(A, Ready, [], St1),
    case Ranked of
        [] -> St2;
        [First | Rest] ->
            {_, B} = lists:foldl(fun({D, K}, {DBest, _}) when D < DBest -> {D, K};
                                    (_, Best) -> Best
                                 end, First, Rest),
            set_count(A, B, 0, group_with(A, B, St2))
    end.

%% d² for each ready candidate, recorded as test "rank".
rank(_A, [], Acc, St) -> {lists:reverse(Acc), St};
rank(A, [B | Bs], Acc, St) ->
    {EA, _, PredB} = pair_view(A, B, St),
    D2 = correlate_gating:d2(maps:get(filter, EA), maps:get(r, EA), PredB),
    rank(A, Bs, [{D2, B} | Acc], record(trace_correlate:rank(A, B, D2), St)).

candidates(A, St) ->
    #{entities := Ents, pack := Pack} = St,
    Src = maps:get(source, maps:get(A, Ents)),
    Allow = maps:get(same_source, Pack) =:= allow,
    [B || B <- lists:sort(maps:keys(Ents)), B =/= A,
          Allow orelse not same_source(Src, B, St)].

same_source(Src, B, St) ->
    EB = entity(B, St),
    case maps:get(group, EB) of
        none -> maps:get(source, EB) =:= Src;
        G -> lists:any(fun(M) -> maps:get(source, entity(M, St)) =:= Src end, members(G, St))
    end.

%% Gate tests, then confirm tests if all passed; then the pair's count.
candidate(A, B, Pack, St0) ->
    {GatePass, St1} = correlate_test_kinds:run_tests(maps:get(gate, Pack), <<"gate">>, A, B, St0),
    {AllPass, St2} = case GatePass of
                         true -> correlate_test_kinds:run_tests(maps:get(confirm, Pack),
                                                                <<"confirm">>, A, B, St1);
                         false -> {false, St1}
                     end,
    N = case AllPass of
            true -> count(A, B, St2) + 1;
            false -> 0
        end,
    CC = maps:get(confirm_count, Pack),
    St3 = set_count(A, B, N, St2),
    record(trace_correlate:count(A, B, N, CC, N >= CC), St3).

group_with(A, B, St) ->
    EA = entity(A, St),
    case maps:get(group, entity(B, St)) of
        none ->
            G = maps:get(next_group, St),
            EB = entity(B, St),
            Ms = lists:sort([A, B]),
            St1 = put_entity(B, EB#{group := G}, put_entity(A, EA#{group := G}, St)),
            St2 = St1#{groups := (maps:get(groups, St1))#{G => Ms}, next_group := G + 1},
            emit(trace_correlate:correlate(G, Ms), St2);
        G ->
            Ms = lists:sort([A | members(G, St)]),
            St1 = put_entity(A, EA#{group := G}, St),
            St2 = St1#{groups := (maps:get(groups, St1))#{G => Ms}},
            emit(trace_correlate:join(G, A), St2)
    end.

%% ---------------------------------------------------------------- tick

tick(Now, St0) ->
    St1 = lists:foldl(fun(K, S) -> stale(K, Now, S) end, St0,
                      lists:sort(maps:keys(maps:get(entities, St0)))),
    St2 = lists:foldl(fun(G, S) -> fused(G, Now, S) end, St1,
                      lists:sort(maps:keys(maps:get(groups, St1)))),
    trace_log:finish(St2).

%% Tick step 1, staleness.
stale(K, Now, St0) ->
    Ent = entity(K, St0),
    case correlate:is_stale(Ent, Now, St0) of
        false -> St0;
        true ->
            St1 = case maps:get(group, Ent) of
                      none -> St0;
                      G -> leave(K, G, <<"stale">>, St0)
                  end,
            Counts = maps:filter(fun({X, Y}, _) -> X =/= K andalso Y =/= K end,
                                 maps:get(counts, St1)),
            St2 = St1#{entities := maps:remove(K, maps:get(entities, St1)), counts := Counts},
            emit(trace_correlate:drop(K), St2)
    end.

%% Tick step 2, fused output.
fused(G, Now, St) ->
    Pack = maps:get(pack, St),
    Ms = members(G, St),
    Primary = primary(maps:get(output, Pack), Ms, Pack, St),
    Ent = entity(Primary, St),
    #{east := {PE, VE, _, _, _}, north := {PN, VN, _, _, _}} = predict(Ent, Now, Pack),
    {Lat, Lon} = model_frame:from_plane(maps:get(ref, St), PE, PN),
    Ev0 = #{<<"ev">> => <<"fused">>, <<"group">> => trace_correlate:group_name(G),
            <<"primary">> => Primary, <<"members">> => Ms,
            <<"lat">> => Lat, <<"lon">> => Lon, <<"course">> => model_frame:course(VE, VN),
            <<"speed_ms">> => math:sqrt(VE * VE + VN * VN)},
    Ev = case value(<<"hae">>, Ent) of
             H when is_number(H) -> Ev0#{<<"hae">> => H};
             _ -> Ev0
         end,
    emit(Ev, St).

%% Primary member: Ms is in key order, so the first best wins ties.
primary(priority, Ms, Pack, St) ->
    Prio = maps:from_list(maps:get(priority, Pack)),
    Rank = fun(M) -> maps:get(maps:get(source, entity(M, St)), Prio, 100) end,
    best(Ms, fun(M) -> Rank(M) end);
primary(latest, Ms, _Pack, St) ->
    best(Ms, fun(M) -> -maps:get(time, entity(M, St)) end).

best([M | Ms], Score) ->
    {_, Best} = lists:foldl(fun(X, {S, B}) ->
                                    SX = Score(X),
                                    if SX < S -> {SX, X}; true -> {S, B} end
                            end, {Score(M), M}, Ms),
    Best.
