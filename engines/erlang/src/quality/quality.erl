%% Quality (spec/quality.md 0.2): the entry point.
%%   load_pack(Dir[, Extensions]) -> {ok, Pack} | {error, Why}
%%   new(Pack) -> State
%%   ingest(Report, State) -> {Events, Trace, State}
%%   tick(NowMs, State) -> {Events, Trace, State}
%%   snapshot(State) -> map()
%% "Reports", "Order", "Ingest", "Window" and "Tick"; samples are
%% quality_samples', measures quality_measures', rules and forwarding
%% quality_rules'. The frame and the filter are correlate.md's (model_frame,
%% model_kalman) as quality.md "Frame and filter" cites them; the time keys
%% model_report:time_keys/2's. State is a value.
-module(quality).
-behaviour(io_engine).
-export([load_pack/1, load_pack/2, new/1, ingest/2, tick/2, snapshot/1]).

-import(quality_samples, [sample/5, take/5]).
-import(trace_log, [emit/2]).

load_pack(Dir) -> load_pack(Dir, #{}).

%% Extensions: #{measures => [Measure]} (quality_measures).
load_pack(Dir, Extensions) -> quality_pack:load_pack(Dir, Extensions).

new(Pack) ->
    (trace_log:fields())#{pack => Pack, ref => null, last_tick => null, entities => #{},
                          rules => quality_rules:new(Pack)}.

snapshot(St) -> snapshot_quality:snapshot(St).

%% ---------------------------------------------------------------- reports

%% An optional key's value, or null when absent, null or of the wrong type.
optional(Key, Type, Report) ->
    V = maps:get(Key, Report, null),
    case model_report:typed(Type, V) of
        true -> V;
        false -> null
    end.

%% ---------------------------------------------------------------- ingest

%% Ingest: check the required keys (reject ends it); set the reference; find
%% the order; build the input clock and the source latest; take the samples;
%% create or update the entity; append the record; emit pass.
ingest(Report, St) ->
    case model_report:first_missing(Report) of
        none -> trace_log:finish(accept(Report, St));
        Missing ->
            trace_log:finish(emit(trace_quality:reject(model_report:missing_reason(Missing)), St))
    end.

accept(Report, St0) ->
    #{pack := Pack} = St0,
    F = maps:get(filter, Pack),
    Key = model_report:entity_key(Report),
    T = maps:get(<<"time_ms">>, Report),
    Lat = maps:get(<<"lat">>, Report),
    Lon = maps:get(<<"lon">>, Report),
    Ce = optional(<<"ce">>, positive, Report),
    Course = optional(<<"course">>, number, Report),
    Speed = optional(<<"speed_ms">>, number, Report),
    Hae = optional(<<"hae">>, number, Report),
    Received = optional(<<"received_ms">>, integer, Report),
    MeasCe = case Ce of null -> maps:get(<<"default_ce_m">>, F); _ -> Ce end,
    Vel = model_frame:velocity(Course, Speed),

    %% Frame and filter: the first accepted report sets the reference.
    St1 = case maps:get(ref, St0) of
              null -> St0#{ref := {Lat, Lon}};
              _ -> St0
          end,
    {E, N} = Z = model_frame:to_plane(maps:get(ref, St1), Lat, Lon),

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
    Clock = quality_samples:input_clock(Source, maps:get(entities, St1)),
    SourceLatest = quality_samples:source_latest(Source, maps:get(entities, St1)),

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
        model_report:time_keys(Report, maps:get(time_default, Pack)),
    {TimeError, St6} = quality_samples:time_sample(Key, <<"time_error">>, ReportTe, DefaultTe, St5),
    {TimeState, St7} = quality_samples:time_sample(Key, <<"time_state">>, ReportState,
                                                   DefaultState, St6),
    SourceOrder = case SourceLatest of
                      none -> <<"in-order">>;
                      _ when T < SourceLatest -> <<"out-of-order">>;
                      _ -> <<"in-order">>
                  end,
    St8 = sample(Key, <<"source_order">>, SourceOrder,
                 [T, case SourceLatest of none -> null; _ -> SourceLatest end], St7),
    {Nis, St9} =
        case Advance of
            true -> quality_samples:nis(Key, maps:get(filter, element(2, Existing)),
                                        (T - Last) / 1000, Z, MeasCe, F, St8);
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
                   last_pos => Z, filter => model_kalman:init(Z, Vel, MeasCe, F),
                   window => []},
                 emit(trace_quality:new(Key), St10)};
            {ok, Old = #{filter := Filter}} when Advance ->
                {Old#{last := T, last_pos := Z,
                      filter := element(1, model_kalman:update(Filter, (T - Last) / 1000,
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
    emit(quality_rules:pass(Key, Source, Report, Ce, St12), St12).

%% ---------------------------------------------------------------- tick

tick(Now, St = #{last_tick := Prev}) when Prev =/= null, Now < Prev ->
    %% Step 1, order.
    trace_log:finish(emit(trace_quality:reject(<<"tick-out-of-order">>), St));
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
    trace_log:finish(St5).

%% The sources that have entities, in key order.
sources(#{entities := Es}) ->
    lists:usort([Src || _ := #{source := Src} <- Es]).

%% Step 2, forget entities: now - last > forget_ms.
forget_entity(Key, Now, St) ->
    #{pack := #{forget_ms := Forget}, entities := Es} = St,
    #{last := Last} = maps:get(Key, Es),
    case Now - Last > Forget of
        true ->
            St1 = quality_rules:forget_subject(entity, Key, St),
            emit(trace_quality:forget_entity(Key), St1#{entities := maps:remove(Key, Es)});
        false -> St
    end.

%% Step 3, forget sources: had entities at the start of the tick, none now.
forget_source(Src, St) ->
    emit(trace_quality:forget_source(Src), quality_rules:forget_subject(source, Src, St)).

%% Step 4, window: drop the records with wt <= now - window_ms.
drop_old(Edge, St = #{entities := Es}) ->
    St#{entities := maps:map(fun(_, E = #{window := W}) ->
                                     E#{window := [R || R = #{<<"wt">> := Wt} <- W, Wt > Edge]}
                             end, Es)}.

%% Step 5, entities in key order: measures, quality event, entity rules.
entities_step([], _Now, Acc, St) -> {Acc, St};
entities_step([Key | Keys], Now, Acc, St0) ->
    #{pack := #{measures := Table, min_samples := K}} = St0,
    Ms = quality_measures:entity(Table, maps:get(Key, maps:get(entities, St0)), Now, K),
    St1 = emit(trace_quality:quality(<<"entity">>, Key, Ms), St0),
    St2 = quality_rules:evaluate(entity, Key, Ms, St1),
    entities_step(Keys, Now, Acc#{Key => Ms}, St2).

%% Step 6, one source: measures over its entities in key order, quality
%% event, source rules.
source_step(Src, Keys, EntityMeasures, St0) ->
    Mine = [maps:get(K, EntityMeasures) || K <- Keys,
                                           maps:get(source, maps:get(K, maps:get(entities, St0)))
                                               =:= Src],
    Ms = quality_measures:source(maps:get(measures, maps:get(pack, St0)), Mine),
    St1 = emit(trace_quality:quality(<<"source">>, Src, Ms), St0),
    quality_rules:evaluate(source, Src, Ms, St1).
