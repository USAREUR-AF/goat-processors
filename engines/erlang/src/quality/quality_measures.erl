%% Entity measures and source measures (quality.md "Entity measures",
%% "Source measures"): the table of measures, the registration point of a
%% measure. A measure is {Name, Entity, Source}:
%%   Entity  fun((Ctx) -> Value) of an entity's window, Ctx being
%%           #{window => [Record], now, last, min_samples}, or none for a
%%           source-only measure;
%%   Source  how a source aggregates its entities' values: sum, mean, max,
%%           min, min_all (every entity has one), or entities.
%% A pack loaded with quality:load_pack(Dir, #{measures => [Measure]}) also
%% has the extra measures, for that pack only. Adding a measure is one entry
%% in builtin/0. Pure.
-module(quality_measures).
-export([builtin/0, table/1, entity_names/1, source_names/1, entity/4, source/2]).

builtin() ->
    [{<<"reports">>, fun(#{window := W}) -> length(W) end, sum},
     {<<"interval_last">>, stat(<<"interval">>, fun lists:last/1), mean},
     {<<"interval_mean">>, stat(<<"interval">>, fun mean/1), mean},
     {<<"interval_max">>, stat(<<"interval">>, fun lists:max/1), max},
     {<<"age">>, fun(#{now := Now, last := Last}) -> Now - Last end, min_all},
     {<<"latency_mean">>, stat(<<"latency">>, fun mean/1), mean},
     {<<"latency_max">>, stat(<<"latency">>, fun lists:max/1), max},
     {<<"lateness_mean">>, stat(<<"lateness">>, fun mean/1), mean},
     {<<"lateness_max">>, stat(<<"lateness">>, fun lists:max/1), max},
     {<<"lateness_min">>, stat(<<"lateness">>, fun lists:min/1), min},
     {<<"nis_mean">>, stat(<<"nis">>, fun mean/1), mean},
     {<<"speed_err_mean">>, stat(<<"speed_err">>, fun mean/1), mean},
     {<<"out_of_order">>, order_count(<<"out-of-order">>), sum},
     {<<"duplicate">>, order_count(<<"duplicate">>), sum},
     {<<"source_out_of_order">>,
      fun(#{window := W}) -> length([R || R = #{<<"source_out_of_order">> := true} <- W]) end, sum},
     {<<"missing_ce">>, missing(<<"ce">>, false), mean},
     {<<"missing_vel">>, missing(<<"vel">>, false), mean},
     {<<"missing_hae">>, missing(<<"hae">>, false), mean},
     {<<"time_error_mean">>, stat(<<"time_error">>, fun mean/1), mean},
     {<<"time_error_max">>, stat(<<"time_error">>, fun lists:max/1), max},
     {<<"time_state_last">>,
      stat(<<"time_state">>, fun(Ss) -> state_code(lists:last(Ss)) end), max},
     {<<"time_state_worst">>,
      stat(<<"time_state">>, fun(Ss) -> lists:max([state_code(S) || S <- Ss]) end), max},
     {<<"missing_time">>, missing(<<"time_state">>, null), mean},
     {<<"entities">>, none, entities}].

table(Extra) -> builtin() ++ Extra.

entity_names(Table) -> [N || {N, E, _} <- Table, E =/= none].
source_names(Table) -> [N || {N, _, _} <- Table].

%% A statistic of a sample's values in the window: null with fewer than
%% min_samples values.
stat(Sample, Fun) ->
    fun(#{window := W, min_samples := K}) ->
            case [V || #{Sample := V} <- W, V =/= null] of
                Vs when length(Vs) >= K -> Fun(Vs);
                _ -> null
            end
    end.

order_count(Order) ->
    fun(#{window := W}) -> length([R || R = #{<<"order">> := O} <- W, O =:= Order]) end.

%% The share of the window's records whose Flag is Absent; null with fewer
%% than min_samples records.
missing(Flag, Absent) ->
    fun(#{window := W, min_samples := K}) ->
            Reports = length(W),
            case Reports < K of
                true -> null;
                false -> length([R || R = #{Flag := F} <- W, F =:= Absent]) / Reports
            end
    end.

%% Time quality: the code of a time state; higher is worse.
state_code(<<"coherent">>) -> 0;
state_code(<<"drifting">>) -> 1;
state_code(<<"free-running">>) -> 2.

%% A mean is s / n, s starting at 0.0 and adding each value in order.
mean(Vs) -> lists:foldl(fun(V, S) -> S + V end, 0.0, Vs) / length(Vs).

%% An entity's measures over its window W at Now with min_samples K.
entity(Table, #{window := W, last := Last}, Now, K) ->
    Ctx = #{window => W, now => Now, last => Last, min_samples => K},
    maps:from_list([{N, E(Ctx)} || {N, E, _} <- Table, E =/= none]).

%% A source's measures: its entities' measures aggregated, taken in key order.
source(Table, Mine) ->
    Present = fun(M) -> [V || #{M := V} <- Mine, V =/= null] end,
    Agg = fun(M, Fun) ->
                  case Present(M) of
                      [] -> null;
                      Vs -> Fun(Vs)
                  end
          end,
    maps:from_list(
      [{N, case How of
               sum -> lists:sum(Present(N));
               mean -> Agg(N, fun mean/1);
               max -> Agg(N, fun lists:max/1);
               min -> Agg(N, fun lists:min/1);
               min_all -> lists:min(Present(N));
               entities -> length(Mine)
           end} || {N, _, How} <- Table]).
