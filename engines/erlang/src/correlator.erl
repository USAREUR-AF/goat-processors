%% The correlator engine: load_pack, ingest, tick, snapshot (spec sections
%% "Reports", "Tests", "Association", "Events", "Trace", "Snapshot").
%% State is a value; ingest and tick return {Events, Trace, NewState}.
%% Explicit recursion stands in for lists:mapfoldl, which OTP 27.3 miscompiles
%% when a case on its result follows.
-module(correlator).
-export([load_pack/1, new/1, ingest/2, tick/2, snapshot/1]).

-define(REQUIRED, [<<"track.source_id">>, <<"uid">>, <<"time_ms">>, <<"lat">>, <<"lon">>]).

load_pack(Dir) -> correlator_pack:load_pack(Dir).

new(Pack) ->
    #{pack => Pack, ref => none, entities => #{}, groups => #{}, counts => #{},
      next_group => 1, events => [], trace => []}.

%% ---------------------------------------------------------------- output

emit(Ev, St = #{events := Es}) -> St#{events := [Ev | Es]}.
record(Rec, St = #{trace := Ts}) -> St#{trace := [Rec | Ts]}.

finish(St = #{events := Es, trace := Ts}) ->
    {lists:reverse(Es), lists:reverse(Ts), St#{events := [], trace := []}}.

%% ---------------------------------------------------------------- reports

%% Reports: reject missing keys in table order, then out-of-order.
ingest(Report, St) ->
    case [K || K <- ?REQUIRED, maps:get(K, Report, null) =:= null] of
        [Missing | _] ->
            finish(emit(#{<<"ev">> => <<"reject">>,
                          <<"reason">> => <<"missing:", Missing/binary>>}, St));
        [] ->
            Key = entity_key(Report),
            T = maps:get(<<"time_ms">>, Report),
            case maps:find(Key, maps:get(entities, St)) of
                {ok, #{time := Last}} when T < Last ->
                    finish(emit(#{<<"ev">> => <<"reject">>, <<"entity">> => Key,
                                  <<"reason">> => <<"out-of-order">>}, St));
                _ ->
                    finish(accept(Key, Report, St))
            end
    end.

entity_key(R) ->
    <<(maps:get(<<"track.source_id">>, R))/binary, "/", (maps:get(<<"uid">>, R))/binary>>.

accept(Key, Report, St0) ->
    #{pack := Pack} = St0,
    F = maps:get(filter, Pack),
    Lat = maps:get(<<"lat">>, Report),
    Lon = maps:get(<<"lon">>, Report),
    T = maps:get(<<"time_ms">>, Report),
    %% Frame: the first accepted report sets the reference.
    St1 = case maps:get(ref, St0) of
              none -> St0#{ref := {Lat, Lon}};
              _ -> St0
          end,
    Z = correlator_filter:to_plane(maps:get(ref, St1), Lat, Lon),
    Ce = report_ce(Report, F),
    Vel = correlator_filter:velocity(maps:get(<<"course">>, Report, null),
                                     maps:get(<<"speed_ms">>, Report, null)),
    Ents = maps:get(entities, St1),
    {Ent, St2} =
        case maps:find(Key, Ents) of
            error ->
                E0 = #{source => maps:get(<<"track.source_id">>, Report),
                       group => none, hold_failures => 0,
                       filter => correlator_filter:init(Z, Vel, Ce, F)},
                {E0, emit(#{<<"ev">> => <<"new">>, <<"entity">> => Key}, St1)};
            {ok, E0 = #{time := Last, filter := Filter}} ->
                Dt = (T - Last) / 1000,
                {E0#{filter := correlator_filter:update(Filter, Dt, Z, Vel, Ce, F)}, St1}
        end,
    Ent1 = Ent#{time => T, report => Report, ce => Ce},
    St3 = put_entity(Key, Ent1, St2),
    case Ent1 of
        #{group := none} -> associate(Key, St3);
        #{group := G} -> hold(Key, G, St3)
    end.

report_ce(Report, F) ->
    case maps:get(<<"ce">>, Report, null) of
        null -> maps:get(<<"default_ce_m">>, F);
        Ce -> Ce
    end.

entity(Key, St) -> maps:get(Key, maps:get(entities, St)).
put_entity(Key, E, St = #{entities := Es}) -> St#{entities := Es#{Key => E}}.

%% Last-report value of a key, null when absent; "@env" from type.
value(<<"@env">>, Ent) ->
    case maps:get(<<"type">>, maps:get(report, Ent), null) of
        Type when is_binary(Type) ->
            case binary:split(Type, <<"-">>, [global]) of
                [_, _, Env | _] -> Env;
                _ -> null
            end;
        _ -> null
    end;
value(K, Ent) -> maps:get(K, maps:get(report, Ent), null).

%% ---------------------------------------------------------------- tests

%% Tests: A is the entity just reported, B predicted to A's time_ms.
pair_view(A, B, St) ->
    EA = entity(A, St),
    EB = entity(B, St),
    F = maps:get(filter, maps:get(pack, St)),
    Dt = (maps:get(time, EA) - maps:get(time, EB)) / 1000,
    {EA, EB, correlator_filter:predict(maps:get(filter, EB), Dt, F)}.

%% Run tests in order, stopping at the first failure; returns {AllPassed, St}.
run_tests([], _Stage, _A, _B, St) -> {true, St};
run_tests([Test | Rest], Stage, A, B, St) ->
    {Pass, Fields} = run_test(Test, pair_view(A, B, St), St),
    Rec = Fields#{<<"stage">> => Stage, <<"a">> => A, <<"b">> => B, <<"pass">> => Pass},
    St1 = record(Rec, St),
    case Pass of
        true -> run_tests(Rest, Stage, A, B, St1);
        false -> {false, St1}
    end.

result(Name, Value, Limit, Pass) ->
    {Pass, #{<<"test">> => Name, <<"value">> => Value, <<"limit">> => Limit}}.

skipped(Name) ->
    {true, #{<<"test">> => Name, <<"value">> => null, <<"limit">> => null,
             <<"skipped">> => true}}.

pos(Filter) ->
    {PE, _, _, _, _} = maps:get(east, Filter),
    {PN, _, _, _, _} = maps:get(north, Filter),
    {PE, PN}.

distance(EA, PredB) ->
    {AE, AN} = pos(maps:get(filter, EA)),
    {BE, BN} = pos(PredB),
    math:sqrt((AE - BE) * (AE - BE) + (AN - BN) * (AN - BN)).

%% d² = sum over east, north of (pa - pb)² / (pp_b + ce_a²).
d2(EA, PredB) ->
    CeA = maps:get(ce, EA),
    Axis = fun(Ax) ->
                   {PA, _, _, _, _} = maps:get(Ax, maps:get(filter, EA)),
                   {PB, _, PPB, _, _} = maps:get(Ax, PredB),
                   (PA - PB) * (PA - PB) / (PPB + CeA * CeA)
           end,
    Axis(east) + Axis(north).

run_test({<<"distance">>, #{<<"max_m">> := Max}}, {EA, _EB, PredB}, _St) ->
    V = distance(EA, PredB),
    result(<<"distance">>, V, Max, V < Max);
run_test({<<"window">>, P}, {EA, EB, PredB}, _St) ->
    #{<<"multiplier">> := M, <<"window_m">> := W,
      <<"err_min_m">> := Lo, <<"err_max_m">> := Hi} = P,
    Ea = clamp(maps:get(ce, EA), Lo, Hi),
    Eb = clamp(maps:get(ce, EB), Lo, Hi),
    Limit = M * math:sqrt(Ea * Ea + Eb * Eb) + W,
    V = distance(EA, PredB),
    result(<<"window">>, V, Limit, V < Limit);
run_test({<<"mahalanobis">>, #{<<"gate">> := Gate}}, {EA, _EB, PredB}, _St) ->
    V = d2(EA, PredB),
    result(<<"mahalanobis">>, V, Gate, V < Gate);
run_test({<<"course">>, #{<<"max_deg">> := Max, <<"min_speed_ms">> := Min}}, {EA, EB, _}, _St) ->
    case moving([EA, EB], Min) of
        [{CA, _}, {CB, _}] ->
            D = abs(CA - CB),
            V = min(D, 360 - D),
            result(<<"course">>, V, Max, V =< Max);
        skip -> skipped(<<"course">>)
    end;
run_test({<<"speed">>, #{<<"max_pct">> := Max, <<"min_speed_ms">> := Min}}, {EA, EB, _}, _St) ->
    case moving([EA, EB], Min) of
        [{_, SA}, {_, SB}] ->
            Slow = min(SA, SB),
            Fast = max(SA, SB),
            V = abs(1 - Slow / Fast) * 100,
            result(<<"speed">>, V, Max, V =< Max);
        skip -> skipped(<<"speed">>)
    end;
run_test({<<"altitude">>, #{<<"max_m">> := Max}}, {EA, EB, _}, _St) ->
    case {value(<<"hae">>, EA), value(<<"hae">>, EB)} of
        {HA, HB} when is_number(HA), is_number(HB) ->
            V = abs(HA - HB),
            result(<<"altitude">>, V, Max, V =< Max);
        _ -> skipped(<<"altitude">>)
    end;
run_test({<<"same">>, #{<<"key">> := K}}, {EA, EB, _}, _St) ->
    VA = value(K, EA),
    VB = value(K, EB),
    result(<<"same">>, VA, VB, VA == VB).

%% Course and speed tests: skipped unless both entities have course and
%% speed_ms with speed at least min_speed_ms.
moving(Ents, Min) ->
    CS = [{value(<<"course">>, E), value(<<"speed_ms">>, E)} || E <- Ents],
    case lists:all(fun({C, S}) -> is_number(C) andalso is_number(S) andalso S >= Min end, CS) of
        true -> CS;
        false -> skip
    end.

clamp(X, Lo, Hi) -> max(Lo, min(Hi, X)).

%% ---------------------------------------------------------------- association

pair(A, B) when A < B -> {A, B};
pair(A, B) -> {B, A}.

count(A, B, St) -> maps:get(pair(A, B), maps:get(counts, St), 0).
set_count(A, B, N, St = #{counts := C}) -> St#{counts := C#{pair(A, B) => N}}.

members(G, St) -> maps:get(G, maps:get(groups, St)).
group_name(G) -> <<"g", (integer_to_binary(G))/binary>>.

%% Association, A in a group: hold.
hold(A, G, St0) ->
    Pack = maps:get(pack, St0),
    Others = [B || B <- members(G, St0), B =/= A],
    {Passes, St1} = hold_members(maps:get(hold, Pack), A, Others, [], St0),
    Ent = entity(A, St1),
    case lists:member(true, Passes) of
        true -> put_entity(A, Ent#{hold_failures := 0}, St1);
        false ->
            Fails = maps:get(hold_failures, Ent) + 1,
            St2 = put_entity(A, Ent#{hold_failures := Fails}, St1),
            case Fails >= maps:get(hold_failures, Pack) of
                true -> leave(A, G, <<"hold">>, St2);
                false -> St2
            end
    end.

hold_members(_Tests, _A, [], Acc, St) -> {lists:reverse(Acc), St};
hold_members(Tests, A, [B | Bs], Acc, St0) ->
    {Pass, St1} = run_tests(Tests, <<"hold">>, A, B, St0),
    hold_members(Tests, A, Bs, [Pass | Acc], St1).

%% Leave a group (count reset); dissolve it when one member is left.
leave(A, G, Reason, St0) ->
    Ent = entity(A, St0),
    St1 = put_entity(A, Ent#{group := none, hold_failures := 0}, St0),
    St2 = emit(#{<<"ev">> => <<"leave">>, <<"group">> => group_name(G),
                 <<"entity">> => A, <<"reason">> => Reason}, St1),
    case [M || M <- members(G, St2), M =/= A] of
        [Last] ->
            LastEnt = entity(Last, St2),
            St3 = put_entity(Last, LastEnt#{group := none}, St2),
            St4 = St3#{groups := maps:remove(G, maps:get(groups, St3))},
            emit(#{<<"ev">> => <<"dissolve">>, <<"group">> => group_name(G),
                   <<"entity">> => Last}, St4);
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
    D2 = d2(EA, PredB),
    Rec = #{<<"stage">> => <<"rank">>, <<"a">> => A, <<"b">> => B, <<"test">> => <<"rank">>,
            <<"value">> => D2, <<"limit">> => null, <<"pass">> => true},
    rank(A, Bs, [{D2, B} | Acc], record(Rec, St)).

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
    {GatePass, St1} = run_tests(maps:get(gate, Pack), <<"gate">>, A, B, St0),
    {AllPass, St2} = case GatePass of
                         true -> run_tests(maps:get(confirm, Pack), <<"confirm">>, A, B, St1);
                         false -> {false, St1}
                     end,
    N = case AllPass of
            true -> count(A, B, St2) + 1;
            false -> 0
        end,
    CC = maps:get(confirm_count, Pack),
    St3 = set_count(A, B, N, St2),
    record(#{<<"stage">> => <<"confirm">>, <<"a">> => A, <<"b">> => B,
             <<"test">> => <<"count">>, <<"value">> => N, <<"limit">> => CC,
             <<"pass">> => N >= CC}, St3).

group_with(A, B, St) ->
    EA = entity(A, St),
    case maps:get(group, entity(B, St)) of
        none ->
            G = maps:get(next_group, St),
            EB = entity(B, St),
            Ms = lists:sort([A, B]),
            St1 = put_entity(B, EB#{group := G}, put_entity(A, EA#{group := G}, St)),
            St2 = St1#{groups := (maps:get(groups, St1))#{G => Ms}, next_group := G + 1},
            emit(#{<<"ev">> => <<"correlate">>, <<"group">> => group_name(G),
                   <<"members">> => Ms}, St2);
        G ->
            Ms = lists:sort([A | members(G, St)]),
            St1 = put_entity(A, EA#{group := G}, St),
            St2 = St1#{groups := (maps:get(groups, St1))#{G => Ms}},
            emit(#{<<"ev">> => <<"join">>, <<"group">> => group_name(G),
                   <<"entity">> => A}, St2)
    end.

%% ---------------------------------------------------------------- tick

tick(Now, St0) ->
    St1 = lists:foldl(fun(K, S) -> stale(K, Now, S) end, St0,
                      lists:sort(maps:keys(maps:get(entities, St0)))),
    St2 = lists:foldl(fun(G, S) -> fused(G, Now, S) end, St1,
                      lists:sort(maps:keys(maps:get(groups, St1)))),
    finish(St2).

%% Tick step 1, staleness.
stale(K, Now, St0) ->
    Ent = entity(K, St0),
    Last = maps:get(time, Ent),
    ReportStale = value(<<"stale_ms">>, Ent),
    IsStale = Now - Last > maps:get(stale_ms, maps:get(pack, St0))
        orelse (is_number(ReportStale) andalso Now >= ReportStale),
    case IsStale of
        false -> St0;
        true ->
            St1 = case maps:get(group, Ent) of
                      none -> St0;
                      G -> leave(K, G, <<"stale">>, St0)
                  end,
            Counts = maps:filter(fun({X, Y}, _) -> X =/= K andalso Y =/= K end,
                                 maps:get(counts, St1)),
            St2 = St1#{entities := maps:remove(K, maps:get(entities, St1)), counts := Counts},
            emit(#{<<"ev">> => <<"drop">>, <<"entity">> => K}, St2)
    end.

%% Tick step 2, fused output.
fused(G, Now, St) ->
    Pack = maps:get(pack, St),
    Ms = members(G, St),
    Primary = primary(maps:get(output, Pack), Ms, Pack, St),
    Ent = entity(Primary, St),
    Pred = correlator_filter:predict(maps:get(filter, Ent),
                                     (Now - maps:get(time, Ent)) / 1000,
                                     maps:get(filter, Pack)),
    {PE, VE, _, _, _} = maps:get(east, Pred),
    {PN, VN, _, _, _} = maps:get(north, Pred),
    {Lat, Lon} = correlator_filter:from_plane(maps:get(ref, St), PE, PN),
    C0 = math:atan2(VE, VN) * 180 / math:pi(),
    Course = if C0 < 0 -> C0 + 360; C0 >= 360 -> C0 - 360; true -> C0 end,
    Ev0 = #{<<"ev">> => <<"fused">>, <<"group">> => group_name(G),
            <<"primary">> => Primary, <<"members">> => Ms,
            <<"lat">> => Lat, <<"lon">> => Lon, <<"course">> => Course,
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

%% ---------------------------------------------------------------- snapshot

snapshot(St) ->
    #{ref := Ref, entities := Ents, groups := Groups, counts := Counts,
      next_group := Next} = St,
    Axis = fun({P, V, PP, PV, VV}) -> [P, V, PP, PV, VV] end,
    #{<<"ref">> => case Ref of none -> null; {Lat, Lon} -> [Lat, Lon] end,
      <<"entities">> =>
          maps:from_list(
            [{K, #{<<"last_time_ms">> => maps:get(time, E),
                   <<"group">> => case maps:get(group, E) of
                                      none -> null;
                                      G -> group_name(G)
                                  end,
                   <<"hold_failures">> => maps:get(hold_failures, E),
                   <<"filter">> => #{<<"east">> => Axis(maps:get(east, maps:get(filter, E))),
                                     <<"north">> => Axis(maps:get(north, maps:get(filter, E)))}}}
             || {K, E} <- maps:to_list(Ents)]),
      <<"groups">> => maps:from_list([{group_name(G), Ms} || {G, Ms} <- maps:to_list(Groups)]),
      <<"counts">> => maps:from_list([{<<A/binary, "|", B/binary>>, N}
                                      || {{A, B}, N} <- maps:to_list(Counts)]),
      <<"next_group">> => Next}.
