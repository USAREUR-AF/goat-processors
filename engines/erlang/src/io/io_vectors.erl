%% The vector runner (spec/vector-format.md): every scenario vector of a
%% function's packs (packs/<function>-*/vectors/) and every load vector
%% (spec/<function>-load-vectors/), with its structural comparison. Prints
%% PASS or FAIL per vector, the path of the first mismatch, a summary line,
%% and halts non-zero when any vector fails.
-module(io_vectors).
-export([main/2, results/2, read/1, steps/1, compare/3]).

main(Function, Root) ->
    Results = results(Function, Root),
    Failed = [R || R <- Results, R =/= ok],
    io:format("~s: ~b vectors, ~b passed, ~b failed~n",
              [Function, length(Results), length(Results) - length(Failed), length(Failed)]),
    halt(case Failed of [] -> 0; _ -> 1 end).

%% ok | fail per vector, scenario vectors then load vectors, each in file order.
results(Function, Root) ->
    {ok, Mod} = io_engine:module(Function),
    Scenarios = lists:sort(filelib:wildcard(
                             filename:join(Root, "packs/" ++ binary_to_list(Function)
                                           ++ "-*/vectors/*.json"))),
    Loads = lists:sort(filelib:wildcard(
                         filename:join(Root, "spec/" ++ binary_to_list(Function)
                                       ++ "-load-vectors/*.json"))),
    Parse = io_engine:pack_parser(Function),
    [scenario(Mod, Root, F) || F <- Scenarios] ++ [load(Parse, F) || F <- Loads].

read(File) ->
    {ok, Bin} = file:read_file(File),
    json:decode(Bin).

%% A steps list: {ingest, Report} or {tick, NowMs} per step.
steps(V) ->
    [case S of
         #{<<"ingest">> := R} -> {ingest, R};
         #{<<"tick">> := N} -> {tick, N}
     end || S <- maps:get(<<"steps">>, V)].

report(Name, ok) -> io:format("PASS ~ts~n", [Name]), ok;
report(Name, {mismatch, Path, Got, Want}) ->
    io:format("FAIL ~ts at ~s~n  got:  ~ts~n  want: ~ts~n",
              [Name, Path, json:encode(Got), json:encode(Want)]),
    fail.

%% Scenario vector: each step's events and trace, then the final snapshot.
scenario(Mod, Root, File) ->
    V = read(File),
    Pack = maps:get(<<"pack">>, V),
    {ok, P} = Mod:load_pack(filename:join([Root, "packs", Pack])),
    Name = <<Pack/binary, "/", (maps:get(<<"name">>, V))/binary>>,
    report(Name, check(Mod, maps:get(<<"steps">>, V), 0, Mod:new(P), V)).

check(Mod, [], _I, St, V) ->
    compare(Mod:snapshot(St), maps:get(<<"snapshot">>, V), "snapshot");
check(Mod, [Step | Rest], I, St0, V) ->
    S = case Step of
            #{<<"ingest">> := Report} -> {ingest, Report};
            #{<<"tick">> := Now} -> {tick, Now}
        end,
    {Events, Trace, St1} = io_engine:step(Mod, S, St0),
    P = lists:flatten(io_lib:format("steps[~b]", [I])),
    case compare(Events, maps:get(<<"expect">>, Step), P ++ ".expect") of
        ok ->
            case compare(Trace, maps:get(<<"trace">>, Step), P ++ ".trace") of
                ok -> check(Mod, Rest, I + 1, St1, V);
                M -> M
            end;
        M -> M
    end.

%% Load vector: parsing pack_def fails exactly when expect_error is true.
load(Parse, File) ->
    V = read(File),
    Got = case Parse(maps:get(<<"pack_def">>, V)) of
              {ok, _} -> false;
              {error, _} -> true
          end,
    report(<<"load/", (maps:get(<<"name">>, V))/binary>>,
           compare(Got, maps:get(<<"expect_error">>, V), "expect_error")).

%% Structural equality, numbers within 1e-6 * max(1, abs(want)).
compare(G, W, Path) when is_number(G), is_number(W) ->
    case abs(G - W) =< 1.0e-6 * max(1, abs(W)) of
        true -> ok;
        false -> {mismatch, Path, G, W}
    end;
compare(G, W, Path) when is_map(G), is_map(W) ->
    GK = lists:sort(maps:keys(G)),
    WK = lists:sort(maps:keys(W)),
    case GK =:= WK of
        false -> {mismatch, Path ++ " (keys)", GK, WK};
        true -> first([fun() -> compare(maps:get(K, G), maps:get(K, W), Path ++ "." ++ binary_to_list(K)) end
                       || K <- WK])
    end;
compare(G, W, Path) when is_list(G), is_list(W) ->
    case length(G) =:= length(W) of
        false -> {mismatch, Path ++ " (length)", G, W};
        true -> first([fun() -> compare(X, Y, Path ++ io_lib:format("[~b]", [I])) end
                       || {I, X, Y} <- lists:zip3(lists:seq(0, length(G) - 1), G, W)])
    end;
compare(G, W, _Path) when G =:= W -> ok;
compare(G, W, Path) -> {mismatch, Path, G, W}.

first([]) -> ok;
first([F | Fs]) ->
    case F() of
        ok -> first(Fs);
        M -> M
    end.
