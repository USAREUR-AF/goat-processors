%% Fuse pack: load and parse pack.def (fuse.md "Pack").
-module(fuse_pack).
-export([load_pack/1, parse/1]).

-define(ONCE, [<<"pack">>, <<"version">>, <<"filter">>, <<"kinematics">>, <<"stale_ms">>]).
-define(REPEATING, [<<"attribute">>, <<"source">>]).
-define(FILTER_PARAMS, [<<"accel_var">>, <<"default_ce_m">>, <<"vel_sigma_ms">>,
                        <<"unknown_vel_ms">>]).
-define(METHODS, [<<"inverse_variance">>, <<"covariance_intersection">>, <<"best">>,
                  <<"priority">>, <<"latest">>]).
-define(RULES, [<<"priority">>, <<"latest">>, <<"majority">>, <<"max">>, <<"min">>]).

load_pack(Dir) ->
    case file:read_file(filename:join(Dir, "pack.def")) of
        {ok, Text} -> parse(Text);
        {error, R} -> {error, {read, R}}
    end.

%% Returns {ok, Pack} or {error, Why}. Pack is
%% #{name, version, filter => #{<<"accel_var">> => Q, ...}, kinematics => Method,
%%   attributes => [{Key, Rule}] (pack order), sources => [SourceId] (rank order),
%%   stale_ms => Ms}.
parse(Text) ->
    try
        Lines = [split_line(L) || L <- binary:split(Text, <<"\n">>, [global])],
        {ok, build([D || D <- Lines, D =/= []])}
    catch
        throw:{pack_error, Why} -> {error, Why}
    end.

fail(Why) -> throw({pack_error, Why}).

%% Lines: a CR at the end is removed; "#" starts a comment; the rest is split
%% on runs of spaces and tabs.
split_line(Line0) ->
    Line = case Line0 of
               <<L:(byte_size(Line0) - 1)/binary, "\r">> -> L;
               _ -> Line0
           end,
    [Code | _] = binary:split(Line, <<"#">>),
    binary:split(Code, [<<" ">>, <<"\t">>], [global, trim_all]).

%% Count rules: unknown directive, once-only missing or repeated.
build(Directives) ->
    Names = [N || [N | _] <- Directives],
    [fail({unknown_directive, N}) || N <- Names, not lists:member(N, ?ONCE ++ ?REPEATING)],
    [fail({count, N}) || N <- ?ONCE, count(N, Names) =/= 1],
    P = lists:foldl(fun directive/2, #{attributes => [], sources => []}, Directives),
    P#{attributes := lists:reverse(maps:get(attributes, P)),
       sources := lists:reverse(maps:get(sources, P))}.

count(N, Names) -> length([X || X <- Names, X =:= N]).

%% Each directive with exactly its number of values.
directive([<<"pack">>, Name], P) -> P#{name => Name};
directive([<<"version">>, V], P) -> P#{version => V};
directive([<<"filter">> | Tokens], P) ->
    F = maps:map(fun(_, V) -> number(V) end, params(Tokens, ?FILTER_PARAMS)),
    [fail({not_above_zero, K}) || K <- [<<"default_ce_m">>, <<"vel_sigma_ms">>,
                                        <<"unknown_vel_ms">>],
                                  not (maps:get(K, F) > 0)],
    maps:get(<<"accel_var">>, F) >= 0 orelse fail({below_zero, accel_var}),
    P#{filter => F};
directive([<<"kinematics">>, M], P) ->
    lists:member(M, ?METHODS) orelse fail({unknown_method, M}),
    P#{kinematics => binary_to_atom(M)};
directive([<<"stale_ms">>, N], P) -> P#{stale_ms => integer(N)};
directive([<<"attribute">>, Key | Tokens], P = #{attributes := As}) ->
    binary:match(Key, <<"=">>) =:= nomatch orelse fail({key_with_equals, Key}),
    lists:keymember(Key, 1, As) andalso fail({repeated_attribute, Key}),
    #{<<"rule">> := Rule} = params(Tokens, [<<"rule">>]),
    lists:member(Rule, ?RULES) orelse fail({unknown_rule, Rule}),
    P#{attributes := [{Key, binary_to_atom(Rule)} | As]};
directive([<<"source">>, S], P = #{sources := Ss}) ->
    lists:member(S, Ss) andalso fail({repeated_source, S}),
    P#{sources := [S | Ss]};
directive(D, _) -> fail({bad_values, D}).

%% name=value parameters: each has "=", none unknown, repeated or missing.
params(Tokens, Wanted) ->
    Pairs = [case binary:split(T, <<"=">>) of
                 [K, V] -> {K, V};
                 [_] -> fail({no_equals, T})
             end || T <- Tokens],
    Keys = [K || {K, _} <- Pairs],
    length(lists:usort(Keys)) =:= length(Keys) orelse fail({repeated_param, Keys}),
    lists:sort(Keys) =:= lists:sort(Wanted) orelse fail({params, Keys, Wanted}),
    maps:from_list(Pairs).

%% An integer is one or more digits.
integer(B) ->
    case re:run(B, <<"^[0-9]+$">>) of
        {match, _} -> binary_to_integer(B);
        nomatch -> fail({not_an_integer, B})
    end.

%% A number: optional "-", digits, optionally "." and digits, optionally "e"
%% or "E", an optional sign and digits.
number(B) ->
    Re = <<"^(-?[0-9]+)(?:\\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$">>,
    case re:run(B, Re, [{capture, all_but_first, list}]) of
        {match, [Int]} -> list_to_integer(Int);
        {match, [Int, Frac]} -> list_to_float(Int ++ "." ++ Frac);
        {match, [Int, Frac, Exp]} -> list_to_float(Int ++ "." ++ default0(Frac) ++ "e" ++ Exp);
        nomatch -> fail({not_a_number, B})
    end.

default0("") -> "0";
default0(S) -> S.
