%% Filter pack: load and parse pack.def (filter.md "Pack").
%%
%% A parsed pack is
%%   #{name, version, default => keep | drop, forget_ms => integer(),
%%     rules => [#{name, action => keep | drop, conditions => [Condition]}]}
%% and a condition is #{test => binary(), negated => boolean(), params => map(),
%% eval => fun}, with each parameter already converted to its value (Values
%% table) and eval the kind's function from filter_conditions:table/0.
-module(filter_pack).
-export([load_pack/1, parse/1, read_number/1]).

-import(io_pack, [fail/1]).

-define(INT64_MAX, 9223372036854775807).

load_pack(Dir) -> io_pack:read(Dir, fun parse/1).

parse(Text) -> io_pack:catching(fun() -> build(io_pack:words(Text)) end).

%% ---------------------------------------------------------------- directives

%% Required directives appear exactly once; rule and when may repeat.
build(Lines) ->
    Names = [N || [N | _] <- Lines],
    [fail({unknown_directive, N})
     || N <- Names,
        not lists:member(N, [<<"pack">>, <<"version">>, <<"default">>, <<"forget_ms">>,
                             <<"rule">>, <<"when">>])],
    [fail({count, N}) || N <- [<<"pack">>, <<"version">>, <<"default">>, <<"forget_ms">>],
                         length([X || X <- Names, X =:= N]) =/= 1],
    P = lists:foldl(fun directive/2, #{rules => []}, Lines),
    Rules = lists:reverse([finish_rule(R) || R <- maps:get(rules, P)]),
    RuleNames = [maps:get(name, R) || R <- Rules],
    length(lists:usort(RuleNames)) =:= length(RuleNames) orelse fail(repeated_rule),
    P#{rules := Rules}.

directive([<<"pack">>, Name], P) -> P#{name => Name};
directive([<<"version">>, V], P) -> P#{version => V};
directive([<<"default">>, A], P) -> P#{default => action(A)};
directive([<<"forget_ms">>, V], P) -> P#{forget_ms => positive_integer(V)};
directive([<<"rule">>, <<"default">>, _], _P) -> fail(rule_named_default);
directive([<<"rule">>, Name, A], P = #{rules := Rs}) ->
    P#{rules := [#{name => Name, action => action(A), conditions => []} | Rs]};
directive([<<"when">> | _], #{rules := []}) -> fail(when_before_rule);
directive([<<"when">> | Args], P = #{rules := [R | Rs]}) ->
    #{conditions := Cs} = R,
    P#{rules := [R#{conditions := [condition(Args) | Cs]} | Rs]};
directive(Line, _P) -> fail({bad_arguments, Line}).

action(<<"keep">>) -> keep;
action(<<"drop">>) -> drop;
action(A) -> fail({bad_action, A}).

%% A rule with no when line is a load error; conditions are kept in pack order.
finish_rule(#{conditions := []}) -> fail(rule_without_when);
finish_rule(R = #{conditions := Cs}) -> R#{conditions := lists:reverse(Cs)}.

%% ---------------------------------------------------------------- conditions

%% when [not] <condition> <param>=<value> ...
condition([<<"not">>, Test | Params]) -> condition(true, Test, Params);
condition([<<"not">>]) -> fail(not_alone);
condition([Test | Params]) -> condition(false, Test, Params);
condition([]) -> fail(empty_when).

condition(Negated, Test, ParamTokens) ->
    Raw = params(ParamTokens, #{}),
    Given = lists:sort(maps:keys(Raw)),
    {Sets, Eval} = case maps:find(Test, filter_conditions:table()) of
                       {ok, Kind} -> Kind;
                       error -> fail({unknown_condition, Test})
                   end,
    lists:member(Given, Sets) orelse fail({bad_parameters, Test, Given}),
    Params = maps:map(fun(Name, Text) -> value(Test, Name, Text) end, Raw),
    check_bounds(Params),
    #{test => Test, negated => Negated, params => Params, eval => Eval}.

%% name=value: the name is the text before the first "=", the value the rest.
params([], Acc) -> Acc;
params([Tok | Rest], Acc) ->
    case binary:split(Tok, <<"=">>) of
        [Name, Value] ->
            maps:is_key(Name, Acc) andalso fail({repeated_param, Name}),
            params(Rest, Acc#{Name => Value});
        [_] -> fail({param_without_equals, Tok})
    end.

%% Values: convert each parameter per its grammar and limits.
value(_, <<"lat">>, T) -> latitude(T);
value(_, <<"lon">>, T) -> longitude(T);
value(_, <<"radius_m">>, T) ->
    R = number(T),
    R >= 0 orelse fail({negative_radius, T}),
    R;
value(_, <<"min">>, T) -> number(T);
value(_, <<"max">>, T) -> number(T);
value(_, <<"min_ms">>, T) -> positive_integer(T);
value(_, <<"max_age_ms">>, T) -> integer(T);
value(_, <<"vertices">>, T) -> vertices(T);
value(_, <<"in">>, T) -> list(T);
value(_, _Name, <<>>) -> fail(empty_token);    % reference, name, eq
value(_, _Name, T) -> T.

%% min <= max when both are given.
check_bounds(#{<<"min">> := Min, <<"max">> := Max}) when Min > Max -> fail(min_above_max);
check_bounds(_) -> ok.

%% A pack number's binary64 value, or not_a_number (used by key form eq).
read_number(T) ->
    try number(T) catch throw:{pack_error, _} -> not_a_number end.

%% number: -?[0-9]+(\.[0-9]+)?, read as the nearest binary64.
number(T) ->
    case re:run(T, <<"^-?[0-9]+(\\.[0-9]+)?$">>, [{capture, all, list}]) of
        {match, [_, _Fraction]} -> binary_to_float(T);
        {match, [_]} -> binary_to_float(<<T/binary, ".0">>);
        nomatch -> fail({bad_number, T})
    end.

latitude(T) ->
    V = number(T),
    (V >= -90 andalso V =< 90) orelse fail({latitude_out_of_range, T}),
    V.

longitude(T) ->
    V = number(T),
    (V >= -180 andalso V =< 180) orelse fail({longitude_out_of_range, T}),
    V.

%% integer: [0-9]+, at most 9223372036854775807.
integer(T) ->
    case re:run(T, <<"^[0-9]+$">>) of
        {match, _} ->
            N = binary_to_integer(T),
            N =< ?INT64_MAX orelse fail({integer_too_large, T}),
            N;
        nomatch -> fail({bad_integer, T})
    end.

positive_integer(T) ->
    N = integer(T),
    N > 0 orelse fail({not_above_zero, T}),
    N.

%% vertices: <lat>,<lon>;... with at least three pairs; returned as [{Lat, Lon}].
vertices(T) ->
    Pairs = [case binary:split(P, <<",">>, [global]) of
                 [Lat, Lon] -> {latitude(Lat), longitude(Lon)};
                 _ -> fail({bad_vertex, P})
             end || P <- binary:split(T, <<";">>, [global])],
    length(Pairs) >= 3 orelse fail(too_few_vertices),
    Pairs.

%% in: one or more non-empty items separated by ",", kept in pack order.
list(T) ->
    Items = binary:split(T, <<",">>, [global]),
    [fail(empty_list_item) || <<>> <- Items],
    Items.
