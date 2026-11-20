%% Pack: load and parse pack.def (correlate.md 0.8 "Pack"; a method's own
%% directives are its module's, correlate-assign.md 0.6 "Pack" for assign).
%%
%% A parsed pack holds method => Module (correlate_methods), tests => the
%% test kind table, filter, maneuver, restart, time_default, gate, stale_ms,
%% and the method's own keys.
-module(correlate_pack).
-export([load_pack/2, parse/1, parse/2]).
%% Shared with the method modules: tests, parameters and numbers.
-export([test/3, params/2, number_params/1, number/1, integer/1]).
%% Shared with quality_pack (quality.md "Pack", time_default).
-export([time_default_line/3]).

-import(io_pack, [fail/1]).

%% Directives both methods share: {Required, Repeating, Once}.
-define(SHARED, {[<<"pack">>, <<"version">>, <<"filter">>, <<"stale_ms">>],
                 [<<"gate">>, <<"time_default">>],
                 [<<"pack">>, <<"version">>, <<"method">>, <<"filter">>, <<"maneuver">>,
                  <<"restart">>, <<"stale_ms">>]}).
-define(FILTER_PARAMS, [<<"accel_var">>, <<"default_ce_m">>, <<"vel_sigma_ms">>,
                        <<"unknown_vel_ms">>]).
-define(MANEUVER_PARAMS, [<<"accel_var">>, <<"p_enter">>, <<"p_leave">>]).
-define(RESTART_PARAMS, [<<"gate">>]).
%% Reports, "Time quality": the three clock states.
-define(TIME_STATES, [<<"coherent">>, <<"drifting">>, <<"free-running">>]).

load_pack(Dir, Extensions) -> io_pack:read(Dir, fun(Text) -> parse(Text, Extensions) end).

parse(Text) -> parse(Text, #{}).

%% Extensions: #{methods => #{Name => Module}, tests => #{Name => Kind}}.
parse(Text, Extensions) ->
    io_pack:catching(fun() -> build(io_pack:words(Text), Extensions) end).

build(Directives, Extensions) ->
    Names = [N || [N | _] <- Directives],
    Methods = correlate_methods:table(maps:get(methods, Extensions, #{})),
    Tests = correlate_test_kinds:table(maps:get(tests, Extensions, #{})),
    %% method: optional, defaults to confirm; any other value is a load error.
    Method = case [D || D = [<<"method">> | _] <- Directives] of
                 [] -> maps:get(correlate_methods:default(), Methods);
                 [[_, Name] | _] when is_map_key(Name, Methods) -> maps:get(Name, Methods);
                 [D | _] -> fail({bad_method, D})
             end,
    {Required0, Repeating0, Once0} = ?SHARED,
    {Required1, Repeating1, Once1} = Method:directives(),
    Required = Required0 ++ Required1,
    Allowed = Once0 ++ Once1 ++ Repeating0 ++ Repeating1,
    [fail({unknown_directive, N}) || N <- Names, not lists:member(N, Allowed)],
    [fail({repeated, N}) || N <- Once0 ++ Once1, count(N, Names) > 1],
    [fail({missing, N}) || N <- Required, count(N, Names) =:= 0],
    Base = maps:merge(#{method => Method, tests => Tests, gate => [], time_default => #{}},
                      Method:defaults()),
    P = lists:foldl(fun(D, Acc) -> directive(D, Acc) end, Base, Directives),
    check_ranges(P),
    Method:check(P),
    Method:finish_pack(P#{gate := lists:reverse(maps:get(gate, P))}).

count(N, Names) -> length([X || X <- Names, X =:= N]).

directive([<<"pack">>, Name], P) -> P#{name => Name};
directive([<<"version">>, V], P) -> P#{version => V};
directive([<<"method">>, _], P) -> P;
directive([<<"filter">> | Params], P) ->
    P#{filter => number_params(params(Params, ?FILTER_PARAMS))};
directive([<<"maneuver">> | Params], P) ->
    P#{maneuver => number_params(params(Params, ?MANEUVER_PARAMS))};
directive([<<"restart">> | Params], P) ->
    P#{restart => number_params(params(Params, ?RESTART_PARAMS))};
directive([<<"time_default">> | Rest], P) ->
    P#{time_default := time_default_line(Rest, maps:get(time_default, P), fun number/1)};
directive([<<"gate">>, Test | Params], P = #{tests := Tests}) ->
    P#{gate := [test(Test, Params, Tests) | maps:get(gate, P)]};
directive([<<"stale_ms">>, N], P) -> P#{stale_ms => integer(N)};
directive(D, P = #{method := Method}) ->
    case Method:directive(D, P) of
        unknown -> fail({bad_directive, D});
        P1 -> P1
    end.

%% Ranges both methods share, checked once the whole file is read: filter
%% and maneuver, restart (correlate.md "Pack").
check_ranges(P) ->
    F = maps:get(filter, P),
    [fail({not_above_zero, K}) || K <- [default_ce_m, vel_sigma_ms, unknown_vel_ms],
                                  not (maps:get(atom_to_binary(K), F) > 0)],
    maps:get(<<"accel_var">>, F) >= 0 orelse fail({below_zero, accel_var}),
    case P of
        #{maneuver := #{<<"accel_var">> := Q2, <<"p_enter">> := A, <<"p_leave">> := B}} ->
            A > 0 orelse fail({not_above_zero, p_enter}),
            B > 0 orelse fail({not_above_zero, p_leave}),
            A + B < 1 orelse fail({not_below_one, switching}),
            Q2 > maps:get(<<"accel_var">>, F) orelse fail({not_above_filter, accel_var});
        _ -> ok
    end,
    case P of
        #{restart := #{<<"gate">> := RG}} -> RG > 0 orelse fail({not_above_zero, restart_gate});
        _ -> ok
    end,
    ok.

%% time_default <source_id> error_ms=<ms> state=<state> (correlate.md "Pack"),
%% shared with quality_pack (quality.md "Pack": the same grammar, with
%% quality's own number grammar): the source id is a first token without
%% "=", then error_ms, state or both, each at most once; error_ms a number
%% (read by Number) 0 or above, state one of the three clock states. At most
%% one line per source. Returns Defaults with the line added, Defaults being
%% #{Source => #{<<"error_ms">> => Ms, <<"state">> => State}},
%% holding only the keys the line gives.
time_default_line([Source | Tokens], Defaults, Number) ->
    binary:match(Source, <<"=">>) =:= nomatch orelse fail({time_default_no_source, Source}),
    maps:is_key(Source, Defaults) andalso fail({time_default_repeated, Source}),
    Given = params(Tokens, [K || {K, _} <- params_given(Tokens)]),
    map_size(Given) > 0 orelse fail({time_default_no_params, Source}),
    Default = maps:map(fun(<<"error_ms">>, V) ->
                               Ms = Number(V),
                               Ms >= 0 orelse fail({below_zero, error_ms}),
                               Ms;
                          (<<"state">>, V) ->
                               lists:member(V, ?TIME_STATES) orelse fail({bad_state, V}),
                               V;
                          (K, _) -> fail({time_default_param, K})
                       end, Given),
    Defaults#{Source => Default};
time_default_line([], _Defaults, _Number) -> fail(time_default_no_source).

%% The name=value pairs of Tokens, for a line whose parameters are each optional.
params_given(Tokens) ->
    [case binary:split(T, <<"=">>) of
         [K, V] -> {K, V};
         _ -> fail({bad_param, T})
     end || T <- Tokens].

%% Tests table (correlate_test_kinds): the kind's parameters, exactly; its
%% values numbers or text.
test(Name, Params, Tests) ->
    case maps:find(Name, Tests) of
        {ok, #{params := Wanted, values := number}} ->
            {Name, number_params(params(Params, Wanted))};
        {ok, #{params := Wanted, values := text}} ->
            {Name, params(Params, Wanted)};
        error -> fail({unknown_test, Name})
    end.

%% name=value parameters: no repeats, no unknown, none missing.
params(Tokens, Wanted) ->
    Pairs = [case binary:split(T, <<"=">>) of
                 [K, V] when K =/= <<>>, V =/= <<>> -> {K, V};
                 _ -> fail({bad_param, T})
             end || T <- Tokens],
    Keys = [K || {K, _} <- Pairs],
    length(lists:usort(Keys)) =:= length(Keys) orelse fail({repeated_param, Keys}),
    lists:sort(Keys) =:= lists:sort(Wanted) orelse fail({params, Keys, Wanted}),
    maps:from_list(Pairs).

number_params(M) -> maps:map(fun(_, V) -> number(V) end, M).

integer(B) ->
    case re:run(B, <<"^[+-]?[0-9]+$">>) of
        {match, _} -> binary_to_integer(B);
        nomatch -> fail({not_an_integer, B})
    end.

%% Numbers are decimal.
number(B) ->
    case re:run(B, <<"^[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?$">>) of
        {match, _} ->
            try binary_to_integer(B)
            catch error:badarg -> to_float(B)
            end;
        nomatch -> fail({not_a_number, B})
    end.

to_float(B) ->
    S = string:lowercase(binary_to_list(B)),
    {Mant, Exp} = case string:split(S, "e") of
                      [M, E] -> {M, E};
                      [M] -> {M, "0"}
                  end,
    {Sign, Unsigned} = case Mant of
                           [$- | R] -> {"-", R};
                           [$+ | R] -> {"", R};
                           _ -> {"", Mant}
                       end,
    {Int, Frac} = case string:split(Unsigned, ".") of
                      [I, F] -> {I, F};
                      [I] -> {I, ""}
                  end,
    finite(fun() -> list_to_float(Sign ++ default0(Int) ++ "." ++ default0(Frac) ++ "e" ++ Exp) end, B).

%% A number whose nearest binary64 is infinite is a load error: OTP has no
%% infinite float (DISAGREEMENTS.md).
finite(Read, B) ->
    try Read()
    catch error:badarg -> fail({not_finite, B})
    end.

default0("") -> "0";
default0(S) -> S.
