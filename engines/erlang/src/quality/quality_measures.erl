%% Entity measures and source measures (quality.md "Entity measures",
%% "Source measures"): the table of measures, the registration point of a
%% measure. A measure is {Name, Entity, Source}:
%%   Entity  fun((Ctx) -> Value) of an entity's window, Ctx being
%%           #{window => [Record], now, last, min_samples, values, counts}
%%           (values: each sample's non-null values in window order;
%%           counts: the records of each order and each absent flag, both
%%           read from the window in one pass), or none for a source-only
%%           measure;
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
     {<<"out_of_order">>, count(out_of_order), sum},
     {<<"duplicate">>, count(duplicate), sum},
     {<<"source_out_of_order">>, count(source_out_of_order), sum},
     {<<"missing_ce">>, missing(ce), mean},
     {<<"missing_vel">>, missing(vel), mean},
     {<<"missing_hae">>, missing(hae), mean},
     {<<"time_error_mean">>, stat(<<"time_error">>, fun mean/1), mean},
     {<<"time_error_max">>, stat(<<"time_error">>, fun lists:max/1), max},
     {<<"time_state_last">>,
      stat(<<"time_state">>, fun(Ss) -> state_code(lists:last(Ss)) end), max},
     {<<"time_state_worst">>,
      stat(<<"time_state">>, fun(Ss) -> lists:max([state_code(S) || S <- Ss]) end), max},
     {<<"missing_time">>, missing(time), mean},
     {<<"entities">>, none, entities}].

table(Extra) -> builtin() ++ Extra.

entity_names(Table) -> [N || {N, E, _} <- Table, E =/= none].
source_names(Table) -> [N || {N, _, _} <- Table].

%% A statistic of a sample's values in the window: null with fewer than
%% min_samples values.
stat(Sample, Fun) ->
    fun(#{values := Values, min_samples := K}) ->
            case maps:get(Sample, Values) of
                Vs when length(Vs) >= K -> Fun(Vs);
                _ -> null
            end
    end.

count(What) -> fun(#{counts := Counts}) -> maps:get(What, Counts) end.

%% The share of the window's records whose flag is absent (ce, vel, hae
%% false; time state null); null with fewer than min_samples records.
missing(What) ->
    fun(#{window := W, min_samples := K, counts := Counts}) ->
            Reports = length(W),
            case Reports < K of
                true -> null;
                false -> maps:get(What, Counts) / Reports
            end
    end.

-define(SAMPLES, [<<"interval">>, <<"latency">>, <<"lateness">>, <<"nis">>, <<"speed_err">>,
                  <<"time_error">>, <<"time_state">>]).

%% One pass over the window: each sample's non-null values in window order,
%% and the counts. Pure.
read_window(W) ->
    {I, La, Lt, N, Se, Te, Ts, Ooo, Dup, Sooo, Ce, Vel, Hae, Time} =
        scan(W, {[], [], [], [], [], [], [], 0, 0, 0, 0, 0, 0, 0}),
    {#{<<"interval">> => lists:reverse(I), <<"latency">> => lists:reverse(La),
       <<"lateness">> => lists:reverse(Lt), <<"nis">> => lists:reverse(N),
       <<"speed_err">> => lists:reverse(Se), <<"time_error">> => lists:reverse(Te),
       <<"time_state">> => lists:reverse(Ts)},
     #{out_of_order => Ooo, duplicate => Dup, source_out_of_order => Sooo, ce => Ce, vel => Vel,
       hae => Hae, time => Time}}.

scan([], Acc) -> Acc;
scan([#{<<"interval">> := I, <<"latency">> := La, <<"lateness">> := Lt, <<"nis">> := N,
        <<"speed_err">> := Se, <<"time_error">> := Te, <<"time_state">> := Ts,
        <<"order">> := Order, <<"source_out_of_order">> := Sooo, <<"ce">> := Ce,
        <<"vel">> := Vel, <<"hae">> := Hae} | Rest],
     {AI, ALa, ALt, AN, ASe, ATe, ATs, AOoo, ADup, ASooo, ACe, AVel, AHae, ATime}) ->
    scan(Rest, {cons(I, AI), cons(La, ALa), cons(Lt, ALt), cons(N, AN), cons(Se, ASe),
                cons(Te, ATe), cons(Ts, ATs),
                AOoo + is(Order, <<"out-of-order">>), ADup + is(Order, <<"duplicate">>),
                ASooo + is(Sooo, true), ACe + is(Ce, false), AVel + is(Vel, false),
                AHae + is(Hae, false), ATime + is(Ts, null)}).

cons(null, L) -> L;
cons(V, L) -> [V | L].

is(X, X) -> 1;
is(_, _) -> 0.

%% Time quality: the code of a time state; higher is worse.
state_code(<<"coherent">>) -> 0;
state_code(<<"drifting">>) -> 1;
state_code(<<"free-running">>) -> 2.

%% A mean is s / n, s starting at 0.0 and adding each value in order.
mean(Vs) -> lists:foldl(fun(V, S) -> S + V end, 0.0, Vs) / length(Vs).

%% An entity's measures over its window W at Now with min_samples K.
entity(Table, #{window := W, last := Last}, Now, K) ->
    {Values, Counts} = read_window(W),
    Ctx = #{window => W, now => Now, last => Last, min_samples => K, values => Values,
            counts => Counts},
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
