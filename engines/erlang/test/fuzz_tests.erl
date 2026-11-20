%% Fuzzing of the input parsers, with a seeded generator written here (no
%% third-party package): the JSON reader of a steps file (io_runner), each
%% function's pack.def parser, and each function's ingest of a decoded
%% report. Each target gets test_support:budget() inputs (1500 by default,
%% GOAT_FUZZ_ITERATIONS to change it), so the run time in CI is bounded.
%% The property: a parser returns {ok, _} or {error, _} and never raises;
%% ingest returns {Events, Trace, State} and never raises.
-module(fuzz_tests).
-include_lib("eunit/include/eunit.hrl").

-define(SEED, 20261120).

%% ---------------------------------------------------------------- JSON reader

json_reader_test_() ->
    {timeout, 300, fun() ->
        Texts = [element(2, file:read_file(F))
                 || {_, _, _, F} <- lists:sublist(test_support:scenarios(), 20)],
        loop(test_support:budget(), test_support:rand_state(?SEED),
             fun(S0) ->
                     {Text, S1} = test_support:pick(Texts, S0),
                     {Bad, S2} = mutate_bytes(Text, S1),
                     check_parser(fun io_runner:parse_steps/1, Bad),
                     S2
             end)
    end}.

%% ---------------------------------------------------------------- pack.def

pack_def_test_() ->
    [{binary_to_list(Fn), {timeout, 300, fun() -> fuzz_pack(Fn) end}}
     || Fn <- [<<"correlate">>, <<"filter">>, <<"fuse">>, <<"quality">>]].

fuzz_pack(Fn) ->
    Texts = [element(2, file:read_file(filename:join(D, "pack.def")))
             || D <- test_support:pack_dirs(Fn)],
    Parse = io_engine:pack_parser(Fn),
    loop(test_support:budget(), test_support:rand_state(?SEED),
         fun(S0) ->
                 {Text, S1} = test_support:pick(Texts, S0),
                 {How, S2} = test_support:uniform(2, S1),
                 {Bad, S3} = case How of
                                 1 -> mutate_tokens(Text, S2);
                                 2 -> mutate_bytes(Text, S2)
                             end,
                 check_parser(Parse, Bad),
                 S3
         end).

check_parser(Parse, Text) ->
    Result = try Parse(Text)
             catch C:E:Stack -> {raised, C, E, hd(Stack)}
             end,
    case Result of
        {ok, _} -> ok;
        {error, _} -> ok;
        Other -> ?assertEqual({ok_or_error, Text}, {Other, Text})
    end.

%% Token mutations: replace a token by a generated one, drop, repeat or
%% swap lines.
mutate_tokens(Text, S0) ->
    Lines = binary:split(Text, <<"\n">>, [global]),
    {Op, S1} = test_support:uniform(4, S0),
    {I, S2} = test_support:uniform(length(Lines), S1),
    Line = lists:nth(I, Lines),
    case Op of
        1 ->
            Tokens = binary:split(Line, [<<" ">>, <<"=">>], [global]),
            {J, S3} = test_support:uniform(length(Tokens), S2),
            {New, S4} = token(S3),
            T2 = lists:sublist(Tokens, J - 1) ++ [New] ++ lists:nthtail(J, Tokens),
            {join(replace(Lines, I, join(T2, <<" ">>)), <<"\n">>), S4};
        2 -> {join(lists:sublist(Lines, I - 1) ++ lists:nthtail(I, Lines), <<"\n">>), S2};
        3 -> {join(lists:sublist(Lines, I) ++ [Line] ++ lists:nthtail(I, Lines), <<"\n">>), S2};
        4 ->
            {J, S3} = test_support:uniform(length(Lines), S2),
            Swapped = replace(replace(Lines, I, lists:nth(J, Lines)), J, Line),
            {join(Swapped, <<"\n">>), S3}
    end.

replace(List, I, X) -> lists:sublist(List, I - 1) ++ [X] ++ lists:nthtail(I, List).
join(Parts, Sep) -> iolist_to_binary(lists:join(Sep, Parts)).

%% A token from the grammars' edges: numbers of every form, huge and tiny
%% exponents, signs alone, names, "=", control characters, UTF-8.
token(S0) ->
    Pool = [<<"0">>, <<"-0">>, <<"+1">>, <<"1e999">>, <<"-1e999">>, <<"1e-999">>, <<".5">>,
            <<"5.">>, <<"1.5e3">>, <<"1E+2">>, <<"-">>, <<"+">>, <<".">>, <<"e">>,
            <<"99999999999999999999999">>, <<"9223372036854775808">>, <<"nan">>, <<"inf">>,
            <<"=">>, <<"a=b">>, <<"x==">>, <<"gate">>, <<"rule">>, <<"when">>, <<"not">>,
            <<"method">>, <<"assign">>, <<"confirm">>, <<"\t">>, <<"\r">>, <<0>>, <<127>>,
            <<"#">>, <<"é"/utf8>>, <<>>, <<"key=@env">>, <<"vertices=1,2;3,4;5,6">>,
            <<"in=a,,b">>, <<"min=2">>, <<"max=1">>, <<"scope=source">>, <<"factor=0.5">>,
            <<"1e400">>, <<"max=1e400">>, <<"limit=1e400">>, huge(), <<"max=", (huge())/binary>>,
            <<"accel_var=", (huge())/binary>>, <<"error_ms=", (huge())/binary>>],
    test_support:pick(Pool, S0).

%% A decimal number beyond binary64's range.
huge() -> list_to_binary(lists:duplicate(400, $9)).

%% Byte mutations: flip, insert, delete or truncate.
mutate_bytes(Text, S0) ->
    Size = max(byte_size(Text), 1),
    {Op, S1} = test_support:uniform(4, S0),
    {At0, S2} = test_support:uniform(Size, S1),
    At = min(At0 - 1, byte_size(Text)),
    {B, S3} = test_support:uniform(256, S2),
    Byte = B - 1,
    <<Pre:At/binary, Post/binary>> = Text,
    Out = case {Op, Post} of
              {1, <<_, Rest/binary>>} -> <<Pre/binary, Byte, Rest/binary>>;
              {2, _} -> <<Pre/binary, Byte, Post/binary>>;
              {3, <<_, Rest/binary>>} -> <<Pre/binary, Rest/binary>>;
              _ -> Pre
          end,
    {Out, S3}.

%% ---------------------------------------------------------------- reports

reports_test_() ->
    [{binary_to_list(Fn), {timeout, 300, fun() -> fuzz_reports(Fn) end}}
     || Fn <- [<<"correlate">>, <<"filter">>, <<"fuse">>, <<"quality">>]].

fuzz_reports(Fn) ->
    {ok, Mod} = io_engine:module(Fn),
    Engines = [test_support:load(Mod, D) || D <- test_support:pack_dirs(Fn)],
    loop(test_support:budget(), test_support:rand_state(?SEED),
         fun(S0) ->
                 {St0, S1} = test_support:pick(Engines, S0),
                 %% A first report sets the frame; then a generated one and a tick.
                 {Report, S2} = report(S1),
                 {_, _, St1} = Mod:ingest(base(0), St0),
                 {E, T, St2} = Mod:ingest(Report, St1),
                 ?assert(is_list(E) andalso is_list(T)),
                 {_, _, St3} = Mod:tick(2000, St2),
                 ?assert(is_map(Mod:snapshot(St3))),
                 S2
         end).

base(T) ->
    #{<<"track.source_id">> => <<"radar-1">>, <<"uid">> => <<"T1">>, <<"time_ms">> => T,
      <<"lat">> => 50.0, <<"lon">> => 8.0}.

%% A report with each key absent, null, of a wrong type, or of the right
%% type within the ranges a report can hold (a position on the earth away
%% from the poles, a speed below the speed of sound times ten).
report(S0) ->
    Keys = [{<<"track.source_id">>, string}, {<<"uid">>, string}, {<<"time_ms">>, time},
            {<<"lat">>, lat}, {<<"lon">>, lon}, {<<"hae">>, number}, {<<"ce">>, number},
            {<<"course">>, number}, {<<"speed_ms">>, speed}, {<<"type">>, type},
            {<<"stale_ms">>, time}, {<<"fuse.group">>, string}, {<<"received_ms">>, time},
            {<<"time_error_ms">>, number}, {<<"time_state">>, state},
            {<<"quality.marks">>, marks}, {<<"track.simulated">>, any}],
    lists:foldl(fun({K, Kind}, {R, S}) ->
                        {Choice, S1} = test_support:uniform(6, S),
                        case Choice of
                            1 -> {R, S1};
                            2 -> {R#{K => null}, S1};
                            3 -> {V, S2} = wrong(S1), {R#{K => V}, S2};
                            _ -> {V, S2} = value(Kind, S1), {R#{K => V}, S2}
                        end
                end, {#{}, S0}, Keys).

wrong(S) -> test_support:pick([true, false, [], #{}, <<"x">>, 1, 1.5, -3, [1, <<"a">>]], S).

value(string, S) -> test_support:pick([<<"radar-1">>, <<"adsb">>, <<"T1">>, <<"A7">>, <<>>], S);
value(time, S) -> {N, S1} = test_support:uniform(4000, S), {N - 1000, S1};
value(lat, S) -> num(-80, 80, S);
value(lon, S) -> num(-180, 180, S);
value(speed, S) -> num(0, 3000, S);
value(number, S) -> num(-1000, 1000, S);
value(type, S) -> test_support:pick([<<"a-f-A">>, <<"a-h-G-U">>, <<"a-n-S">>, <<"b">>, <<>>], S);
value(state, S) -> test_support:pick([<<"coherent">>, <<"drifting">>, <<"free-running">>,
                                      <<"Coherent">>], S);
value(marks, S) -> test_support:pick([[], [<<"m">>], [<<"m">>, 1]], S);
value(any, S) -> wrong(S).

num(Lo, Hi, S0) ->
    {U, S1} = rand:uniform_s(S0),
    {Lo + U * (Hi - Lo), S1}.

%% ---------------------------------------------------------------- loop

loop(0, _S, _F) -> ok;
loop(N, S, F) -> loop(N - 1, F(S), F).
