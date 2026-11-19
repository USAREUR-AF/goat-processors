%% Quality pack: load and parse pack.def (quality.md "Pack").
-module(quality_pack).
-export([load_pack/1, parse/1, entity_measures/0, source_measures/0]).

%% quality.md "Entity measures" and "Source measures": the measures, in
%% table order. A source has every entity measure plus `entities`.
-define(ENTITY_MEASURES,
        [<<"reports">>, <<"interval_last">>, <<"interval_mean">>, <<"interval_max">>,
         <<"age">>, <<"latency_mean">>, <<"latency_max">>, <<"nis_mean">>,
         <<"speed_err_mean">>, <<"out_of_order">>, <<"duplicate">>, <<"missing_ce">>,
         <<"missing_vel">>, <<"missing_hae">>]).

entity_measures() -> ?ENTITY_MEASURES.
source_measures() -> ?ENTITY_MEASURES ++ [<<"entities">>].

-define(ONCE, [<<"pack">>, <<"version">>, <<"filter">>, <<"window">>]).
-define(FILTER_PARAMS, [<<"accel_var">>, <<"default_ce_m">>, <<"vel_sigma_ms">>,
                        <<"unknown_vel_ms">>]).
-define(WINDOW_PARAMS, [<<"window_ms">>, <<"min_samples">>, <<"forget_ms">>]).
-define(RULE_PARAMS, [<<"scope">>, <<"measure">>, <<"op">>, <<"limit">>, <<"for">>,
                      <<"clear">>, <<"action">>]).

load_pack(Dir) ->
    case file:read_file(filename:join(Dir, "pack.def")) of
        {ok, Text} -> parse(Text);
        {error, R} -> {error, {read, R}}
    end.

%% Returns {ok, Pack} or {error, Why}. Pack:
%% #{name, version, filter => #{<<"accel_var">> => float, ...},
%%   window_ms, min_samples, forget_ms, rules => [Rule] in pack order}.
parse(Text) ->
    try
        Lines = [tokens(L) || L <- binary:split(Text, [<<"\n">>], [global])],
        {ok, build([D || D <- Lines, D =/= []])}
    catch
        throw:{pack_error, Why} -> {error, Why}
    end.

fail(Why) -> throw({pack_error, Why}).

%% "#" starts a comment; tokens are separated by spaces or tabs.
tokens(Line) ->
    [Code | _] = binary:split(Line, <<"#">>),
    binary:split(Code, [<<" ">>, <<"\t">>], [global, trim_all]).

%% `pack`, `version`, `filter`, `window` required, once; `rule` repeats.
build(Directives) ->
    Names = [N || [N | _] <- Directives],
    [fail({unknown_directive, N}) || N <- Names, not lists:member(N, [<<"rule">> | ?ONCE])],
    [fail({repeated_or_missing, N}) || N <- ?ONCE, count(N, Names) =/= 1],
    P = lists:foldl(fun directive/2, #{rules => []}, Directives),
    P#{rules := lists:reverse(maps:get(rules, P))}.

count(N, Names) -> length([X || X <- Names, X =:= N]).

directive([<<"pack">>, Name], P) -> P#{name => Name};
directive([<<"version">>, V], P) -> P#{version => V};
directive([<<"filter">> | Ps], P) -> P#{filter => filter(params(Ps, ?FILTER_PARAMS, []))};
directive([<<"window">> | Ps], P) -> maps:merge(P, window(params(Ps, ?WINDOW_PARAMS, [])));
directive([<<"rule">> | Ts], P = #{rules := Rules}) -> P#{rules := [rule(Ts, Rules) | Rules]};
directive(D, _) -> fail({values, D}).

%% filter: numbers; accel_var >= 0, the others > 0.
filter(M) ->
    F = maps:map(fun(_, V) -> number(V) end, M),
    maps:get(<<"accel_var">>, F) >= 0 orelse fail(accel_var),
    [fail({not_above_zero, K}) || K <- tl(?FILTER_PARAMS), not (maps:get(K, F) > 0)],
    F.

%% window: integers, each at least 1.
window(M) ->
    maps:from_list([{binary_to_atom(K), at_least_one(integer(V))} || K := V <- M]).

at_least_one(N) when N >= 1 -> N;
at_least_one(N) -> fail({below_one, N}).

%% rule <name> scope= measure= op= limit= for= clear= action= [factor=]
rule([], _) -> fail(rule_without_name);
rule([Name | Ps], Earlier) ->
    re:run(Name, <<"^[A-Za-z0-9._-]+$">>) =/= nomatch orelse fail({bad_name, Name}),
    [fail({repeated_name, Name}) || #{name := N} <- Earlier, N =:= Name],
    M = params(Ps, ?RULE_PARAMS, [<<"factor">>]),
    Scope = case maps:get(<<"scope">>, M) of
                <<"entity">> -> entity;
                <<"source">> -> source;
                S -> fail({bad_scope, S})
            end,
    Measure = maps:get(<<"measure">>, M),
    Measures = case Scope of entity -> ?ENTITY_MEASURES; source -> source_measures() end,
    lists:member(Measure, Measures) orelse fail({bad_measure, Measure}),
    Op = maps:get(<<"op">>, M),
    lists:member(Op, [<<"<">>, <<"<=">>, <<">">>, <<">=">>]) orelse fail({bad_op, Op}),
    Action = maps:get(<<"action">>, M),
    lists:member(Action, [<<"mark">>, <<"downgrade">>, <<"drop">>, <<"alert">>])
        orelse fail({bad_action, Action}),
    Limit = number(maps:get(<<"limit">>, M)),
    Clear = number(maps:get(<<"clear">>, M)),
    For = at_least_one(integer(maps:get(<<"for">>, M))),
    %% clear on the far side of limit from the condition.
    case Op of
        <<">", _/binary>> when Clear > Limit -> fail({clear_above_limit, Name});
        <<"<", _/binary>> when Clear < Limit -> fail({clear_below_limit, Name});
        _ -> ok
    end,
    Factor = case {Action, maps:find(<<"factor">>, M)} of
                 {<<"downgrade">>, error} -> fail({downgrade_without_factor, Name});
                 {<<"downgrade">>, {ok, FB}} ->
                     case number(FB) of
                         FN when FN >= 1 -> FN;
                         _ -> fail({factor_below_one, Name})
                     end;
                 {_, error} -> null;
                 {_, {ok, _}} -> fail({factor_with_other_action, Name})
             end,
    #{name => Name, scope => Scope, measure => Measure, op => Op, limit => Limit,
      for => For, clear => Clear, action => Action, factor => Factor}.

%% name=value parameters: each has "=", none repeated, none unknown, every
%% required one present.
params(Tokens, Required, Optional) ->
    Pairs = [case binary:split(T, <<"=">>) of
                 [K, V] -> {K, V};
                 [_] -> fail({param_without_equals, T})
             end || T <- Tokens],
    Keys = [K || {K, _} <- Pairs],
    length(lists:usort(Keys)) =:= length(Keys) orelse fail({repeated_param, Keys}),
    [fail({unknown_param, K}) || K <- Keys, not lists:member(K, Required ++ Optional)],
    [fail({missing_param, K}) || K <- Required, not lists:member(K, Keys)],
    maps:from_list(Pairs).

%% A number is -?[0-9]+(\.[0-9]+)?, read as the nearest binary64.
number(B) ->
    case re:run(B, <<"^-?[0-9]+(\\.[0-9]+)?$">>, [{capture, none}]) of
        match ->
            case binary:match(B, <<".">>) of
                nomatch -> binary_to_float(<<B/binary, ".0">>);
                _ -> binary_to_float(B)
            end;
        nomatch -> fail({not_a_number, B})
    end.

%% An integer is [0-9]+.
integer(B) ->
    case re:run(B, <<"^[0-9]+$">>, [{capture, none}]) of
        match -> binary_to_integer(B);
        nomatch -> fail({not_an_integer, B})
    end.
