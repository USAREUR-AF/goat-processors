%% The correlator (spec/correlate.md 0.8): the entry point of both methods.
%%   load_pack(Dir[, Extensions]) -> {ok, Pack} | {error, Why}
%%   new(Pack) -> State
%%   ingest(Report, State) -> {Events, Trace, State}
%%   tick(NowMs, State) -> {Events, Trace, State}
%%   snapshot(State) -> map()
%% This module holds what both methods share: "Reports" (the checks and the
%% order of rejects) and accepting a report into its entity ("Frame", "Track
%% estimate", "Restart"). The pack's method line selects a method module
%% from correlate_methods; it decides association, the tick and the
%% snapshot. State is a value, never a global.
-module(correlate).
-behaviour(io_engine).
-export([load_pack/1, load_pack/2, new/1, ingest/2, tick/2, snapshot/1]).
%% Shared with the method modules.
-export([entity/2, put_entity/3, value/2, predict/3, add_timing/2, pair_view/3,
         is_stale/3]).

load_pack(Dir) -> load_pack(Dir, #{}).

%% Extensions: #{methods => #{Name => Module}, tests => #{Name => Kind}},
%% added to the built-in tables for this pack only (correlate_methods,
%% correlate_test_kinds).
load_pack(Dir, Extensions) -> correlate_pack:load_pack(Dir, Extensions).

new(Pack = #{method := Method}) ->
    maps:merge((trace_log:fields())#{pack => Pack, ref => none, entities => #{}},
               Method:new(Pack)).

tick(Now, St = #{pack := #{method := Method}}) -> Method:tick(Now, St).

snapshot(St = #{pack := #{method := Method}}) -> Method:snapshot(St).

%% ---------------------------------------------------------------- reports

%% Reports: reject missing keys in table order, then a retiring entity
%% (a method that retires entities keeps them in the state's retiring), then
%% out-of-order.
ingest(Report0, St) ->
    case model_report:validate(Report0) of
        {reject, Reason} ->
            trace_log:finish(trace_log:emit(trace_correlate:reject(Reason), St));
        {ok, Report} ->
            Key = model_report:entity_key(Report),
            T = maps:get(<<"time_ms">>, Report),
            Retiring = maps:is_key(Key, maps:get(retiring, St, #{})),
            case maps:find(Key, maps:get(entities, St)) of
                _ when Retiring ->
                    trace_log:finish(trace_log:emit(trace_correlate:reject(Key, <<"retiring">>), St));
                {ok, #{time := Last}} when T < Last ->
                    trace_log:finish(trace_log:emit(trace_correlate:reject(Key, <<"out-of-order">>), St));
                _ ->
                    trace_log:finish(accept(Key, Report, St))
            end
    end.

accept(Key, Report, St0) ->
    #{pack := Pack = #{method := Method}} = St0,
    Lat = maps:get(<<"lat">>, Report),
    Lon = maps:get(<<"lon">>, Report),
    T = maps:get(<<"time_ms">>, Report),
    %% Frame: the first accepted report sets the reference.
    St1 = case maps:get(ref, St0) of
              none -> St0#{ref := {Lat, Lon}};
              _ -> St0
          end,
    Z = model_frame:to_plane(maps:get(ref, St1), Lat, Lon),
    Ce = correlate_track:report_ce(Report, maps:get(filter, Pack)),
    Vel = model_frame:velocity(maps:get(<<"course">>, Report, null),
                               maps:get(<<"speed_ms">>, Report, null)),
    Found = maps:find(Key, maps:get(entities, St1)),
    %% Track estimate, Measurement variance: R = {r_east, r_north} and the
    %% timing variance, with its "time" filter record before any other.
    {Te, TimeState} = correlate_track:time_quality(Report, Pack),
    {R, Timing, StT} = correlate_track:measurement_variance(Key, Found, T, Vel, Ce, Te, St1),
    {Ent, St2} =
        case Found of
            error ->
                E0 = maps:merge((Method:entity_fields())#{source => maps:get(<<"track.source_id">>, Report)},
                                model_imm:init(Z, Vel, R, Pack)),
                {E0, trace_log:emit(trace_correlate:new(Key), StT)};
            {ok, E0 = #{time := Last}} ->
                case correlate_track:restart_test(Key, E0, T, Z, R, StT) of
                    {true, StR} ->
                        Dt = (T - Last) / 1000,
                        {Est, Records} = model_imm:update(E0, Dt, Z, Vel, R, Pack),
                        %% Two-model filter, Trace: four filter records first.
                        {maps:merge(E0, Est),
                         lists:foldl(fun({Test, Model, Value}, S) ->
                                             trace_log:record(trace_correlate:filter(Key, Test, Model, Value), S)
                                     end, StR, Records)};
                    {false, StR} ->
                        %% Restart: the filter starts again as on a first
                        %% report; key, the method's association state and
                        %% no new event. The method is told (method assign
                        %% marks the entity restarted until the next tick).
                        {maps:merge(E0, model_imm:init(Z, Vel, R, Pack)),
                         Method:restarted(Key, StR)}
                end
        end,
    %% The entity keeps its last report's ce, measurement variance R, time
    %% error and timing variance.
    Ent1 = Ent#{time => T, report => Report, ce => Ce, r => R, time_error => Te,
                time_state => TimeState, timing => Timing},
    Method:reported(Key, put_entity(Key, Ent1, St2)).

entity(Key, St) -> maps:get(Key, maps:get(entities, St)).
put_entity(Key, E, St = #{entities := Es}) -> St#{entities := Es#{Key => E}}.

%% Last-report value of a key, null when absent; "@env" from type.
value(<<"@env">>, Ent) ->
    model_report:type_element(env, maps:get(<<"type">>, maps:get(report, Ent), null));
value(K, Ent) -> maps:get(K, maps:get(report, Ent), null).

%% Prediction of an entity to time T (ms): a copy of its estimate.
predict(Ent, T, St) ->
    model_imm:predict(Ent, (T - maps:get(time, Ent)) / 1000, maps:get(pack, St)).

%% A prediction Pred of entity Ent compared with another entity: Ent's timing
%% variance added to pp on each axis.
add_timing(Pred, Ent) -> correlate_track:add_timing(Pred, maps:get(timing, Ent)).

%% Tests: A is the entity just reported, B predicted to A's time_ms, with B's
%% timing variance added to the predicted pp on each axis (Track estimate,
%% Measurement variance); then moved into A's frame by the method
%% (correlate-assign.md "Sensor bias"; the confirm method does not move).
pair_view(A, B, St = #{pack := #{method := Method}}) ->
    EA = entity(A, St),
    EB = entity(B, St),
    PredB = add_timing(predict(EB, maps:get(time, EA), St), EB),
    {EA, EB, Method:move(PredB, maps:get(source, EA), maps:get(source, EB), St)}.

%% Staleness, shared by both methods' tick.
is_stale(Ent, Now, St) ->
    ReportStale = value(<<"stale_ms">>, Ent),
    Now - maps:get(time, Ent) > maps:get(stale_ms, maps:get(pack, St))
        orelse (is_number(ReportStale) andalso Now >= ReportStale).
