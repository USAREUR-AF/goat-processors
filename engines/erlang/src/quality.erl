%% The quality engine: load_pack, new, ingest, tick, snapshot (spec/quality.md 0.2).
%% State is a value; ingest and tick return {Events, Trace, NewState}.
%% The frame and the filter are correlator_filter's (correlate.md "Frame",
%% "Track estimate"), as quality.md "Frame and filter" cites them; the time
%% keys are read by correlator:time_keys/2 (correlate.md 0.8 "Time quality",
%% steps 1 and 2), as quality.md "Time quality" cites them.
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
%% the order; build the input clock and the source latest; take the samples;
%% create or update the entity; append the record; emit pass.
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

    %% Input clock and source latest, from the entities before this report.
    Source = maps:get(<<"track.source_id">>, Report),
    Clock = input_clock(Source, maps:get(entities, St1)),
    SourceLatest = source_latest(Source, maps:get(entities, St1)),

    %% Samples, in the order interval, latency, lateness, time_error,
    %% time_state, source_order, nis, speed_err.
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
    {Lateness, St5} =
        case Clock of
            none -> {null, St4};
            _ -> take(Key, <<"lateness">>, Clock - T, [Clock, T], St4)
        end,
    {{ReportTe, DefaultTe}, {ReportState, DefaultState}} =
        correlator:time_keys(Report, maps:get(time_default, Pack)),
    {TimeError, St6} = time_sample(Key, <<"time_error">>, ReportTe, DefaultTe, St5),
    {TimeState, St7} = time_sample(Key, <<"time_state">>, ReportState, DefaultState, St6),
    SourceOrder = case SourceLatest of
                      none -> <<"in-order">>;
                      _ when T < SourceLatest -> <<"out-of-order">>;
                      _ -> <<"in-order">>
                  end,
    St8 = sample(Key, <<"source_order">>, SourceOrder,
                 [T, case SourceLatest of none -> null; _ -> SourceLatest end], St7),
    {Nis, St9} =
        case Advance of
            true -> nis(Key, maps:get(filter, element(2, Existing)), (T - Last) / 1000,
                        Z, MeasCe, F, St8);
            false -> {null, St8}
        end,
    {SpeedErr, St10} =
        case Advance andalso Speed =/= null of
            true ->
                {LE, LN} = maps:get(last_pos, element(2, Existing)),
                Dt = (T - Last) / 1000,
                Implied = math:sqrt((E - LE) * (E - LE) + (N - LN) * (N - LN)) / Dt,
                take(Key, <<"speed_err">>, abs(Implied - Speed), [Implied, Speed], St9);
            false -> {null, St9}
        end,

    %% Create the entity (event new) or update filter, last and last_pos.
    {Ent0, St11} =
        case Existing of
            error ->
                {#{source => Source, last => T,
                   last_pos => Z, filter => correlator_filter:init(Z, Vel, MeasCe, F),
                   window => []},
                 emit(#{<<"ev">> => <<"new">>, <<"entity">> => Key}, St10)};
            {ok, Old = #{filter := Filter}} when Advance ->
                {Old#{last := T, last_pos := Z,
                      filter := element(1, correlator_filter:update(Filter, (T - Last) / 1000,
                                                                     maps:get(<<"accel_var">>, F),
                                                                     Z, Vel, MeasCe, F))},
                 St10};
            {ok, Old} ->
                {Old, St10}
        end,

    %% The record, appended in arrival order.
    Record = #{<<"wt">> => Wt, <<"time_ms">> => T, <<"order">> => Order,
               <<"interval">> => Interval, <<"latency">> => Latency,
               <<"lateness">> => Lateness,
               <<"source_out_of_order">> => SourceOrder =:= <<"out-of-order">>,
               <<"time_error">> => TimeError, <<"time_state">> => TimeState,
               <<"nis">> => Nis, <<"speed_err">> => SpeedErr, <<"ce">> => Ce =/= null,
               <<"vel">> => Vel =/= none, <<"hae">> => Hae =/= null},
    Ent = Ent0#{window := maps:get(window, Ent0) ++ [Record]},
    St12 = St11#{entities := (maps:get(entities, St11))#{Key => Ent}},
    emit(pass(Key, Source, Report, Ce, St12), St12).

%% Input clock: for each source other than the report's, its latest time is
%% the greatest last among the entities whose source it is; the clock is the
%% median of those times (the mean of the two middle values, in binary64, for
%% an even count), or none with no other source.
input_clock(Source, Entities) ->
    median(lists:sort([L || Src := L <- latest_by_source(Entities), Src =/= Source])).

median([]) -> none;
median(Sorted) ->
    N = length(Sorted),
    case N rem 2 of
        1 -> lists:nth(N div 2 + 1, Sorted);
        0 -> (float(lists:nth(N div 2, Sorted)) + float(lists:nth(N div 2 + 1, Sorted))) / 2
    end.

%% Source latest: the greatest last among the entities whose source is the
%% report's track.source_id (its own entity included when that is its
%% source), or none.
source_latest(Source, Entities) ->
    maps:get(Source, latest_by_source(Entities), none).

%% #{Source => greatest last among its entities}.
latest_by_source(Entities) ->
    maps:fold(fun(_, #{source := Src, last := L}, Acc) ->
                      case Acc of
                          #{Src := M} when M >= L -> Acc;
                          _ -> Acc#{Src => L}
                      end
              end, #{}, Entities).

%% Samples, time_error and time_state (quality.md "Time quality"): the
%% report's valid value, otherwise the time_default's; otherwise unstated, no
%% sample. The trace inputs are [report value, default value].
time_sample(_Key, _Name, null, null, St) -> {null, St};
time_sample(Key, Name, null, Default, St) -> take(Key, Name, Default, [null, Default], St);
time_sample(Key, Name, Own, Default, St) -> take(Key, Name, Own, [Own, Default], St).

%% Samples, nis: predict to t, compare with the report's position against
%% the predicted plus the reported variance, east then north.
nis(Key, Filter, Dt, {E, N}, Ce, F, St) ->
    #{east := {PE, _, PPE, _, _}, north := {PN, _, PPN, _, _}} =
        correlator_filter:predict(Filter, Dt, maps:get(<<"accel_var">>, F)),
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

%% Forwarding: the actions in force other than alert, in pack order. Source
%% rules are those of the report's own track.source_id (quality.md "Reports"),
%% which differs from the entity's source only when keys collide.
pass(Key, Src, Report, Ce, St = #{pack := Pack}) ->
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

%% ce: the valid ce or default_ce_m, times each downgrade factor in pack
%% order; the largest finite binary64 when that overflows to infinity.
downgrade(InForce, Ce, Pack, Report) ->
    case [Fa || #{action := <<"downgrade">>, factor := Fa} <- InForce] of
        [] -> Report;
        Factors ->
            X0 = case Ce of null -> maps:get(<<"default_ce_m">>, maps:get(filter, Pack));
                     _ -> Ce
                 end,
            Report#{<<"ce">> => multiply(X0, Factors)}
    end.

%% OTP raises badarith where IEEE-754 gives infinity; every factor is at least
%% 1, so once infinite x stays infinite, and the result is the largest finite
%% binary64.
multiply(X0, Factors) ->
    try lists:foldl(fun(Fa, X) -> X * Fa end, X0, Factors)
    catch error:badarith -> 1.7976931348623157e308
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
      <<"lateness_mean">> => Stat(<<"lateness">>, fun mean/1),
      <<"lateness_max">> => Stat(<<"lateness">>, fun lists:max/1),
      <<"lateness_min">> => Stat(<<"lateness">>, fun lists:min/1),
      <<"nis_mean">> => Stat(<<"nis">>, fun mean/1),
      <<"speed_err_mean">> => Stat(<<"speed_err">>, fun mean/1),
      <<"out_of_order">> => Count(<<"out-of-order">>),
      <<"duplicate">> => Count(<<"duplicate">>),
      <<"source_out_of_order">> => length([R || R = #{<<"source_out_of_order">> := true} <- W]),
      <<"missing_ce">> => Missing(<<"ce">>),
      <<"missing_vel">> => Missing(<<"vel">>),
      <<"missing_hae">> => Missing(<<"hae">>),
      <<"time_error_mean">> => Stat(<<"time_error">>, fun mean/1),
      <<"time_error_max">> => Stat(<<"time_error">>, fun lists:max/1),
      <<"time_state_last">> => Stat(<<"time_state">>, fun(Ss) -> state_code(lists:last(Ss)) end),
      <<"time_state_worst">> =>
          Stat(<<"time_state">>, fun(Ss) -> lists:max([state_code(S) || S <- Ss]) end),
      <<"missing_time">> =>
          case Reports < K of
              true -> null;
              false -> length([R || R = #{<<"time_state">> := null} <- W]) / Reports
          end}.

%% Time quality: the code of a time state; higher is worse.
state_code(<<"coherent">>) -> 0;
state_code(<<"drifting">>) -> 1;
state_code(<<"free-running">>) -> 2.

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
    Sums = [<<"reports">>, <<"out_of_order">>, <<"duplicate">>, <<"source_out_of_order">>],
    Means = [<<"interval_last">>, <<"interval_mean">>, <<"latency_mean">>,
             <<"lateness_mean">>, <<"nis_mean">>, <<"speed_err_mean">>, <<"missing_ce">>,
             <<"missing_vel">>, <<"missing_hae">>, <<"time_error_mean">>, <<"missing_time">>],
    Largest = [<<"interval_max">>, <<"latency_max">>, <<"lateness_max">>,
               <<"time_error_max">>, <<"time_state_last">>, <<"time_state_worst">>],
    maps:from_list(
      [{M, Sum(M)} || M <- Sums] ++
      [{M, Agg(M, fun mean/1)} || M <- Means] ++
      [{M, Agg(M, fun lists:max/1)} || M <- Largest] ++
      [{<<"lateness_min">>, Agg(<<"lateness_min">>, fun lists:min/1)},
       {<<"age">>, lists:min(Present(<<"age">>))},
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
