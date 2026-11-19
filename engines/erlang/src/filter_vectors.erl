%% Runs every filter scenario vector (packs/filter-*) and filter load vector
%% (spec/filter-load-vectors), with the comparison of spec/vector-format.md.
%% A failing vector prints the path of its first mismatch.
-module(filter_vectors).
-export([main/1]).

-import(correlator_vectors, [read/1, report/2, compare/3]).

main([Root]) ->
    Scenarios = lists:sort(filelib:wildcard(filename:join(Root, "packs/filter-*/vectors/*.json"))),
    Loads = lists:sort(filelib:wildcard(filename:join(Root, "spec/filter-load-vectors/*.json"))),
    correlator_vectors:summarize([scenario(Root, F) || F <- Scenarios] ++ [load(F) || F <- Loads]).

%% Scenario vector: each step's events and trace, then the final snapshot.
scenario(Root, File) ->
    V = read(File),
    {ok, Pack} = filter:load_pack(filename:join([Root, "packs", maps:get(<<"pack">>, V)])),
    report(maps:get(<<"name">>, V), steps(maps:get(<<"steps">>, V), 0, filter:new(Pack), V)).

steps([], _I, St, V) ->
    compare(filter:snapshot(St), maps:get(<<"snapshot">>, V), "snapshot");
steps([Step | Rest], I, St0, V) ->
    {Events, Trace, St1} =
        case Step of
            #{<<"ingest">> := Report} -> filter:ingest(Report, St0);
            #{<<"tick">> := Now} -> filter:tick(Now, St0)
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
    Got = case filter_pack:parse(maps:get(<<"pack_def">>, V)) of
              {ok, _} -> false;
              {error, _} -> true
          end,
    report(maps:get(<<"name">>, V), compare(Got, maps:get(<<"expect_error">>, V), "expect_error")).
