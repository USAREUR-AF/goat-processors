%% Method confirm (correlate.md 1.0 "Association", "Tick", "Snapshot" with
%% "Pack" for its own directives): gate and confirm tests, then either
%% confirm_count with hold and hold_failures, or the sequential test of the
%% sprt line (correlate_sprt); groups, staleness and the fused output by the
%% output modes of outputs/0 (fused, priority, latest).
-module(correlate_confirm).
-behaviour(correlate_methods).
-export([directives/0, defaults/0, directive/2, check/1, finish_pack/1,
         new/1, entity_fields/0, restarted/2, reported/2, move/4, tick/2, snapshot/1]).
%% Shared with correlate_sprt.
-export([pair/2, members/2, leave/4, candidates/2, choose/3]).
%% The output modes.
-export([outputs/0, fused_output/3, priority_output/3, latest_output/3]).

-define(SPRT_PARAMS, [<<"false">>, <<"missed">>, <<"pos_m">>, <<"vel_ms">>, <<"hae_sigma_m">>]).

-import(correlate, [entity/2, put_entity/3, value/2, predict/3, pair_view/3]).
-import(trace_log, [emit/2, record/2]).
-import(correlate_pack, [number/1, integer/1, params/2, number_params/1]).
-import(io_pack, [fail/1]).

%% ---------------------------------------------------------------- pack

%% confirm_count and hold_failures are required without sprt and refused
%% with it (check/1).
directives() ->
    {[],
     [<<"confirm">>, <<"hold">>, <<"priority">>],
     [<<"confirm_count">>, <<"hold_failures">>, <<"same_source">>, <<"output">>, <<"sprt">>]}.

defaults() ->
    #{confirm => [], hold => [], priority => [], same_source => forbid, output => <<"fused">>}.

%% The output modes (Association, "On each tick" step 2): name => function of
%% (Group, Now, St) giving the fused event's primary (null for fused) and
%% its estimate {PE, VE, PN, VN, Hae}. A mode is one entry here.
outputs() ->
    #{<<"fused">> => fun ?MODULE:fused_output/3,
      <<"priority">> => fun ?MODULE:priority_output/3,
      <<"latest">> => fun ?MODULE:latest_output/3}.

directive([Stage, Test | Params], P = #{tests := Tests})
  when Stage =:= <<"confirm">>; Stage =:= <<"hold">> ->
    Key = binary_to_atom(Stage),
    P#{Key := [correlate_pack:test(Test, Params, Tests) | maps:get(Key, P)]};
directive([<<"confirm_count">>, N], P) -> P#{confirm_count => integer(N)};
directive([<<"hold_failures">>, N], P) -> P#{hold_failures => integer(N)};
directive([<<"same_source">>, <<"forbid">>], P) -> P#{same_source := forbid};
directive([<<"same_source">>, <<"allow">>], P) -> P#{same_source := allow};
directive([<<"output">>, Mode], P) ->
    case maps:is_key(Mode, outputs()) of
        true -> P#{output := Mode};
        false -> unknown
    end;
directive([<<"sprt">> | Params], P) ->
    P#{sprt => number_params(params(Params, ?SPRT_PARAMS))};
directive([<<"priority">>, Source, N], P) ->
    P#{priority := [{Source, number(N)} | maps:get(priority, P)]};
directive(_, _) -> unknown.

%% Without sprt, confirm_count and hold_failures are required; with sprt,
%% confirm_count, hold_failures and hold are refused, false and missed are
%% above 0 and below 0.5, pos_m, vel_ms and hae_sigma_m above 0.
check(P = #{sprt := S}) ->
    [fail({refused_with_sprt, K}) || K <- [confirm_count, hold_failures], maps:is_key(K, P)],
    maps:get(hold, P) =:= [] orelse fail({refused_with_sprt, hold}),
    [fail({sprt_range, K}) || K <- [<<"false">>, <<"missed">>],
                              not (maps:get(K, S) > 0 andalso maps:get(K, S) < 0.5)],
    [fail({not_above_zero, K}) || K <- [<<"pos_m">>, <<"vel_ms">>, <<"hae_sigma_m">>],
                                  not (maps:get(K, S) > 0)],
    ok;
check(P) ->
    [fail({missing, K}) || K <- [confirm_count, hold_failures], not maps:is_key(K, P)],
    ok.

finish_pack(P0) ->
    P = lists:foldl(fun(K, Acc) -> Acc#{K := lists:reverse(maps:get(K, Acc))} end, P0,
                    [confirm, hold, priority]),
    case P of
        #{sprt := S} -> P#{sprt := correlate_sprt:bounds(S)};
        _ -> P
    end.

%% ---------------------------------------------------------------- state

new(_Pack) -> #{groups => #{}, counts => #{}, llr => #{}, next_group => 1}.

entity_fields() -> #{group => none, hold_failures => 0}.

%% Restart: key, group, pair counts and hold failure count are kept.
restarted(_Key, St) -> St.

reported(Key, St = #{pack := #{sprt := _}}) -> correlate_sprt:reported(Key, St);
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
    case choose(A, Ready, St1) of
        {none, St2} -> St2;
        {B, St2} -> set_count(A, B, 0, St2)
    end.

%% Of the ready candidates (key order), the one with the smallest d², ties
%% to key order, with one rank record each; A joins its group or correlates
%% with it. {Chosen | none, St}.
choose(A, Ready, St0) ->
    {Ranked, St1} = rank(A, Ready, [], St0),
    case Ranked of
        [] -> {none, St1};
        [First | Rest] ->
            {_, B} = lists:foldl(fun({D, K}, {DBest, _}) when D < DBest -> {D, K};
                                    (_, Best) -> Best
                                 end, First, Rest),
            {B, group_with(A, B, St1)}
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
            Keep = fun({X, Y}, _) -> X =/= K andalso Y =/= K end,
            St2 = St1#{entities := maps:remove(K, maps:get(entities, St1)),
                       counts := maps:filter(Keep, maps:get(counts, St1)),
                       llr := maps:filter(Keep, maps:get(llr, St1))},
            emit(trace_correlate:drop(K), St2)
    end.

%% Tick step 2, fused output: the pack's output mode gives the primary and
%% the estimate at Now.
fused(G, Now, St) ->
    Pack = maps:get(pack, St),
    Ms = members(G, St),
    Output = maps:get(maps:get(output, Pack), outputs()),
    {Primary, {PE, VE, PN, VN, Hae}} = Output(Ms, Now, St),
    {Lat, Lon} = model_frame:from_plane(maps:get(ref, St), PE, PN),
    Ev0 = #{<<"ev">> => <<"fused">>, <<"group">> => trace_correlate:group_name(G),
            <<"primary">> => Primary, <<"members">> => Ms,
            <<"lat">> => Lat, <<"lon">> => Lon, <<"course">> => model_frame:course(VE, VN),
            <<"speed_ms">> => math:sqrt(VE * VE + VN * VN)},
    Ev = case Hae of
             H when is_number(H) -> Ev0#{<<"hae">> => H};
             _ -> Ev0
         end,
    emit(Ev, St).

%% output fused: per axis the information-weighted combination of every
%% member's filter predicted to Now (no timing variance), members in key
%% order, each sum left to right from 0; hae of the member with the greatest
%% last_time_ms whose last report has hae, ties to key order.
fused_output(Ms, Now, St) ->
    Pack = maps:get(pack, St),
    Preds = [predict(entity(M, St), Now, Pack) || M <- Ms],
    {PE, VE} = combine([E || #{east := E} <- Preds]),
    {PN, VN} = combine([N || #{north := N} <- Preds]),
    WithHae = [M || M <- Ms, is_number(value(<<"hae">>, entity(M, St)))],
    Hae = case WithHae of
              [] -> null;
              _ -> value(<<"hae">>, entity(best(WithHae, fun(M) -> -maps:get(time, entity(M, St)) end), St))
          end,
    {null, {PE, VE, PN, VN, Hae}}.

combine(Axes) ->
    {SP, SIP, SV, SIV} = lists:foldl(fun({P, V, PP, _, VV}, {A, B, C, D}) ->
                                             {A + P / PP, B + 1 / PP, C + V / VV, D + 1 / VV}
                                     end, {0.0, 0.0, 0.0, 0.0}, Axes),
    {SP / SIP, SV / SIV}.

%% output priority: the lowest priority number for the member's source (100
%% for a source the pack does not list), ties to key order.
priority_output(Ms, Now, St) ->
    Prio = maps:from_list(maps:get(priority, maps:get(pack, St))),
    primary_output(best(Ms, fun(M) -> maps:get(maps:get(source, entity(M, St)), Prio, 100) end),
                   Now, St).

%% output latest: the greatest last_time_ms, ties to key order.
latest_output(Ms, Now, St) ->
    primary_output(best(Ms, fun(M) -> -maps:get(time, entity(M, St)) end), Now, St).

%% The primary's filter predicted to Now and its last hae.
primary_output(Primary, Now, St) ->
    Ent = entity(Primary, St),
    #{east := {PE, VE, _, _, _}, north := {PN, VN, _, _, _}} = predict(Ent, Now, maps:get(pack, St)),
    {Primary, {PE, VE, PN, VN, value(<<"hae">>, Ent)}}.

%% The first of Ms (key order) with the lowest score.
best([M | Ms], Score) ->
    {_, Best} = lists:foldl(fun(X, {S, B}) ->
                                    SX = Score(X),
                                    if SX < S -> {SX, X}; true -> {S, B} end
                            end, {Score(M), M}, Ms),
    Best.
