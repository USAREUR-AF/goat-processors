%% Conditions (filter.md "Conditions"): the table of condition kinds, and
%% evaluating one condition with its negation. A kind is
%%   {ParameterSets, Eval}, Eval(Params, Ctx) -> {Result, Value, Limit},
%% Result true | false | unknown; ParameterSets the accepted sets of
%% parameter names, each sorted. Adding a condition kind is one entry in
%% table/0. Ctx is #{report, key, prior, entities}. Pure.
-module(filter_conditions).
-export([table/0, parameter_sets/1, evaluate/3]).
-export([circle/2, polygon/2, near/2, env/2, affiliation/2, source/2, uid/2, key/2, has/2,
         speed/2, altitude/2, interval/2, order/2]).

table() ->
    In = [[<<"in">>]],
    Range = [[<<"min">>], [<<"max">>], [<<"max">>, <<"min">>]],
    #{<<"circle">> => {[[<<"lat">>, <<"lon">>, <<"radius_m">>]], fun ?MODULE:circle/2},
      <<"polygon">> => {[[<<"vertices">>]], fun ?MODULE:polygon/2},
      <<"near">> => {[[<<"max_age_ms">>, <<"radius_m">>, <<"reference">>]], fun ?MODULE:near/2},
      <<"env">> => {In, fun ?MODULE:env/2},
      <<"affiliation">> => {In, fun ?MODULE:affiliation/2},
      <<"source">> => {In, fun ?MODULE:source/2},
      <<"uid">> => {In, fun ?MODULE:uid/2},
      <<"key">> => {[[<<"eq">>, <<"name">>], [<<"in">>, <<"name">>], [<<"min">>, <<"name">>],
                     [<<"max">>, <<"name">>], [<<"max">>, <<"min">>, <<"name">>]],
                    fun ?MODULE:key/2},
      <<"has">> => {[[<<"name">>]], fun ?MODULE:has/2},
      <<"speed">> => {Range, fun ?MODULE:speed/2},
      <<"altitude">> => {Range, fun ?MODULE:altitude/2},
      <<"interval">> => {[[<<"min_ms">>]], fun ?MODULE:interval/2},
      <<"order">> => {[[]], fun ?MODULE:order/2}}.

%% The parameter sets of a kind, or unknown.
parameter_sets(Test) ->
    case maps:find(Test, table()) of
        {ok, {Sets, _}} -> Sets;
        error -> unknown
    end.

%% One condition: its result (true | false | unknown), with value and limit,
%% then negation. Passes only when the negated result is true. Returns
%% {Record, Pass}.
evaluate(#{test := Test, negated := Negated, params := P, eval := Eval}, Rule, Ctx) ->
    {Result, Value, Limit} = Eval(P, Ctx),
    Final = case {Result, Negated} of
                {unknown, _} -> unknown;
                {R, false} -> R;
                {R, true} -> not R
            end,
    Pass = Final =:= true,
    {trace_filter:rule(Rule, maps:get(key, Ctx), Test, Negated, Value, Limit, Pass,
                       Result =:= unknown),
     Pass}.

%% ---------------------------------------------------------------- the kinds

circle(#{<<"lat">> := Lat, <<"lon">> := Lon, <<"radius_m">> := Radius}, #{report := R}) ->
    D = filter_geometry:distance(lat(R), lon(R), Lat, Lon),
    {D =< Radius, D, Radius}.

polygon(#{<<"vertices">> := Vs}, #{report := R}) ->
    Where = filter_geometry:polygon(Vs, lat(R), lon(R)),
    {Where =/= outside, atom_to_binary(Where), null}.

near(P, #{report := R, entities := Ents}) ->
    #{<<"reference">> := Ref, <<"radius_m">> := Radius, <<"max_age_ms">> := MaxAge} = P,
    T = maps:get(<<"time_ms">>, R),
    case maps:get(Ref, Ents, none) of
        none -> {unknown, null, Radius};
        RefEnt ->
            case reference_stale(RefEnt, T, MaxAge) of
                true -> {unknown, null, Radius};
                false ->
                    {PLat, PLon} = filter_geometry:predict(RefEnt, T),
                    D = filter_geometry:distance(lat(R), lon(R), PLat, PLon),
                    {D =< Radius, D, Radius}
            end
    end.

env(#{<<"in">> := List}, #{report := R}) ->
    in_list(model_report:type_element(env, maps:get(<<"type">>, R, null)), List).
affiliation(#{<<"in">> := List}, #{report := R}) ->
    in_list(model_report:type_element(affiliation, maps:get(<<"type">>, R, null)), List).
source(#{<<"in">> := List}, #{report := R}) ->
    in_list(maps:get(<<"track.source_id">>, R), List).
uid(#{<<"in">> := List}, #{report := R}) ->
    in_list(maps:get(<<"uid">>, R), List).

key(P = #{<<"name">> := Name}, #{report := R}) ->
    V = maps:get(Name, R, null),
    case P of
        #{<<"eq">> := Text} when V =:= null -> {unknown, null, Text};
        #{<<"eq">> := Text} -> {key_equal(V, Text), V, Text};
        #{<<"in">> := List} when V =:= null -> {unknown, null, List};
        #{<<"in">> := List} -> {lists:any(fun(T) -> key_equal(V, T) end, List), V, List};
        _ -> range(V, P)
    end.

has(#{<<"name">> := Name}, #{report := R}) ->
    Present = maps:is_key(Name, R),
    {Present, Present, null}.

speed(P, #{report := R}) -> range(maps:get(<<"speed_ms">>, R, null), P).
altitude(P, #{report := R}) -> range(maps:get(<<"hae">>, R, null), P).

%% interval: time_ms - kept_ms < min_ms; false when there is no kept report.
interval(#{<<"min_ms">> := Min}, #{report := R, prior := Prior}) ->
    case kept_ms(Prior) of
        null -> {false, null, Min};
        Kept ->
            V = maps:get(<<"time_ms">>, R) - Kept,
            {V < Min, V, Min}
    end.

%% order: time_ms < kept_ms; false when there is no kept report.
order(_P, #{report := R, prior := Prior}) ->
    T = maps:get(<<"time_ms">>, R),
    case kept_ms(Prior) of
        null -> {false, T, null};
        Kept -> {T < Kept, T, Kept}
    end.

lat(R) -> maps:get(<<"lat">>, R).
lon(R) -> maps:get(<<"lon">>, R).

kept_ms(none) -> null;
kept_ms(#{kept_ms := K}) -> K.

%% in lists compare strings byte for byte; unknown when the value is absent.
in_list(null, List) -> {unknown, null, List};
in_list(V, List) -> {lists:member(V, List), V, List}.

%% Ranges: inclusive, an omitted bound is null in limit and no bound; unknown
%% when the value is absent or not a number (true/false are not numbers).
range(V, P) ->
    Min = maps:get(<<"min">>, P, null),
    Max = maps:get(<<"max">>, P, null),
    Limit = [Min, Max],
    case is_number(V) of
        false -> {unknown, V, Limit};
        true -> {(Min =:= null orelse Min =< V) andalso (Max =:= null orelse V =< Max),
                 V, Limit}
    end.

%% key equality between the report's value V and a pack text T.
key_equal(V, T) when is_binary(V) -> V =:= T;
key_equal(V, T) when is_number(V) ->
    case filter_pack:read_number(T) of
        not_a_number -> false;
        F -> F == V
    end;
key_equal(true, T) -> T =:= <<"true">>;
key_equal(false, T) -> T =:= <<"false">>;
key_equal(_ArrayOrObject, _T) -> false.

%% near: stale when abs(time_ms - ref.time_ms) > max_age_ms, or when ref.stale_ms
%% is present and time_ms >= ref.stale_ms.
reference_stale(#{time_ms := RefT, stale_ms := RefStale}, T, MaxAge) ->
    abs(T - RefT) > MaxAge orelse (RefStale =/= null andalso T >= RefStale).
