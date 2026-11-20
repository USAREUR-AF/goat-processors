%% Fuse pack: load and parse pack.def (fuse.md "Pack").
-module(fuse_pack).
-export([load_pack/1, parse/1]).

-define(ONCE, [<<"pack">>, <<"version">>, <<"filter">>, <<"kinematics">>, <<"stale_ms">>]).
-define(REPEATING, [<<"attribute">>, <<"source">>]).
-define(FILTER_PARAMS, [<<"accel_var">>, <<"default_ce_m">>, <<"vel_sigma_ms">>,
                        <<"unknown_vel_ms">>]).

-import(io_pack, [fail/1]).

load_pack(Dir) -> io_pack:read(Dir, fun parse/1).

%% Returns {ok, Pack} or {error, Why}. Pack is
%% #{name, version, filter => #{<<"accel_var">> => Q, ...}, kinematics => Method,
%%   attributes => [{Key, Rule}] (pack order), sources => [SourceId] (rank order),
%%   stale_ms => Ms}.
%% Lines (io_pack:words_strip_cr/1): a CR at the end is removed; "#" starts
%% a comment; the rest is split on runs of spaces and tabs.
parse(Text) -> io_pack:catching(fun() -> build(io_pack:words_strip_cr(Text)) end).

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
    P#{kinematics => named(M, fuse_kinematics:methods(), unknown_method)};
directive([<<"stale_ms">>, N], P) -> P#{stale_ms => integer(N)};
directive([<<"attribute">>, Key | Tokens], P = #{attributes := As}) ->
    binary:match(Key, <<"=">>) =:= nomatch orelse fail({key_with_equals, Key}),
    lists:keymember(Key, 1, As) andalso fail({repeated_attribute, Key}),
    #{<<"rule">> := Rule} = params(Tokens, [<<"rule">>]),
    P#{attributes := [{Key, named(Rule, fuse_attributes:rules(), unknown_rule)} | As]};
directive([<<"source">>, S], P = #{sources := Ss}) ->
    lists:member(S, Ss) andalso fail({repeated_source, S}),
    P#{sources := [S | Ss]};
directive(D, _) -> fail({bad_values, D}).

%% The key of Table (fuse_kinematics:methods/0, fuse_attributes:rules/0)
%% named by the token, byte for byte.
named(Token, Table, Why) ->
    case [K || K <- maps:keys(Table), atom_to_binary(K) =:= Token] of
        [K] -> K;
        [] -> fail({Why, Token})
    end.

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
        {match, [Int, Frac]} -> finite(Int ++ "." ++ Frac, B);
        {match, [Int, Frac, Exp]} -> finite(Int ++ "." ++ default0(Frac) ++ "e" ++ Exp, B);
        nomatch -> fail({not_a_number, B})
    end.

%% A number whose nearest binary64 is infinite is a load error: OTP has no
%% infinite float (DISAGREEMENTS.md).
finite(Text, B) ->
    try list_to_float(Text)
    catch error:badarg -> fail({not_finite, B})
    end.

default0("") -> "0";
default0(S) -> S.
