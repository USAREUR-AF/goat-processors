%% Reports (correlate.md "Reports", "Time quality"), shared by every
%% function: the required and optional key tables, the reject reason, the
%% normalized report, the entity key, the time keys and the type elements.
%% Pure functions of a report.
-module(model_report).
-export([required/0, optional/0, typed/2, first_missing/1, missing_reason/1, validate/1,
         normalize/2, entity_key/1, time_keys/2, type_element/2, first_given/2]).

%% Required keys in table order with their type; optional keys with their
%% type. A key of the wrong type is missing (required) or absent (optional).
required() ->
    [{<<"track.source_id">>, string}, {<<"uid">>, string},
     {<<"time_ms">>, integer}, {<<"lat">>, number}, {<<"lon">>, number}].

optional() ->
    [{<<"hae">>, number}, {<<"ce">>, positive}, {<<"course">>, number},
     {<<"speed_ms">>, number}, {<<"type">>, string}, {<<"stale_ms">>, integer}].

%% A ce of 0 or below is absent; a boolean is an atom, never a number.
typed(positive, V) -> is_number(V) andalso V > 0;
typed(nonempty_string, V) -> is_binary(V) andalso V =/= <<>>;
typed(string, V) -> is_binary(V);
typed(integer, V) -> is_integer(V);
typed(number, V) -> is_number(V).

%% The first required key, in table order, that is missing or of the wrong
%% type, or none.
first_missing(Report) -> first_missing(required(), Report).

first_missing([], _Report) -> none;
first_missing([{K, Type} | Rest], Report) ->
    case typed(Type, maps:get(K, Report, null)) of
        true -> first_missing(Rest, Report);
        false -> K
    end.

missing_reason(Key) -> <<"missing:", Key/binary>>.

%% {reject, <<"missing:<key>">>} for the first missing required key;
%% otherwise {ok, Report} normalized with the optional table.
validate(Report) ->
    case first_missing(Report) of
        none -> {ok, normalize(Report, optional())};
        K -> {reject, missing_reason(K)}
    end.

%% Every null value removed (null is the same as absent), and every
%% optional key of Optional whose value is of the wrong type.
normalize(Report, Optional) ->
    maps:filter(fun(_K, null) -> false;
                   (K, V) ->
                        case lists:keyfind(K, 1, Optional) of
                            {K, Type} -> typed(Type, V);
                            false -> true
                        end
                end, Report).

entity_key(R) ->
    <<(maps:get(<<"track.source_id">>, R))/binary, "/", (maps:get(<<"uid">>, R))/binary>>.

%% Reports, "Time quality", steps 1 and 2 (shared with quality.md "Time
%% quality"): {{ReportError, DefaultError}, {ReportState, DefaultState}},
%% each null when not given. The report's value is its valid one:
%% time_error_ms a finite number 0 or above (JSON numbers decoded by OTP are
%% always finite), time_state one of the three states, byte for byte; any
%% other value is absent, never a reject. The default is the time_default
%% for the report's track.source_id, when it gives that key. Defaults is the
%% pack's #{Source => #{<<"error_ms">> => Ms, <<"state">> => State}}.
time_keys(Report, Defaults) ->
    Default = maps:get(maps:get(<<"track.source_id">>, Report), Defaults, #{}),
    ReportTe = case maps:get(<<"time_error_ms">>, Report, null) of
                   Ms when is_number(Ms), Ms >= 0 -> Ms;
                   _ -> null
               end,
    ReportState = case maps:get(<<"time_state">>, Report, null) of
                      S when S =:= <<"coherent">>; S =:= <<"drifting">>;
                             S =:= <<"free-running">> -> S;
                      _ -> null
                  end,
    {{ReportTe, maps:get(<<"error_ms">>, Default, null)},
     {ReportState, maps:get(<<"state">>, Default, null)}}.

%% Step 3: the first value that is not null, or Otherwise.
first_given([null | Rest], Otherwise) -> first_given(Rest, Otherwise);
first_given([V | _], _Otherwise) -> V;
first_given([], Otherwise) -> Otherwise.

%% The "-"-separated elements of a type: env is the third element; the
%% affiliation the second when the first is exactly "a". Returns the element
%% or null.
type_element(env, Type) when is_binary(Type) ->
    case binary:split(Type, <<"-">>, [global]) of
        [_, _, Env | _] -> Env;
        _ -> null
    end;
type_element(affiliation, Type) when is_binary(Type) ->
    case binary:split(Type, <<"-">>, [global]) of
        [<<"a">>, Aff | _] -> Aff;
        _ -> null
    end;
type_element(_, _) -> null.
