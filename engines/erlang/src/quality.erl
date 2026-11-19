%% The quality engine: load_pack, new, ingest, tick, snapshot (spec/quality.md).
%% State is a value; ingest and tick return {Events, Trace, NewState}.
%% The frame and the filter are correlator_filter's (correlate.md "Frame",
%% "Track estimate"), as quality.md "Frame and filter" cites them.
%% Explicit recursion and folds stand in for lists:mapfoldl, which OTP 27.3
%% miscompiles when a case on its result follows.
-module(quality).
-export([load_pack/1, new/1, ingest/2, tick/2, snapshot/1]).

%% Reports: required keys in table order with their type.
-define(REQUIRED, [{<<"track.source_id">>, string}, {<<"uid">>, string},
                   {<<"time_ms">>, integer}, {<<"lat">>, number}, {<<"lon">>, number}]).

load_pack(Dir) -> quality_pack:load_pack(Dir).

new(Pack) ->
    #{pack => Pack, ref => null, last_tick => null, entities => #{},
      rules => maps:from_list([{maps:get(name, R), #{}} || R <- maps:get(rules, Pack)]),
      events => [], trace => []}.

%% ---------------------------------------------------------------- output

emit(Ev, St = #{events := Es}) -> St#{events := [Ev | Es]}.
record(Rec, St = #{trace := Ts}) -> St#{trace := [Rec | Ts]}.

finish(St = #{events := Es, trace := Ts}) ->
    {lists:reverse(Es), lists:reverse(Ts), St#{events := [], trace := []}}.

%% ---------------------------------------------------------------- reports

%% Reports: a value of the wrong type is missing (required) or absent
%% (optional). A boolean is an atom in OTP's json, so never a number.
typed(string, V) -> is_binary(V);
typed(integer, V) -> is_integer(V);
typed(number, V) -> is_number(V);
typed(positive, V) -> is_number(V) andalso V > 0.

%% An optional key's value, or null when absent, null or of the wrong type.
optional(Key, Type, Report) ->
    V = maps:get(Key, Report, null),
    case typed(Type, V) of
        true -> V;
        false -> null
    end.

entity_key(R) ->
    <<(maps:get(<<"track.source_id">>, R))/binary, "/", (maps:get(<<"uid">>, R))/binary>>.

%% ---------------------------------------------------------------- ingest

%% Ingest: check the required keys (reject ends it); set the reference; find
%% the order; take the samples; create or update the entity; append the
%% record; emit pass.
ingest(Report, St) ->
    case [K || {K, Type} <- ?REQUIRED, not typed(Type, maps:get(K, Report, null))] of
        [Missing | _] ->
            finish(emit(#{<<"ev">> => <<"reject">>,
                          <<"reason">> => <<"missing:", Missing/binary>>}, St));
        [] ->
            finish(accept(Report, St))
    end.

accept(Report, St0) ->
    #{pack := Pack} = St0,
    F = maps:get(filter, Pack),
    Key = entity_key(Report),
    T = maps:get(<<"time_ms">>, Report),
    Lat = maps:get(<<"lat">>, Report),
    Lon = maps:get(<<"lon">>, Report),
    Ce = optional(<<"ce">>, positive, Report),
    Course = optional(<<"course">>, number, Report),
    Speed = optional(<<"speed_ms">>, number, Report),
    Hae = optional(<<"hae">>, number, Report),
    Received = optional(<<"received_ms">>, integer, Report),
    MeasCe = case Ce of null -> maps:get(<<"default_ce_m">>, F); _ -> Ce end,
    Vel = correlator_filter:velocity(Course, Speed),

    %% Frame and filter: the first accepted report sets the reference.
    St1 = case maps:get(ref, St0) of
              null -> St0#{ref := {Lat, Lon}};
              _ -> St0
          end,
    {E, N} = Z = correlator_filter:to_plane(maps:get(ref, St1), Lat, Lon),

    %% Order, and the window time wt.
    Existing = maps:find(Key, maps:get(entities, St1)),
    {Order, Last} = case Existing of
                        error -> {<<"first">>, null};
                        {ok, #{last := L}} when T > L -> {<<"advance">>, L};
                        {ok, #{last := L}} when T =:= L -> {<<"duplicate">>, L};
                        {ok, #{last := L}} -> {<<"out-of-order">>, L}
                    end,
    Wt = case Order of
             <<"first">> -> T;
             <<"advance">> -> T;
             _ -> Last
         end,
    St2 = sample(Key, <<"order">>, Order, [T, Last], St1),

    %% Samples, in the order interval, latency, nis, speed_err.
    Advance = Order =:= <<"advance">>,
    {Interval, St3} =
        case Advance of
            true -> take(Key, <<"interval">>, T - Last, [T, Last], St2);
            false -> {null, St2}
        end,
    {Latency, St4} =
        case Received of
            null -> {null, St3};
            _ -> take(Key, <<"latency">>, Received - T, [Received, T], St3)
        end,
    {Nis, St5} =
        case Advance of
            true -> nis(Key, maps:get(filter, element(2, Existing)), (T - Last) / 1000,
                        Z, MeasCe, F, St4);
            false -> {null, St4}
        end,
    {SpeedErr, St6} =
        case Advance andalso Speed =/= null of
            true ->
                {LE, LN} = maps:get(last_pos, element(2, Existing)),
                Dt = (T - Last) / 1000,
                Implied = math:sqrt((E - LE) * (E - LE) + (N - LN) * (N - LN)) / Dt,
                take(Key, <<"speed_err">>, abs(Implied - Speed), [Implied, Speed], St5);
            false -> {null, St5}
        end,

    %% Create the entity (event new) or update filter, last and last_pos.
    {Ent0, St7} =
        case Existing of
            error ->
                {#{source => maps:get(<<"track.source_id">>, Report), last => T,
                   last_pos => Z, filter => correlator_filter:init(Z, Vel, MeasCe, F),
                   window => []},
                 emit(#{<<"ev">> => <<"new">>, <<"entity">> => Key}, St6)};
            {ok, Old = #{filter := Filter}} when Advance ->
                {Old#{last := T, last_pos := Z,
                      filter := correlator_filter:update(Filter, (T - Last) / 1000, Z, Vel,
                                                         MeasCe, F)},
                 St6};
            {ok, Old} ->
                {Old, St6}
        end,

    %% The record, appended in arrival order.
    Record = #{<<"wt">> => Wt, <<"time_ms">> => T, <<"order">> => Order,
               <<"interval">> => Interval, <<"latency">> => Latency, <<"nis">> => Nis,
               <<"speed_err">> => SpeedErr, <<"ce">> => Ce =/= null,
               <<"vel">> => Vel =/= none, <<"hae">> => Hae =/= null},
    Ent = Ent0#{window := maps:get(window, Ent0) ++ [Record]},
    St8 = St7#{entities := (maps:get(entities, St7))#{Key => Ent}},
    emit(pass(Key, Ent, Report, Ce, St8), St8).

%% Samples, nis: predict to t, compare with the report's position against
%% the predicted plus the reported variance, east then north.
nis(Key, Filter, Dt, {E, N}, Ce, F, St) ->
    #{east := {PE, _, PPE, _, _}, north := {PN, _, PPN, _, _}} =
        correlator_filter:predict(Filter, Dt, F),
    R = Ce * Ce,
    De = E - PE,
    Dn = N - PN,
    Se = PPE + R,
    Sn = PPN + R,
    Nis = De * De / Se + Dn * Dn / Sn,
    take(Key, <<"nis">>, Nis, [De, Dn, Se, Sn], St).

%% Trace, ingest: one record per sample, preceded by the order.
sample(Key, Name, Value, Inputs, St) ->
    record(#{<<"stage">> => <<"sample">>, <<"entity">> => Key, <<"sample">> => Name,
             <<"value">> => Value, <<"inputs">> => Inputs}, St).

take(Key, Name, Value, Inputs, St) -> {Value, sample(Key, Name, Value, Inputs, St)}.

%% ---------------------------------------------------------------- forwarding

%% Forwarding: the actions in force other than alert, in pack order.
pass(Key, #{source := Src}, Report, Ce, St = #{pack := Pack}) ->
    InForce = [R || R = #{action := A} <- maps:get(rules, Pack), A =/= <<"alert">>,
                    active(R, subject(R, Key, Src), St)],
    Names = [maps:get(name, R) || R <- InForce],
    Base = #{<<"ev">> => <<"pass">>, <<"entity">> => Key, <<"rules">> => Names},
    case [R || R = #{action := <<"drop">>} <- InForce] of
        [_ | _] -> Base#{<<"withheld">> => true};
        [] -> Base#{<<"withheld">> => false,
                    <<"report">> => marks(InForce, downgrade(InForce, Ce, Pack, Report))}
    end.

subject(#{scope := entity}, Key, _Src) -> Key;
subject(#{scope := source}, _Key, Src) -> Src.

active(#{name := Name}, Subject, #{rules := Rules}) ->
    case maps:get(Subject, maps:get(Name, Rules), none) of
        #{active := true} -> true;
        _ -> false
    end.

%% ce: the valid ce or default_ce_m, times each downgrade factor in pack order.
downgrade(InForce, Ce, Pack, Report) ->
    case [Fa || #{action := <<"downgrade">>, factor := Fa} <- InForce] of
        [] -> Report;
        Factors ->
            X0 = case Ce of null -> maps:get(<<"default_ce_m">>, maps:get(filter, Pack));
                     _ -> Ce
                 end,
            Report#{<<"ce">> => lists:foldl(fun(Fa, X) -> X * Fa end, X0, Factors)}
    end.

%% quality.marks: the received list when it is all strings, else empty; then
%% each mark rule name in pack order that it does not hold.
marks(InForce, Report) ->
    case [Name || #{action := <<"mark">>, name := Name} <- InForce] of
        [] -> Report;
        Names ->
            Start = case maps:get(<<"quality.marks">>, Report, null) of
                        L when is_list(L) ->
                            case lists:all(fun is_binary/1, L) of
                                true -> L;
                                false -> []
                            end;
                        _ -> []
                    end,
            Marks = lists:foldl(fun(Nm, Acc) ->
                                        case lists:member(Nm, Acc) of
                                            true -> Acc;
                                            false -> Acc ++ [Nm]
                                        end
                                end, Start, Names),
            Report#{<<"quality.marks">> => Marks}
    end.

%% ---------------------------------------------------------------- tick

tick(Now, St = #{last_tick := Prev}) when Prev =/= null, Now < Prev ->
    %% Step 1, order.
    finish(emit(#{<<"ev">> => <<"reject">>, <<"reason">> => <<"tick-out-of-order">>}, St));
tick(Now, St0) ->
    #{pack := Pack} = St0,
    SourcesBefore = sources(St0),
    St1 = lists:foldl(fun(K, S) -> forget_entity(K, Now, S) end,
                      St0#{last_tick := Now}, lists:sort(maps:keys(maps:get(entities, St0)))),
    SourcesAfter = sources(St1),
    St2 = lists:foldl(fun(Src, S) -> forget_source(Src, S) end, St1,
                      [Src || Src <- SourcesBefore, not lists:member(Src, SourcesAfter)]),
    St3 = drop_old(Now - maps:get(window_ms, Pack), St2),
    Keys = lists:sort(maps:keys(maps:get(entities, St3))),
    {EntityMeasures, St4} = entities_step(Keys, Now, #{}, St3),
    St5 = lists:foldl(fun(Src, S) -> source_step(Src, Keys, EntityMeasures, S) end,
                      St4, sources(St4)),
    finish(St5).

%% The sources that have entities, in key order.
sources(#{entities := Es}) ->
    lists:usort([Src || _ := #{source := Src} <- Es]).

%% Step 2, forget entities: now - last > forget_ms.
forget_entity(Key, Now, St) ->
    #{pack := #{forget_ms := Forget}, entities := Es} = St,
    #{last := Last} = maps:get(Key, Es),
    case Now - Last > Forget of
        true ->
            St1 = forget_subject(entity, Key, St),
            emit(#{<<"ev">> => <<"forget">>, <<"entity">> => Key},
                 St1#{entities := maps:remove(Key, Es)});
        false -> St
    end.

%% Step 3, forget sources: had entities at the start of the tick, none now.
forget_source(Src, St) ->
    emit(#{<<"ev">> => <<"forget">>, <<"source">> => Src}, forget_subject(source, Src, St)).

%% Each active rule of the scope for the subject ends (reason forget, value
%% null), in pack order; every rule state for the subject is removed.
forget_subject(Scope, Subject, St0) ->
    Rules = [R || R = #{scope := S} <- maps:get(rules, maps:get(pack, St0)), S =:= Scope],
    lists:foldl(
      fun(R = #{name := Name}, St) ->
              St1 = case active(R, Subject, St) of
                        true -> emit(action_end(R, Subject, <<"forget">>, null), St);
                        false -> St
                    end,
              #{rules := RS} = St1,
              St1#{rules := RS#{Name := maps:remove(Subject, maps:get(Name, RS))}}
      end, St0, Rules).

%% Step 4, window: drop the records with wt <= now - window_ms.
drop_old(Edge, St = #{entities := Es}) ->
    St#{entities := maps:map(fun(_, E = #{window := W}) ->
                                     E#{window := [R || R = #{<<"wt">> := Wt} <- W, Wt > Edge]}
                             end, Es)}.

%% Step 5, entities in key order: measures, quality event, entity rules.
entities_step([], _Now, Acc, St) -> {Acc, St};
entities_step([Key | Keys], Now, Acc, St0) ->
    Ms = entity_measures(maps:get(Key, maps:get(entities, St0)), Now,
                         maps:get(min_samples, maps:get(pack, St0))),
    St1 = emit(quality_event(<<"entity">>, Key, Ms), St0),
    St2 = evaluate(entity, Key, Ms, St1),
    entities_step(Keys, Now, Acc#{Key => Ms}, St2).

%% Step 6, one source: measures over its entities in key order, quality
%% event, source rules.
source_step(Src, Keys, EntityMeasures, St0) ->
    Mine = [maps:get(K, EntityMeasures) || K <- Keys,
                                           maps:get(source, maps:get(K, maps:get(entities, St0)))
                                               =:= Src],
    Ms = source_measures(Mine),
    St1 = emit(quality_event(<<"source">>, Src, Ms), St0),
    evaluate(source, Src, Ms, St1).

quality_event(Scope, Subject, Ms) ->
    #{<<"ev">> => <<"quality">>, <<"scope">> => Scope, <<"subject">> => Subject,
      <<"measures">> => Ms}.

%% ---------------------------------------------------------------- measures

%% Entity measures over the window W with min_samples K.
entity_measures(#{window := W, last := Last}, Now, K) ->
    Reports = length(W),
    Stat = fun(Sample, Fun) ->
                   case [V || #{Sample := V} <- W, V =/= null] of
                       Vs when length(Vs) >= K -> Fun(Vs);
                       _ -> null
                   end
           end,
    Count = fun(Order) -> length([R || R = #{<<"order">> := O} <- W, O =:= Order]) end,
    Missing = fun(Flag) ->
                      case Reports < K of
                          true -> null;
                          false -> length([R || R = #{Flag := false} <- W]) / Reports
                      end
              end,
    #{<<"reports">> => Reports,
      <<"interval_last">> => Stat(<<"interval">>, fun lists:last/1),
      <<"interval_mean">> => Stat(<<"interval">>, fun mean/1),
      <<"interval_max">> => Stat(<<"interval">>, fun lists:max/1),
      <<"age">> => Now - Last,
      <<"latency_mean">> => Stat(<<"latency">>, fun mean/1),
      <<"latency_max">> => Stat(<<"latency">>, fun lists:max/1),
      <<"nis_mean">> => Stat(<<"nis">>, fun mean/1),
      <<"speed_err_mean">> => Stat(<<"speed_err">>, fun mean/1),
      <<"out_of_order">> => Count(<<"out-of-order">>),
      <<"duplicate">> => Count(<<"duplicate">>),
      <<"missing_ce">> => Missing(<<"ce">>),
      <<"missing_vel">> => Missing(<<"vel">>),
      <<"missing_hae">> => Missing(<<"hae">>)}.

%% A mean is s / n, s starting at 0.0 and adding each value in order.
mean(Vs) -> lists:foldl(fun(V, S) -> S + V end, 0.0, Vs) / length(Vs).

%% Source measures: aggregate the entities' measures, taken in key order.
source_measures(Mine) ->
    Present = fun(M) -> [V || #{M := V} <- Mine, V =/= null] end,
    Agg = fun(M, Fun) ->
                  case Present(M) of
                      [] -> null;
                      Vs -> Fun(Vs)
                  end
          end,
    Sum = fun(M) -> lists:sum(Present(M)) end,
    Means = [<<"interval_last">>, <<"interval_mean">>, <<"latency_mean">>, <<"nis_mean">>,
             <<"speed_err_mean">>, <<"missing_ce">>, <<"missing_vel">>, <<"missing_hae">>],
    maps:from_list(
      [{M, Sum(M)} || M <- [<<"reports">>, <<"out_of_order">>, <<"duplicate">>]] ++
      [{M, Agg(M, fun mean/1)} || M <- Means] ++
      [{M, Agg(M, fun lists:max/1)} || M <- [<<"interval_max">>, <<"latency_max">>]] ++
      [{<<"age">>, lists:min(Present(<<"age">>))},
       {<<"entities">>, length(Mine)}]).

%% ---------------------------------------------------------------- rules

%% Evaluate each rule of the scope, in pack order, for one subject.
evaluate(Scope, Subject, Ms, St0) ->
    Rules = [R || R = #{scope := S} <- maps:get(rules, maps:get(pack, St0)), S =:= Scope],
    lists:foldl(fun(R, St) -> evaluate_rule(R, Subject, maps:get(maps:get(measure, R), Ms), St)
                end, St0, Rules).

%% Rules, evaluation. State {count, active}, created {0, false}.
evaluate_rule(Rule, Subject, V, St0) ->
    #{name := Name, op := Op, limit := Limit, clear := Clear, for := For} = Rule,
    #{rules := RS} = St0,
    #{count := Count0, active := Active0} =
        maps:get(Subject, maps:get(Name, RS), #{count => 0, active => false}),
    {TraceLimit, Pass, State, Event} =
        case Active0 of
            false ->
                Met = V =/= null andalso holds(Op, V, Limit),
                Count = case Met of true -> Count0 + 1; false -> 0 end,
                case Count >= For of
                    true -> {Limit, Met, #{count => 0, active => true},
                             action_start(Rule, Subject, V)};
                    false -> {Limit, Met, #{count => Count, active => false}, none}
                end;
            true ->
                Cleared = V =/= null andalso clears(Op, V, Clear),
                case Cleared of
                    true -> {Clear, true, #{count => 0, active => false},
                             action_end(Rule, Subject, <<"clear">>, V)};
                    false -> {Clear, false, #{count => Count0, active => true}, none}
                end
        end,
    St1 = St0#{rules := RS#{Name := (maps:get(Name, RS))#{Subject => State}}},
    St2 = case Event of none -> St1; _ -> emit(Event, St1) end,
    record(#{<<"stage">> => <<"rule">>, <<"rule">> => Name, <<"subject">> => Subject,
             <<"measure">> => maps:get(measure, Rule), <<"value">> => V,
             <<"limit">> => TraceLimit, <<"pass">> => Pass,
             <<"count">> => maps:get(count, State), <<"active">> => maps:get(active, State)},
           St2).

%% Erlang compares an integer with a float by value, so an integer measure
%% equal to the limit is compared exactly.
holds(<<"<">>, V, L) -> V < L;
holds(<<"<=">>, V, L) -> V =< L;
holds(<<">">>, V, L) -> V > L;
holds(<<">=">>, V, L) -> V >= L.

clears(<<">", _/binary>>, V, C) -> V < C;
clears(<<"<", _/binary>>, V, C) -> V > C.

action_start(#{name := N, scope := S, action := A}, Subject, V) ->
    #{<<"ev">> => <<"action-start">>, <<"rule">> => N, <<"scope">> => atom_to_binary(S),
      <<"subject">> => Subject, <<"action">> => A, <<"value">> => V}.

action_end(#{name := N, scope := S, action := A}, Subject, Reason, V) ->
    #{<<"ev">> => <<"action-end">>, <<"rule">> => N, <<"scope">> => atom_to_binary(S),
      <<"subject">> => Subject, <<"action">> => A, <<"reason">> => Reason, <<"value">> => V}.

%% ---------------------------------------------------------------- snapshot

snapshot(#{ref := Ref, last_tick := LastTick, entities := Es, rules := RS}) ->
    #{<<"ref">> => case Ref of null -> null; {Lat, Lon} -> [Lat, Lon] end,
      <<"last_tick">> => LastTick,
      <<"entities">> =>
          maps:map(fun(_, #{source := Src, last := Last, last_pos := {E, N},
                            filter := #{east := FE, north := FN}, window := W}) ->
                           #{<<"source">> => Src, <<"last_time_ms">> => Last,
                             <<"last_pos">> => [E, N],
                             <<"filter">> => #{<<"east">> => tuple_to_list(FE),
                                               <<"north">> => tuple_to_list(FN)},
                             <<"window">> => W}
                   end, Es),
      <<"rules">> =>
          maps:map(fun(_, Subjects) ->
                           maps:map(fun(_, #{count := C, active := A}) ->
                                            #{<<"count">> => C, <<"active">> => A}
                                    end, Subjects)
                   end, RS)}.
