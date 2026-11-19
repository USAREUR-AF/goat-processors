%% Runs every correlate scenario vector (packs/correlate-*) and correlate load
%% vector (spec/correlate-load-vectors) (spec/vector-format.md).
-module(correlator_vectors).
-export([main/1]).
%% Shared with filter_vectors, fuse_vectors and quality_vectors: reading, reporting and the
%% structural comparison of spec/vector-format.md.
-export([read/1, report/2, summarize/2, compare/3]).

main([Root]) ->
    Scenarios = lists:sort(filelib:wildcard(
                             filename:join(Root, "packs/correlate-*/vectors/*.json"))),
    Loads = lists:sort(filelib:wildcard(filename:join(Root, "spec/correlate-load-vectors/*.json"))),
    summarize("correlate", [scenario(Root, F) || F <- Scenarios] ++ [load(F) || F <- Loads]).

%% Prints the summary line and halts, non-zero when any vector failed.
summarize(Label, Results) ->
    Failed = [R || R <- Results, R =/= ok],
    io:format("~s: ~b vectors, ~b passed, ~b failed~n",
              [Label, length(Results), length(Results) - length(Failed), length(Failed)]),
    halt(case Failed of [] -> 0; _ -> 1 end).

read(File) ->
    {ok, Bin} = file:read_file(File),
    json:decode(Bin).

report(Name, ok) -> io:format("PASS ~s~n", [Name]), ok;
report(Name, {mismatch, Path, Got, Want}) ->
    io:format("FAIL ~s at ~s~n  got:  ~ts~n  want: ~ts~n",
              [Name, Path, json:encode(Got), json:encode(Want)]),
    fail.

%% Scenario vector: each step's events and trace, then the final snapshot.
scenario(Root, File) ->
    V = read(File),
    Name = maps:get(<<"name">>, V),
    Dir = filename:join([Root, "packs", maps:get(<<"pack">>, V)]),
    {ok, Pack} = correlator:load_pack(Dir),
    Result = steps(maps:get(<<"steps">>, V), 0, correlator:new(Pack), V),
    report(Name, Result).

steps([], _I, St, V) ->
    compare(correlator:snapshot(St), maps:get(<<"snapshot">>, V), "snapshot");
steps([Step | Rest], I, St0, V) ->
    {Events, Trace, St1} =
        case Step of
            #{<<"ingest">> := Report} -> correlator:ingest(Report, St0);
            #{<<"tick">> := Now} -> correlator:tick(Now, St0)
        end,
    P = io_lib:format("steps[~b]", [I]),
    case compare(Events, maps:get(<<"expect">>, Step), P ++ ".expect") of
        ok ->
            case compare(Trace, maps:get(<<"trace">>, Step), P ++ ".trace") of
                ok -> steps(Rest, I + 1, St1, V);
                M -> M
            end;
        M -> M
    end.

%% Load vector: parsing pack_def fails exactly when expect_error is true.
load(File) ->
    V = read(File),
    Got = case correlator_pack:parse(maps:get(<<"pack_def">>, V)) of
              {ok, _} -> false;
              {error, _} -> true
          end,
    report(maps:get(<<"name">>, V), compare(Got, maps:get(<<"expect_error">>, V), "expect_error")).

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
