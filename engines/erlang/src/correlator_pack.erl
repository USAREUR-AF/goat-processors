%% Pack: load and parse pack.def (correlate.md "Pack", correlate-assign.md "Pack").
-module(correlator_pack).
-export([load_pack/1, parse/1]).

%% Directives per method: {Required, Repeating, Once}. correlate.md "Pack" for
%% confirm; correlate-assign.md "Pack" for assign.
-define(CONFIRM, {[<<"pack">>, <<"version">>, <<"filter">>, <<"confirm_count">>,
                   <<"hold_failures">>, <<"stale_ms">>],
                  [<<"gate">>, <<"confirm">>, <<"hold">>, <<"priority">>],
                  [<<"pack">>, <<"version">>, <<"method">>, <<"filter">>, <<"confirm_count">>,
                   <<"hold_failures">>, <<"stale_ms">>, <<"same_source">>, <<"output">>]}).
-define(ASSIGN, {[<<"pack">>, <<"version">>, <<"method">>, <<"filter">>, <<"new_cost">>,
                  <<"keep_bonus">>, <<"stale_ms">>],
                 [<<"gate">>],
                 [<<"pack">>, <<"version">>, <<"method">>, <<"filter">>, <<"new_cost">>,
                  <<"keep_bonus">>, <<"stale_ms">>]}).
-define(FILTER_PARAMS, [<<"accel_var">>, <<"default_ce_m">>, <<"vel_sigma_ms">>,
                        <<"unknown_vel_ms">>]).

load_pack(Dir) ->
    case file:read_file(filename:join(Dir, "pack.def")) of
        {ok, Text} -> parse(Text);
        {error, R} -> {error, {read, R}}
    end.

parse(Text) ->
    try
        Lines = [split_line(L) || L <- binary:split(Text, [<<"\n">>], [global])],
        Directives = [D || D <- Lines, D =/= []],
        {ok, build(Directives)}
    catch
        throw:{pack_error, Why} -> {error, Why}
    end.

fail(Why) -> throw({pack_error, Why}).

%% "#" starts a comment; blank lines are ignored.
split_line(Line) ->
    [Code | _] = binary:split(Line, <<"#">>),
    binary:split(Code, [<<" ">>, <<"\t">>, <<"\r">>], [global, trim_all]).

build(Directives) ->
    Names = [N || [N | _] <- Directives],
    %% method: optional, defaults to confirm; any other value is a load error.
    Method = case [D || D = [<<"method">> | _] <- Directives] of
                 [] -> confirm;
                 [[_, <<"confirm">>] | _] -> confirm;
                 [[_, <<"assign">>] | _] -> assign;
                 [D | _] -> fail({bad_method, D})
             end,
    {Required, Repeating, Once} = case Method of
                                      confirm -> ?CONFIRM;
                                      assign -> ?ASSIGN
                                  end,
    [fail({unknown_directive, N}) || N <- Names,
                                     not lists:member(N, Once ++ Repeating)],
    [fail({repeated, N}) || N <- Once, count(N, Names) > 1],
    [fail({missing, N}) || N <- Required, count(N, Names) =:= 0],
    Base = case Method of
               confirm -> #{method => confirm, gate => [], confirm => [], hold => [],
                            priority => [], same_source => forbid, output => priority};
               assign -> #{method => assign, gate => []}
           end,
    P = lists:foldl(fun directive/2, Base, Directives),
    lists:foldl(fun(K, Acc) -> Acc#{K := lists:reverse(maps:get(K, Acc))} end, P,
                [K || K <- [gate, confirm, hold, priority], maps:is_key(K, P)]).

count(N, Names) -> length([X || X <- Names, X =:= N]).

directive([<<"pack">>, Name], P) -> P#{name => Name};
directive([<<"version">>, V], P) -> P#{version => V};
directive([<<"method">>, _], P) -> P;
directive([<<"new_cost">>, N], P) -> P#{new_cost => number(N)};
directive([<<"keep_bonus">>, N], P) -> P#{keep_bonus => number(N)};
directive([<<"filter">> | Params], P) ->
    P#{filter => number_params(params(Params, ?FILTER_PARAMS))};
directive([Stage, Test | Params], P)
  when Stage =:= <<"gate">>; Stage =:= <<"confirm">>; Stage =:= <<"hold">> ->
    Key = binary_to_atom(Stage),
    P#{Key := [test(Test, Params) | maps:get(Key, P)]};
directive([<<"confirm_count">>, N], P) -> P#{confirm_count => integer(N)};
directive([<<"hold_failures">>, N], P) -> P#{hold_failures => integer(N)};
directive([<<"stale_ms">>, N], P) -> P#{stale_ms => integer(N)};
directive([<<"same_source">>, <<"forbid">>], P) -> P#{same_source := forbid};
directive([<<"same_source">>, <<"allow">>], P) -> P#{same_source := allow};
directive([<<"output">>, <<"priority">>], P) -> P#{output := priority};
directive([<<"output">>, <<"latest">>], P) -> P#{output := latest};
directive([<<"priority">>, Source, N], P) ->
    P#{priority := [{Source, number(N)} | maps:get(priority, P)]};
directive(D, _) -> fail({bad_directive, D}).

%% Tests table: each test's parameters, exactly.
test_params(<<"distance">>) -> [<<"max_m">>];
test_params(<<"window">>) -> [<<"multiplier">>, <<"window_m">>, <<"err_min_m">>, <<"err_max_m">>];
test_params(<<"mahalanobis">>) -> [<<"gate">>];
test_params(<<"course">>) -> [<<"max_deg">>, <<"min_speed_ms">>];
test_params(<<"speed">>) -> [<<"max_pct">>, <<"min_speed_ms">>];
test_params(<<"altitude">>) -> [<<"max_m">>];
test_params(<<"same">>) -> [<<"key">>];
test_params(T) -> fail({unknown_test, T}).

test(<<"same">>, Params) ->
    {<<"same">>, params(Params, test_params(<<"same">>))};
test(Test, Params) ->
    {Test, number_params(params(Params, test_params(Test)))}.

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
    list_to_float(Sign ++ default0(Int) ++ "." ++ default0(Frac) ++ "e" ++ Exp).

default0("") -> "0";
default0(S) -> S.
